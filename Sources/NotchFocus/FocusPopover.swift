import AppKit

/// Popover under the status item: type what you're working on, hit Start.
final class FocusPopoverController: NSViewController, NSTextFieldDelegate {
    var onStart: ((String) -> Void)?
    var onPause: (() -> Void)?

    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let spend = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start focus", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))

        let title = NSTextField(labelWithString: "What are you working on?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        field.placeholderString = "e.g. Ship the notch app"
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail

        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded

        pauseButton.target = self
        pauseButton.action = #selector(pause)
        pauseButton.bezelStyle = .rounded

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 2

        spend.font = .systemFont(ofSize: 11)
        spend.textColor = .tertiaryLabelColor
        spend.lineBreakMode = .byTruncatingTail

        let buttons = NSStackView(views: [pauseButton, NSView(), startButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.spacing = 8

        let stack = NSStackView(views: [title, field, buttons, status, spend])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            spend.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        view = root
    }

    func refresh(goal: String, summary: String, spend spendText: String, paused: Bool) {
        field.stringValue = goal
        status.stringValue = (paused ? "Paused · " : "") + summary
        spend.stringValue = spendText
        pauseButton.title = paused ? "Resume" : "Pause"
        startButton.title = goal.isEmpty ? "Start focus" : "Update goal"
    }

    func focusField() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func start() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onStart?(text)
    }

    @objc private func pause() { onPause?() }

    // Enter in the field submits.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { start(); return true }
        return false
    }
}
