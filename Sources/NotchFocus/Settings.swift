import Foundation

/// Persistent settings + API key lookup.
/// Key resolution order: env TYPESAFE_API_KEY → ~/.config/notchfocus/apikey
enum Settings {
    private static let d = UserDefaults.standard

    static let configDir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/notchfocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var focusGoal: String {
        get { d.string(forKey: "focusGoal") ?? "" }
        set { d.set(newValue, forKey: "focusGoal") }
    }

    /// Seconds between screen checks.
    static var interval: TimeInterval {
        get { let v = d.double(forKey: "interval"); return v > 0 ? v : 10 }
        set { d.set(newValue, forKey: "interval") }
    }

    /// Seconds to wait after a tab / window / app change before judging it (lets the page settle).
    static var eventDelay: TimeInterval {
        get { let v = d.double(forKey: "eventDelay"); return v > 0 ? v : 1.5 }
        set { d.set(newValue, forKey: "eventDelay") }
    }

    /// Minimum seconds between event-driven checks; a check inside the gap is deferred to its end.
    static var eventGap: TimeInterval {
        get { let v = d.double(forKey: "eventGap"); return v > 0 ? v : 4 }
        set { d.set(newValue, forKey: "eventGap") }
    }

    /// p(distracted) above which a sample counts as distracted.
    static var threshold: Double {
        get { let v = d.double(forKey: "threshold"); return v > 0 ? v : 0.65 }
        set { d.set(newValue, forKey: "threshold") }
    }

    /// Threshold value that can never be reached by p ∈ 0...1 → "don't nudge".
    static let never: Double = 2

    /// p(distracted) needed when Jev rates the activity as only "Slight drift" (email, Slack, docs,
    /// tangents). Kept above `threshold` so related work only shakes the notch when Jev is quite sure.
    static var slightDriftThreshold: Double {
        get { let v = d.double(forKey: "slightDriftThreshold"); return v > 0 ? v : 0.8 }
        set { d.set(newValue, forKey: "slightDriftThreshold") }
    }

    /// USD per million tokens, applied to input + output. TypeSafe publishes no billing API,
    /// so today's spend in the menu is this × tokens from verdicts.jsonl.
    static var priceUsdPerMTokens: Double {
        get { let v = d.double(forKey: "priceUsdPerMTokens"); return v > 0 ? v : 0.042 }
        set { d.set(newValue, forKey: "priceUsdPerMTokens") }
    }

    /// Consecutive distracted samples before the notch shakes (debounce).
    static var consecutiveNeeded: Int {
        get { let v = d.integer(forKey: "consecutive"); return v > 0 ? v : 1 }
        set { d.set(newValue, forKey: "consecutive") }
    }

    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty {
            return env
        }
        let file = configDir.appendingPathComponent("apikey")
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func saveApiKey(_ key: String) throws {
        let file = configDir.appendingPathComponent("apikey")
        try key.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Plain-text app log (errors, permission state) next to the verdicts.
    static func log(_ msg: String) {
        NSLog("%@", msg)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let file = configDir.appendingPathComponent("app.log")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Append-only JSONL log of every verdict, for later analysis / ScreenTimerAI import.
    static func appendLog(_ obj: [String: Any]) {
        let file = configDir.appendingPathComponent("verdicts.jsonl")
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
