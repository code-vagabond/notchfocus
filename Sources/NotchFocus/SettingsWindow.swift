import AppKit

/// Settings window in System Settings style: grouped sections (Rhythm / Sensitivity / Patience),
/// each control with its live value and a short caption. Values write through to `Settings`
/// immediately; `onIntervalChanged` lets the timer restart.
final class SettingsWindowController: NSWindowController {
    var onIntervalChanged: (() -> Void)?

    private let intervalSlider = NSSlider()
    private let intervalValue = NSTextField(labelWithString: "")
    private let delaySlider = NSSlider()
    private let delayValue = NSTextField(labelWithString: "")
    private let gapSlider = NSSlider()
    private let gapValue = NSTextField(labelWithString: "")
    private let thresholdSlider = NSSlider()
    private let thresholdValue = NSTextField(labelWithString: "")
    private let driftSlider = NSSlider()
    private let driftValue = NSTextField(labelWithString: "")
    private let consecutiveStepper = NSStepper()
    private let consecutiveValue = NSTextField(labelWithString: "")

    private static let width: CGFloat = 480
    private static let outerInset: CGFloat = 20
    private static let cardInset: CGFloat = 16
    /// Text measure inside a card: 480 − 2·20 − 2·16 = 408.
    private static let measure = width - 2 * (outerInset + cardInset)

    /// White card on grey in light mode; a slightly lifted card in dark mode (like System Settings).
    private static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .quinaryLabel : .controlBackgroundColor
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "NotchFocus Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        load()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        configure(intervalSlider, min: 5, max: 60, step: 5, action: #selector(intervalChanged))
        configure(delaySlider, min: 0.5, max: 5, step: 0.5, action: #selector(delayChanged))
        configure(gapSlider, min: 1, max: 15, step: 1, action: #selector(gapChanged))
        configure(thresholdSlider, min: 30, max: 95, step: 5, action: #selector(thresholdChanged))
        configure(driftSlider, min: 30, max: 100, step: 5, action: #selector(driftChanged))

        consecutiveStepper.minValue = 1
        consecutiveStepper.maxValue = 5
        consecutiveStepper.increment = 1
        consecutiveStepper.target = self
        consecutiveStepper.action = #selector(consecutiveChanged)

        let sections = [
            section("Rhythm", rows: [
                sliderRow("Check interval", intervalSlider, intervalValue, ends: ("5 s", "60 s"),
                          caption: "How often NotchFocus glances at your screen. Shorter intervals catch drift sooner; longer ones cost less and interrupt less."),
                sliderRow("Reaction delay", delaySlider, delayValue, ends: ("0.5 s", "5 s"),
                          caption: "How long to wait after you switch, open or close a tab, window or app before judging it. Long enough for the page to settle, short enough to feel immediate."),
                sliderRow("Minimum gap", gapSlider, gapValue, ends: ("1 s", "15 s"),
                          caption: "The least time between two change-triggered checks. Flicking through tabs waits for this gap to pass before Jev is asked again; the regular interval is unaffected."),
            ]),
            section("Sensitivity", rows: [
                sliderRow("Distraction threshold", thresholdSlider, thresholdValue, ends: ("30%", "95%"),
                          caption: "How certain Jev must be that you have wandered off before a check counts against you. Lower it to be nudged sooner; raise it to be nudged only when there is little doubt."),
                sliderRow("Slight-drift threshold", driftSlider, driftValue, ends: ("30%", "Never"),
                          caption: "A separate bar for the grey zone — email, Slack, docs and tangents that orbit your goal without serving it. Set it high to tolerate related work, or to Never and such detours pass in silence."),
            ]),
            section("Patience", rows: [
                stepperRow("Samples before nudge", consecutiveStepper, consecutiveValue,
                           caption: "How many consecutive off-task checks it takes before the notch stirs. Raise it to forgive a brief glance; lower it for a shorter leash."),
            ]),
        ]

        let root = column(sections, spacing: 20, inset: Self.outerInset)
        root.edgeInsets.top = Self.outerInset
        root.edgeInsets.bottom = Self.outerInset
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        window.setContentSize(content.fittingSize)  // height follows the wrapped captions
    }

    /// Small-caps style group title above a rounded card holding the rows, hairline-separated.
    private func section(_ title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])

        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            if i > 0 { views.append(separator()) }
            views.append(row)
        }
        let inner = column(views, spacing: 12, inset: Self.cardInset)
        inner.edgeInsets.top = 12
        inner.edgeInsets.bottom = 12
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.cornerRadius = 8
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = Self.cardFill
        card.contentViewMargins = .zero
        if let cv = card.contentView {
            cv.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                inner.topAnchor.constraint(equalTo: cv.topAnchor),
                inner.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }

        return column([header, card], spacing: 8)
    }

    /// Vertical stack whose arranged views all span its width minus the horizontal inset.
    /// (`NSStackView.alignment` has no fill mode, so the widths are pinned explicitly.)
    private func column(_ views: [NSView], spacing: CGFloat, inset: CGFloat = 0) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        for v in views {
            v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -2 * inset).isActive = true
        }
        return s
    }

    /// Title + live value, full-width slider, min/max hints under its ends, caption.
    private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField,
                           ends: (String, String), caption: String) -> NSView {
        let scale = NSStackView(views: [hint(ends.0), hint(ends.1)])
        scale.orientation = .horizontal
        scale.distribution = .equalSpacing

        let row = column([headline(title, trailing: styled(value)), slider, scale, captionLabel(caption)], spacing: 8)
        row.setCustomSpacing(2, after: slider)
        return row
    }

    /// Title with value + stepper on the right, caption beneath.
    private func stepperRow(_ title: String, _ stepper: NSStepper, _ value: NSTextField, caption: String) -> NSView {
        let controls = NSStackView(views: [styled(value), stepper])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6

        return column([headline(title, trailing: controls), captionLabel(caption)], spacing: 8)
    }

    private func headline(_ title: String, trailing: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        t.setContentHuggingPriority(.init(1), for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let h = NSStackView(views: [t, trailing])
        h.orientation = .horizontal
        h.alignment = .centerY
        return h
    }

    private func styled(_ value: NSTextField) -> NSTextField {
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.alignment = .right
        return value
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func captionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        l.preferredMaxLayoutWidth = Self.measure
        return l
    }

    private func separator() -> NSView {
        let s = NSBox()
        s.boxType = .separator
        s.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return s
    }

    private func configure(_ s: NSSlider, min: Double, max: Double, step: Double, action: Selector) {
        s.minValue = min
        s.maxValue = max
        s.numberOfTickMarks = Int((max - min) / step) + 1
        s.allowsTickMarkValuesOnly = true
        s.isContinuous = true
        s.target = self
        s.action = action
    }

    // MARK: - Model ↔ view

    private func load() {
        intervalSlider.doubleValue = Settings.interval
        delaySlider.doubleValue = Settings.eventDelay
        gapSlider.doubleValue = Settings.eventGap
        thresholdSlider.doubleValue = Settings.threshold * 100
        driftSlider.doubleValue = Settings.slightDriftThreshold >= 1 ? 100 : Settings.slightDriftThreshold * 100
        consecutiveStepper.integerValue = Settings.consecutiveNeeded
        updateLabels()
    }

    private func updateLabels() {
        intervalValue.stringValue = "\(Int(intervalSlider.doubleValue)) s"
        delayValue.stringValue = String(format: "%.1f s", delaySlider.doubleValue)
        gapValue.stringValue = "\(Int(gapSlider.doubleValue)) s"
        thresholdValue.stringValue = "\(Int(thresholdSlider.doubleValue))%"
        driftValue.stringValue = driftSlider.doubleValue >= 100 ? "Never" : "\(Int(driftSlider.doubleValue))%"
        consecutiveValue.stringValue = "\(consecutiveStepper.integerValue)"
    }

    @objc private func intervalChanged() {
        let v = intervalSlider.doubleValue.rounded()
        if v != Settings.interval {
            Settings.interval = v
            onIntervalChanged?()
        }
        updateLabels()
    }

    @objc private func delayChanged() {
        Settings.eventDelay = (delaySlider.doubleValue * 2).rounded() / 2
        updateLabels()
    }

    @objc private func gapChanged() {
        Settings.eventGap = gapSlider.doubleValue.rounded()
        updateLabels()
    }

    @objc private func thresholdChanged() {
        Settings.threshold = thresholdSlider.doubleValue.rounded() / 100
        updateLabels()
    }

    @objc private func driftChanged() {
        let v = driftSlider.doubleValue.rounded()
        Settings.slightDriftThreshold = v >= 100 ? Settings.never : v / 100
        updateLabels()
    }

    @objc private func consecutiveChanged() {
        Settings.consecutiveNeeded = consecutiveStepper.integerValue
        updateLabels()
    }
}
