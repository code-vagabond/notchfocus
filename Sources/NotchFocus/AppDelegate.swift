import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let popover = NSPopover()
    private let focusVC = FocusPopoverController()
    private lazy var settingsWC: SettingsWindowController = {
        let wc = SettingsWindowController()
        wc.onIntervalChanged = { [weak self] in self?.scheduleTimer() }
        return wc
    }()
    private let notch = NotchPresenter()
    private var timer: Timer?
    private var switchDebounce: Timer?
    private lazy var windowWatcher = WindowWatcher { [weak self] in self?.windowChanged() }
    private var lastCheckedTitle = ""
    // Two-layer "nothing changed" cache, most-recent sample only, memory only:
    //  1. pixel fingerprint of the last OCR'd frame → skip OCR + Jev (caret blink, clock tick)
    //  2. goal + window identity + OCR text of the last judged sample → skip Jev (dark mode, resize)
    private var lastFingerprint: ScreenReader.Fingerprint?
    private var lastScreenKey = ""
    private var lastVerdict: JevVerdict?
    private var lastFullCheckAt: Date = .distantPast
    /// Safety valve: slow drift (typing one word per check) never crosses the pixel threshold
    /// against a fixed anchor, so force the full path at least this often.
    private let maxSkipSpan: TimeInterval = 300
    private var lastEventCheckAt: Date = .distantPast
    private var checking = false
    private var warnedPermission = false

    // Debounce / escalation state
    private var consecutiveDistracted = 0
    private var wasDistracted = false
    private var alertedContext = ""   // identity of the distraction last shaken for
    private var lastAlertAt: Date = .distantPast
    private let reAlertEvery: TimeInterval = 45

    private var lastSummary = "No check yet"

    // Menu items we update
    private let goalItem = NSMenuItem()
    private let lastItem = NSMenuItem()
    private let spendItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let ax = ActiveContext.ensureAccessibility()
        let sc = ScreenReader.hasPermission()
        Settings.log("launch: accessibility=\(ax) screenRecording=\(sc) bundle=\(Bundle.main.bundlePath)")
        if !sc { Settings.log("requesting screen recording → \(ScreenReader.requestPermission())") }
        if Settings.apiKey == nil { promptForApiKey() }
        if Settings.focusGoal.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.statusClicked() }
        }

        scheduleTimer()
        observeAppSwitches()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { windowWatcher.watch(pid: pid) }
        notch.pulse("NotchFocus on", color: .systemGreen)
        Settings.log("started interval=\(Settings.interval)s threshold=\(Settings.threshold) slightDrift=\(Settings.slightDriftThreshold)")
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"
        statusItem.button?.font = .systemFont(ofSize: 14)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.contentViewController = focusVC
        popover.behavior = .transient
        focusVC.onStart = { [weak self] goal in self?.setGoal(goal) }
        focusVC.onPause = { [weak self] in self?.togglePause(); self?.refreshPopover() }

        menu = NSMenu()
        goalItem.action = #selector(promptForGoal)
        goalItem.target = self
        menu.addItem(goalItem)

        lastItem.isEnabled = false
        menu.addItem(lastItem)
        spendItem.isEnabled = false
        menu.addItem(spendItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Check now", action: #selector(checkNow), keyEquivalent: "r").target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(withTitle: "Test notch shake", action: #selector(testShake), keyEquivalent: "t").target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self

        menu.addItem(withTitle: "Grant Screen Recording…", action: #selector(openScreenRecordingSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Grant Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set API key…", action: #selector(promptForApiKey), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open log folder", action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchFocus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.delegate = self
        refreshMenu()
    }

    /// Left-click: goal popover. Right-click: full menu.
    @objc private func statusClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu          // attach just for this click…
            button.performClick(nil)
            statusItem.menu = nil           // …so left-click keeps opening the popover
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            focusVC.focusField()
        }
    }

    private func refreshPopover() {
        focusVC.refresh(goal: Settings.focusGoal, summary: lastSummary, spend: Spend.today().summary, paused: Settings.paused)
    }

    private func setGoal(_ text: String) {
        Settings.focusGoal = text
        Settings.paused = false
        lastFingerprint = nil
        lastScreenKey = ""
        lastVerdict = nil
        consecutiveDistracted = 0
        wasDistracted = false
        alertedContext = ""
        popover.performClose(nil)
        notch.pulse("Focus: \(text.prefix(28))", color: .systemBlue)
        refreshMenu()
        runCheck(force: true)
    }

    private func refreshMenu() {
        let goal = Settings.focusGoal
        goalItem.title = goal.isEmpty ? "Set focus goal…" : "Goal: \(goal.prefix(40))…"
        lastItem.title = "Last: \(lastSummary)"
        spendItem.title = Spend.today().summary
        pauseItem.title = Settings.paused ? "Resume" : "Pause"
        statusItem.button?.title = Settings.paused ? "◌" : (wasDistracted ? "◉" : "◎")
    }

    // MARK: - Loop

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.interval, repeats: true) { [weak self] _ in
            self?.runCheck()
        }
        timer?.tolerance = 1
    }

    @objc private func checkNow() { runCheck(force: true) }

    /// Re-check shortly after the frontmost app changes, instead of waiting for the timer,
    /// and start watching that app's windows for tab / title changes.
    private func observeAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else { return }
            windowWatcher.watch(pid: pid)
            if !Settings.paused { scheduleEventCheck() }
        }
    }

    /// AX event from the front app: only worth a check if the focused window's title actually
    /// differs from what was last judged (title-ticking pages, unread counters).
    private func windowChanged() {
        guard !Settings.paused, windowWatcher.pid > 0 else { return }
        let title = ActiveContext.focusedWindowTitle(pid: windowWatcher.pid) ?? ""
        guard title != lastCheckedTitle else { return }
        scheduleEventCheck()
    }

    /// Debounce lets the new window/tab render and swallows rapid ⌘-tabbing.
    /// If it fires inside `Settings.eventGap`, defer to the gap's end instead of dropping the check.
    private func scheduleEventCheck(after delay: TimeInterval = Settings.eventDelay) {
        switchDebounce?.invalidate()
        switchDebounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let remaining = Settings.eventGap - now.timeIntervalSince(lastEventCheckAt)
            if remaining > 0 { scheduleEventCheck(after: remaining); return }
            lastEventCheckAt = now
            runCheck()
            scheduleTimer() // restart the periodic clock from this check
        }
    }

    private func runCheck(force: Bool = false) {
        guard !checking, force || !Settings.paused else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let goal = Settings.focusGoal
                let ctx = ActiveContext.capture()
                lastCheckedTitle = ctx.windowTitle
                // Screen locked / screensaver: nothing to judge.
                if ctx.bundleId == "com.apple.loginwindow" || ctx.bundleId == "com.apple.ScreenSaver.Engine" { return }
                let identity = [goal, ctx.bundleId, ctx.windowTitle, ctx.url ?? ""].joined(separator: "\u{1F}")
                let sameWindow = lastScreenKey.hasPrefix(identity + "\u{1F}")
                let canSkip = !force && sameWindow && lastVerdict != nil
                    && Date().timeIntervalSince(lastFullCheckAt) < maxSkipSpan

                // Layer 1: pixels near-identical to the last OCR'd frame → no OCR, no Jev.
                let screen: ScreenReader.Result
                if canSkip, let anchor = lastFingerprint {
                    guard let changed = try await ScreenReader.readActiveWindowIfChanged(pid: ctx.pid, title: ctx.windowTitle, since: anchor) else {
                        handle(verdict: lastVerdict!, ctx: ctx, ocrLines: 0, skippedBy: "pixels", captureMs: 0, ocrMs: 0)
                        return
                    }
                    screen = changed
                } else {
                    screen = try await ScreenReader.readActiveWindow(pid: ctx.pid, title: ctx.windowTitle)
                }

                // Layer 2: same window + same OCR text → no Jev. Still counts as a sample for the debounce.
                let key = identity + "\u{1F}" + screen.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if canSkip, key == lastScreenKey {
                    lastFingerprint = screen.fingerprint   // re-anchor: text same, pixels moved (theme/resize)
                    handle(verdict: lastVerdict!, ctx: ctx, ocrLines: screen.lineCount, skippedBy: "text", captureMs: screen.captureMs, ocrMs: screen.ocrMs)
                    return
                }

                let v = try await JevClient.judge(goal: goal, context: ctx, screenText: screen.text)
                lastScreenKey = key
                lastFingerprint = screen.fingerprint
                lastVerdict = v
                lastFullCheckAt = Date()
                handle(verdict: v, ctx: ctx, ocrLines: screen.lineCount, captureMs: screen.captureMs, ocrMs: screen.ocrMs)
            } catch {
                lastSummary = "error: \(error.localizedDescription)"
                Settings.log("check failed: \(error.localizedDescription)")
                if (error as NSError).code == ScreenReader.notGrantedError.code, !warnedPermission {
                    warnedPermission = true
                    notch.alert(left: "Needs Screen Recording", right: "see menu ◎", color: .systemOrange, autoCollapse: 8)
                }
                refreshMenu()
            }
        }
    }

    /// `skippedBy`: nil = fresh Jev verdict, "pixels" / "text" = replayed from the cache layer that fired.
    private func handle(verdict v: JevVerdict, ctx: ActiveContext, ocrLines: Int, skippedBy: String? = nil, captureMs: Int, ocrMs: Int) {
        let cached = skippedBy != nil
        let pct = Int((v.distracted * 100).rounded())
        // Slight drift (related work) gets its own, usually stricter, cutoff.
        let cutoff = v.severityIndex == 1 ? Settings.slightDriftThreshold : Settings.threshold
        let distracted = v.distracted >= cutoff
        consecutiveDistracted = distracted ? consecutiveDistracted + 1 : 0

        lastSummary = "\(distracted ? "distracted" : "on task") \(pct)% · \(v.severityLabel) · \(ctx.appName) · \(cached ? "cached" : "\(v.latencyMs)ms")"
        Settings.log("verdict\(skippedBy.map { " (skipped by \($0))" } ?? "") p=\(String(format: "%.2f", v.distracted)) sev=\(String(format: "%.2f", v.severity)) app=\(ctx.appName) title=\(ctx.windowTitle.prefix(60)) ocr=\(ocrLines) lines tokens=\(cached ? 0 : v.inputTokens) capture=\(captureMs)ms ocr=\(ocrMs)ms jev=\(cached ? 0 : v.latencyMs)ms")

        Settings.appendLog([
            "ts": ISO8601DateFormatter().string(from: Date()),
            "goal": Settings.focusGoal,
            "app": ctx.appName,
            "bundle_id": ctx.bundleId,
            "title": ctx.windowTitle,
            "url": ctx.url ?? "",
            "p_distracted": v.distracted,
            "severity": v.severity,
            "severity_label": v.severityLabel,
            "ocr_lines": ocrLines,
            "input_tokens": cached ? 0 : v.inputTokens,
            "output_tokens": cached ? 0 : v.outputTokens,
            "latency_ms": cached ? 0 : v.latencyMs,
            "capture_ms": captureMs,
            "ocr_ms": ocrMs,
            "model": v.model,
            "skipped_by": skippedBy ?? "",
        ])

        if !cached { Spend.record(inputTokens: v.inputTokens, outputTokens: v.outputTokens) }

        let now = Date()
        if consecutiveDistracted >= Settings.consecutiveNeeded {
            // Shake on first trigger or a new distraction; re-shake periodically while the same one persists.
            let context = "\(ctx.bundleId)|\(ctx.windowTitle)|\(ctx.url ?? "")"
            if !wasDistracted || context != alertedContext || now.timeIntervalSince(lastAlertAt) >= reAlertEvery {
                notch.alert(left: v.severityLabel, right: "\(pct)%", color: v.severity >= 2.5 ? .systemRed : .systemOrange, autoCollapse: nil)
                alertedContext = context
                lastAlertAt = now
            }
            wasDistracted = true
        } else if wasDistracted && !distracted {
            wasDistracted = false
            alertedContext = ""
            notch.pulse("Back on track", color: .systemGreen)
        }
        refreshMenu()
        if popover.isShown { refreshPopover() }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        Settings.paused.toggle()
        if Settings.paused {
            // Clean slate: no stale "Back on track" or pending event check after resuming.
            switchDebounce?.invalidate()
            consecutiveDistracted = 0
            wasDistracted = false
            alertedContext = ""
            notch.collapse()
        }
        refreshMenu()
    }

    @objc private func testShake() {
        notch.alert(left: "Test", right: "100%", color: .systemRed)
    }

    @objc private func openSettings() {
        settingsWC.show()
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Settings.configDir)
    }

    @objc private func promptForGoal() {
        if !popover.isShown { statusClicked() }
    }

    @objc private func promptForApiKey() {
        let text = askText(
            title: "TypeSafe API key",
            message: "Stored in ~/.config/notchfocus/apikey (chmod 600). Or set TYPESAFE_API_KEY in the environment.",
            initial: "", secure: true
        )
        if let text, !text.isEmpty {
            do { try Settings.saveApiKey(text) } catch { NSLog("save key failed: \(error)") }
        }
    }

    private func askText(title: String, message: String, initial: String, secure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        return r == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
}
