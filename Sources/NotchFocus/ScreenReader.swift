import AppKit
import ScreenCaptureKit
import Vision

/// Grabs one frame of the active window (falling back to the main display) via
/// ScreenCaptureKit and runs Apple's on-device OCR (Vision) over it. Nothing but the
/// recognized text leaves this file.
enum ScreenReader {
    static let maxChars = 2500

    struct Result {
        init(lines: [String], fingerprint: Fingerprint, captureMs: Int, ocrMs: Int) {
            var text = lines.joined(separator: "\n")
            if text.count > maxChars { text = String(text.prefix(maxChars)) + "…" }
            self.text = text
            self.lineCount = lines.count
            self.fingerprint = fingerprint
            self.captureMs = captureMs
            self.ocrMs = ocrMs
        }

        var text: String
        var lineCount: Int
        /// Perceptual fingerprint of the frame the text came from (see `Fingerprint`).
        var fingerprint: Fingerprint
        var captureMs: Int
        var ocrMs: Int
    }

    /// Captures only the frontmost app's focused window when one can be found, so other
    /// visible windows (chat, second monitor spill, etc.) don't leak into the verdict.
    static func readActiveWindow(pid: pid_t, title: String) async throws -> Result {
        let t0 = Date()
        let image = try await capture(pid: pid, title: title)
        let t1 = Date()
        let fp = Fingerprint(image)
        let lines = try await ocr(image)
        return Result(lines: lines, fingerprint: fp, captureMs: ms(t0, t1), ocrMs: ms(t1, Date()))
    }

    /// Cheap "did the screen change?" gate: capture, then compare against the frame that was
    /// last OCR'd. Returns nil when the picture is near-identical (caret blink, clock tick,
    /// spinner), so the caller can replay its previous verdict without running OCR.
    static func readActiveWindowIfChanged(pid: pid_t, title: String, since anchor: Fingerprint?) async throws -> Result? {
        let t0 = Date()
        let image = try await capture(pid: pid, title: title)
        let t1 = Date()
        let fp = Fingerprint(image)
        if let anchor, fp.isSame(as: anchor) { return nil }
        let lines = try await ocr(image)
        return Result(lines: lines, fingerprint: fp, captureMs: ms(t0, t1), ocrMs: ms(t1, Date()))
    }

    private static func ms(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) * 1000).rounded()) }

    // MARK: - Fingerprint

    /// 64×64 grayscale box-average of the capture + a difference hash (each bit: is this
    /// pixel brighter than its right neighbour?). ~0.5 ms; only ever lives in memory.
    /// Measured on text pages: caret/clock/spinner noise = 0–2 bits, scroll or new page = 300+.
    struct Fingerprint {
        static let side = 64
        /// Max Hamming distance still treated as "same screen". >10× margin either way.
        static let threshold = 24

        let width: Int
        let height: Int
        let bits: [UInt64]   // 64 rows × 63 comparisons, packed per row

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            let n = Fingerprint.side
            var gray = [Float](repeating: 0, count: n * n)
            if let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
               image.bitsPerPixel == 32, image.width >= n, image.height >= n {
                let bpr = image.bytesPerRow
                let w = image.width, h = image.height
                // Sample a fixed grid of source pixels per cell instead of every pixel so
                // the cost stays flat regardless of window size (≈8×8 samples per cell).
                let sx = max(1, (w / n) / 8), sy = max(1, (h / n) / 8)
                for cy in 0..<n {
                    let y0 = cy * h / n, y1 = (cy + 1) * h / n
                    for cx in 0..<n {
                        let x0 = cx * w / n, x1 = (cx + 1) * w / n
                        var sum: Float = 0, count: Float = 0
                        var y = y0
                        while y < y1 {
                            var x = x0
                            while x < x1 {
                                let px = base + y * bpr + x * 4
                                // BGRA or RGBA both fine: luma-ish mean of the first three channels.
                                sum += Float(px[0]) + Float(px[1]) + Float(px[2])
                                count += 3
                                x += sx
                            }
                            y += sy
                        }
                        gray[cy * n + cx] = count > 0 ? sum / count : 0
                    }
                }
            }
            var rows = [UInt64](repeating: 0, count: n)
            for y in 0..<n {
                var row: UInt64 = 0
                for x in 0..<(n - 1) where gray[y * n + x] > gray[y * n + x + 1] {
                    row |= 1 << UInt64(x)
                }
                rows[y] = row
            }
            bits = rows
        }

        func distance(to other: Fingerprint) -> Int {
            zip(bits, other.bits).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        }

        /// Same capture geometry and near-zero hash distance.
        func isSame(as other: Fingerprint) -> Bool {
            width == other.width && height == other.height && distance(to: other) <= Fingerprint.threshold
        }
    }

    // MARK: - Capture

    /// True once macOS has persisted Screen Recording for this app. Logged so we can tell
    /// "not granted" apart from "granted but capture failed".
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS once per launch; the user must then enable the toggle in
    /// System Settings → Privacy & Security → Screen & System Audio Recording and relaunch.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Set once a real capture succeeded; after that the preflight is ignored.
    private static var captureVerified = false
    /// Set after one real attempt failed; stops re-prompting the user every check.
    private static var captureRefused = false

    static let notGrantedError = NSError(domain: "NotchFocus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Screen Recording not granted"])

    private static func capture(pid: pid_t, title: String) async throws -> CGImage {
        // Preflight can lag behind a fresh grant, so trust one real attempt over it —
        // but only one, so a real refusal doesn't re-prompt on every check.
        if !captureVerified && !hasPermission() && captureRefused { throw notGrantedError }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            captureRefused = true
            Settings.log("SCShareableContent failed (preflight=\(hasPermission())): \(error.localizedDescription)")
            throw notGrantedError
        }
        if !captureVerified { captureVerified = true; Settings.log("screen capture verified OK (preflight=\(hasPermission()))") }

        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best

        let filter: SCContentFilter
        if let window = activeWindow(in: content, pid: pid, title: title) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            // frame is in points, so this captures at ~half the Retina pixel
            // resolution — plenty for OCR and keeps Vision fast.
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
        } else {
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
            else { throw NSError(domain: "NotchFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"]) }
            // Exclude our own windows (the notch panel) from the capture.
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            config.width = display.width
            config.height = display.height
        }

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The frontmost app's focused window: prefer an exact title match, otherwise its
    /// frontmost normal-layer window. Ignores tiny helper windows (tooltips, popovers).
    private static func activeWindow(in content: SCShareableContent, pid: pid_t, title: String) -> SCWindow? {
        // SCShareableContent lists windows front-to-back, so `first` is the topmost.
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width > 200 && $0.frame.height > 150
        }
        if !title.isEmpty, let exact = candidates.first(where: { $0.title == title }) { return exact }
        return candidates.first
    }

    // MARK: - OCR

    private static func ocr(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Top-to-bottom, then left-to-right (Vision's origin is bottom-left).
                let sorted = obs.sorted {
                    let dy = $1.boundingBox.midY - $0.boundingBox.midY
                    return abs(dy) > 0.01 ? dy > 0 : $0.boundingBox.minX < $1.boundingBox.minX
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count > 1 }
                cont.resume(returning: lines)
            }
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US", "de-DE"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
