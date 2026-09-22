import AppKit
import ApplicationServices

/// Event-driven "the front app changed what it shows" signal via Accessibility: focused-window
/// changes, new windows, and title changes. Browsers rewrite the window title on every tab
/// switch / open / close and on navigation, so tabs are covered without polling.
final class WindowWatcher {
    private var observer: AXObserver?
    private(set) var pid: pid_t = 0
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    /// Re-point the observer at a process; no-op if already watching it.
    func watch(pid newPid: pid_t) {
        guard newPid != pid, newPid > 0 else { return }
        stop()
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(newPid, callback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(newPid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(obs, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        pid = newPid
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        pid = 0
    }
}
