import AppKit

/// One `NotchPanel` per display, built on demand. Alerts go to the screen the user is looking
/// at (focused window, else cursor), so an external monitor gets its own island instead of the
/// shake happening on a MacBook lid that may be closed or out of view.
final class NotchPresenter {
    private var panels: [NSNumber: NotchPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    init() {
        // Displays plugged/unplugged/rearranged: geometry is stale, rebuild lazily.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panels.values.forEach { $0.close() }
            self?.panels.removeAll()
        }
    }

    func alert(left: String, right: String, color: NSColor = .systemRed, autoCollapse: TimeInterval? = 6, shake: Bool = true) {
        let target = panel(for: ActiveContext.currentScreen())
        for p in panels.values where p !== target { p.collapse() }
        target?.alert(left: left, right: right, color: color, autoCollapse: autoCollapse, shake: shake)
    }

    /// Quiet confirmation: expands/collapses without the shake or haptic.
    func pulse(_ text: String, color: NSColor = .systemGreen) {
        alert(left: text, right: "", color: color, autoCollapse: 1.8, shake: false)
    }

    func collapse() {
        panels.values.forEach { $0.collapse() }
    }

    private func panel(for screen: NSScreen?) -> NotchPanel? {
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        if let existing = panels[id] { return existing }
        let p = NotchPanel(screen: screen)
        panels[id] = p
        return p
    }
}
