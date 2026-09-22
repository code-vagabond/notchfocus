import AppKit
import QuartzCore

/// A borderless, click-through panel that sits exactly over the MacBook notch and
/// "grows out of it" Dynamic-Island style. Collapsed it is black-on-black and invisible;
/// on a distraction it widens sideways, shows a label, and buzzes.
///
/// The window itself never moves or resizes: it is allocated at its maximum size once
/// and everything visible is a Core Animation layer inside it, so the WindowServer only
/// ever composites — no frame changes, no draw(_:) redraws mid-animation.
final class NotchPanel {
    // MARK: Tunables

    private let pad: CGFloat = 16              // slack around the island so the shake never clips
    private let extraDrop: CGFloat = 10        // how far the black extends below the notch when open
    private let wingWidth: CGFloat = 150       // each side when expanded
    private let collapsedRadius: CGFloat = 10  // ≈ the physical notch's bottom radius
    private let expandedRadius: CGFloat = 17

    private struct Spring { let mass: CGFloat; let stiffness: CGFloat; let damping: CGFloat }
    private let expandSpring   = Spring(mass: 1, stiffness: 280, damping: 24)  // ζ≈0.72 → ~4 % overshoot
    private let collapseSpring = Spring(mass: 1, stiffness: 320, damping: 36)  // ζ≈1.0  → no overshoot, quicker

    private let labelDelay: CFTimeInterval = 0.06   // labels start after the island is already growing
    private let labelFadeIn: CFTimeInterval = 0.22
    private let labelFadeOut: CFTimeInterval = 0.12 // faster than the collapse so text never gets clipped
    private let labelScaleFrom: CGFloat = 0.9
    private let labelSlide: CGFloat = 4             // pt the labels travel outward while appearing

    private let shakeAmplitude: CGFloat = 6
    private let shakeDuration: CFTimeInterval = 0.45
    private let shakeCycles: Double = 6.5           // ~14 Hz: reads as a buzz, not a wobble

    private let reducedMotionDuration: CFTimeInterval = 0.18

    // MARK: State

    private let panel: NSPanel
    private let container = NSView()       // everything that shakes lives in here
    private let islandHost = NSView()      // layer-hosting: owns `island` outright, AppKit never touches it
    private let island = CALayer()
    private let leftGroup = NSView()
    private let rightGroup = NSView()
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let dot = NSView()

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat
    private let hasNotch: Bool
    private let windowSize: CGSize

    private var collapseTimer: Timer?
    private(set) var isExpanded = false

    init(screen: NSScreen) {
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let notchCenterX: CGFloat

        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = r.minX - l.maxX
            notchHeight = screen.safeAreaInsets.top
            notchCenterX = (l.maxX + r.minX) / 2
        } else {
            // No notch (external display / older Mac): fake a small island in the menu-bar band,
            // hidden while collapsed since there is no black notch to blend into.
            hasNotch = false
            notchWidth = 180
            notchHeight = max(24, screenFrame.maxY - screen.visibleFrame.maxY)
            notchCenterX = screenFrame.midX
        }

        // Fixed maximum window: expanded island + shake slack. Never changes after this.
        windowSize = CGSize(width: notchWidth + 2 * wingWidth + 2 * pad,
                            height: notchHeight + extraDrop + pad)
        let snap = { (v: CGFloat) in (v * scale).rounded() / scale }   // pixel-align so edges stay crisp
        let frame = NSRect(x: snap(notchCenterX - windowSize.width / 2),
                           y: screenFrame.maxY - windowSize.height,   // top edge flush with the screen
                           width: windowSize.width, height: windowSize.height)

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        buildViews(scale: scale)
        layout(expanded: false, animated: false)
        panel.orderFrontRegardless()
    }

    // MARK: - Public

    /// Expand sideways with a message. Stays open until `collapse()` or `autoCollapse`.
    /// `shake` adds the buzz + trackpad haptic — reserved for real distraction alerts.
    func alert(left: String, right: String, color: NSColor = .systemRed, autoCollapse: TimeInterval? = 6, shake: Bool = true) {
        collapseTimer?.invalidate()
        leftLabel.stringValue = left
        rightLabel.stringValue = right
        withoutActions { dot.layer?.backgroundColor = color.cgColor }
        layout(expanded: true, animated: true)
        if shake {
            if !reduceMotion { self.shake() }
            haptic()
        }
        if let s = autoCollapse {
            collapseTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
                self?.collapse()
            }
        }
    }

    /// Short, quiet confirmation (e.g. back on task): same spring, no shake, no haptic.
    func pulse(_ text: String, color: NSColor = .systemGreen) {
        alert(left: text, right: "", color: color, autoCollapse: 1.8, shake: false)
    }

    func collapse() {
        collapseTimer?.invalidate()
        layout(expanded: false, animated: true)
    }

    /// Tear down (display unplugged / rearranged); the presenter builds a fresh one on demand.
    func close() {
        collapseTimer?.invalidate()
        panel.close()
    }

    // MARK: - View tree

    private func buildViews(scale: CGFloat) {
        let bounds = NSRect(origin: .zero, size: windowSize)
        let host = NSView(frame: bounds)
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .never
        panel.contentView = host

        container.frame = bounds
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .never
        host.addSubview(container)

        // Layer-hosting (layer set before wantsLayer) so AppKit does not manage its sublayers.
        let hostLayer = CALayer()
        hostLayer.contentsScale = scale
        islandHost.layer = hostLayer
        islandHost.wantsLayer = true
        islandHost.layerContentsRedrawPolicy = .never
        islandHost.frame = bounds
        container.addSubview(islandHost)

        // Anchored top-center: growing the bounds only ever pushes sideways and downward,
        // so the top edge stays glued to the screen edge without animating position.
        island.anchorPoint = CGPoint(x: 0.5, y: 1)
        island.position = CGPoint(x: windowSize.width / 2, y: windowSize.height)
        island.backgroundColor = NSColor.black.cgColor
        island.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // bottom only; top stays square
        island.contentsScale = scale
        hostLayer.addSublayer(island)

        // Labels live in the wings, vertically centered in the menu-bar band.
        let bandY = windowSize.height - notchHeight
        let labelH: CGFloat = 16
        let labelY = ((notchHeight - labelH) / 2).rounded()

        leftGroup.frame = NSRect(x: pad, y: bandY, width: wingWidth, height: notchHeight)
        rightGroup.frame = NSRect(x: pad + wingWidth + notchWidth, y: bandY, width: wingWidth, height: notchHeight)
        for group in [leftGroup, rightGroup] {
            group.wantsLayer = true
            group.layerContentsRedrawPolicy = .never
            group.alphaValue = 0
            container.addSubview(group)
        }

        for label in [leftLabel, rightLabel] {
            label.textColor = .white
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.wantsLayer = true
        }
        dot.wantsLayer = true
        dot.layerContentsRedrawPolicy = .never
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.frame = NSRect(x: 14, y: ((notchHeight - 8) / 2).rounded(), width: 8, height: 8)
        leftGroup.addSubview(dot)

        leftLabel.alignment = .left
        leftLabel.frame = NSRect(x: 26, y: labelY, width: wingWidth - 30, height: labelH)
        leftGroup.addSubview(leftLabel)

        rightLabel.alignment = .right
        rightLabel.frame = NSRect(x: 8, y: labelY, width: wingWidth - 22, height: labelH)
        rightGroup.addSubview(rightLabel)
    }

    // MARK: - Layout

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func layout(expanded: Bool, animated: Bool) {
        let wasExpanded = isExpanded
        isExpanded = expanded
        // Re-alerting while open: text is already updated, only the shake needs to happen.
        if animated && wasExpanded == expanded { return }

        let newSize = CGSize(width: notchWidth + (expanded ? 2 * wingWidth : 0),
                             height: notchHeight + (expanded ? extraDrop : 0))
        let newRadius = expanded ? expandedRadius : collapsedRadius
        let newAlpha: CGFloat = expanded ? 1 : 0
        let newIslandOpacity: Float = (expanded || hasNotch) ? 1 : 0
        let oldSize = island.bounds.size
        let oldRadius = island.cornerRadius
        let oldAlpha = leftGroup.alphaValue
        let oldIslandOpacity = island.opacity

        // Commit the model values immediately; the explicit animations below are additive
        // deltas from the old model, so a retarget mid-flight continues from where it is.
        withoutActions {
            island.bounds.size = newSize
            island.cornerRadius = newRadius
            island.opacity = newIslandOpacity
            leftGroup.alphaValue = newAlpha
            rightGroup.alphaValue = newAlpha
        }

        guard animated else {
            for l in [island, container.layer, leftGroup.layer, rightGroup.layer] { l?.removeAllAnimations() }
            return
        }

        let sizeDelta = CGSize(width: oldSize.width - newSize.width, height: oldSize.height - newSize.height)
        let radiusDelta = oldRadius - newRadius
        let alphaDelta = Float(oldAlpha - newAlpha)
        let islandOpacityDelta = oldIslandOpacity - newIslandOpacity
        if islandOpacityDelta != 0 {
            island.add(basic("opacity", from: islandOpacityDelta, to: 0 as Float,
                             duration: expanded ? labelFadeIn : labelFadeOut), forKey: nil)
        }

        if reduceMotion {
            // Accessibility: no spring, no overshoot, just short eased changes and a crossfade.
            island.add(basic("bounds.size", from: sizeDelta, to: CGSize.zero, duration: reducedMotionDuration), forKey: nil)
            island.add(basic("cornerRadius", from: radiusDelta, to: 0 as CGFloat, duration: reducedMotionDuration), forKey: nil)
            for group in [leftGroup, rightGroup] {
                group.layer?.add(basic("opacity", from: alphaDelta, to: 0 as Float, duration: 0.15), forKey: nil)
            }
            return
        }

        let spring = expanded ? expandSpring : collapseSpring
        island.add(self.spring("bounds.size", from: sizeDelta, to: CGSize.zero, spring), forKey: nil)
        island.add(self.spring("cornerRadius", from: radiusDelta, to: 0 as CGFloat, spring), forKey: nil)

        if expanded {
            // Labels emerge from the notch: slightly small, 4 pt inward, staggered after the island.
            for (group, dir) in [(leftGroup, 1.0), (rightGroup, -1.0)] {
                guard let layer = group.layer else { continue }
                layer.add(basic("opacity", from: alphaDelta, to: 0 as Float,
                                duration: labelFadeIn, timing: .easeOut, delay: labelDelay), forKey: nil)
                let from = scaledAboutCenter(group.bounds.size, scale: labelScaleFrom, dx: CGFloat(dir) * labelSlide)
                layer.add(self.spring("transform", from: from, to: CATransform3DIdentity, expandSpring, delay: labelDelay), forKey: nil)
            }
        } else {
            for group in [leftGroup, rightGroup] {
                group.layer?.add(basic("opacity", from: alphaDelta, to: 0 as Float,
                                       duration: labelFadeOut, timing: .easeIn), forKey: nil)
            }
        }
    }

    // MARK: - Effects

    /// The "vibration": a decaying ~14 Hz horizontal buzz of island + labels together.
    /// Additive, so it rides on top of whatever the expand spring is doing.
    private func shake() {
        guard let layer = container.layer else { return }
        let steps = 60
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = (0...steps).map { i -> CGFloat in
            let t = Double(i) / Double(steps)
            let envelope = pow(1 - t, 1.5)          // 6 → 0, front-loaded like a haptic tap
            return shakeAmplitude * CGFloat(envelope * sin(2 * .pi * shakeCycles * t))
        }
        anim.duration = shakeDuration
        anim.calculationMode = .cubic
        anim.isAdditive = true
        layer.add(anim, forKey: "shake")   // same key: a fresh alert restarts the buzz
    }

    /// Trackpad haptic — only felt if a finger is resting on the trackpad, harmless otherwise.
    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: - Animation helpers

    /// Model updates with implicit actions off — the explicit animations own all motion.
    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func spring(_ keyPath: String, from: Any, to: Any, _ p: Spring, delay: CFTimeInterval = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = p.mass
        a.stiffness = p.stiffness
        a.damping = p.damping
        a.initialVelocity = 0
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        stage(a, delay: delay)
        return a
    }

    private func basic(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval,
                       timing: CAMediaTimingFunctionName = .easeInEaseOut, delay: CFTimeInterval = 0) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: timing)
        stage(a, delay: delay)
        return a
    }

    private func stage(_ a: CAPropertyAnimation, delay: CFTimeInterval) {
        a.isAdditive = true
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards   // hold the "from" delta during the stagger instead of flashing the end state
        }
    }

    /// Scale about the group's center plus a horizontal nudge. AppKit pins layer-backed views'
    /// anchorPoint to (0,0), so the centering has to be baked into the matrix.
    private func scaledAboutCenter(_ size: CGSize, scale s: CGFloat, dx: CGFloat) -> CATransform3D {
        var m = CATransform3DMakeTranslation(size.width / 2 + dx, size.height / 2, 0)
        m = CATransform3DScale(m, s, s, 1)
        return CATransform3DTranslate(m, -size.width / 2, -size.height / 2, 0)
    }
}
