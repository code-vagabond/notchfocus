import AppKit
import ApplicationServices

/// What the user is looking at right now, minus the pixels.
struct ActiveContext {
    var appName: String
    var bundleId: String
    var pid: pid_t
    var windowTitle: String
    var url: String?

    static func capture() -> ActiveContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ActiveContext(appName: "unknown", bundleId: "", pid: 0, windowTitle: "", url: nil)
        }
        let bundleId = app.bundleIdentifier ?? ""
        var ctx = ActiveContext(
            appName: app.localizedName ?? "unknown",
            bundleId: bundleId,
            pid: app.processIdentifier,
            windowTitle: focusedWindowTitle(pid: app.processIdentifier) ?? "",
            url: nil
        )
        if browserAppNames[bundleId] != nil || bundleId == "com.apple.Safari" {
            ctx.url = browserURL(bundleId: bundleId)
        }
        return ctx
    }

    /// Screen the user is looking at: the one under the frontmost app's focused window,
    /// else the one under the cursor.
    static func currentScreen() -> NSScreen? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frame = focusedWindowFrame(pid: pid) {
            // AX reports top-left global coordinates; NSScreen uses bottom-left, anchored on the primary screen.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = NSPoint(x: frame.midX, y: primaryHeight - frame.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    // MARK: - Accessibility (focused window)

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let winEl = win else { return nil }
        return (winEl as! AXUIElement)
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard let winEl = focusedWindow(pid: pid) else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    private static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let winEl = focusedWindow(pid: pid) else { return nil }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Browser URL via AppleScript (ported from indistractable-monitor/GetURL.swift)

    private static let browserAppNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.operasoftware.Opera": "Opera",
        "com.brave.Browser": "Brave Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    private static func browserURL(bundleId: String) -> String? {
        let script: String
        if bundleId == "com.apple.Safari" {
            script = """
            tell application "Safari"
                if frontmost then return URL of current tab of front window
            end tell
            """
        } else if let name = browserAppNames[bundleId] {
            script = """
            tell application "\(name)"
                if frontmost then return URL of active tab of front window
            end tell
            """
        } else {
            return nil
        }
        var err: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
        if let err { NSLog("AppleScript: \(err)") }
        return out?.isEmpty == false ? out : nil
    }
}
