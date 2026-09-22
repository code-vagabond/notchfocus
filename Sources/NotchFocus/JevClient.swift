import Foundation

/// Minimal client for TypeSafe's System One endpoint (Jev).
/// Text in, typed probabilistic decisions out. No generation, no vision.
/// Docs: https://docs.typesafe.ai/api
struct JevVerdict {
    /// p(distracted) in 0...1
    var distracted: Double
    /// 0 = on task … 3 = doom-scrolling (probability-weighted, can be fractional)
    var severity: Double
    /// Index into `JevClient.severityLevels` (rounded `severity`); 1 = "Slight drift".
    var severityIndex: Int
    var severityLabel: String
    var severityConfidence: Double
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var latencyMs: Int
}

enum JevError: Error, LocalizedError {
    case noApiKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No TypeSafe API key (set TYPESAFE_API_KEY or ~/.config/notchfocus/apikey)"
        case .http(let code, let body): return "Jev HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "Jev: unexpected response shape"
        }
    }
}

enum JevClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Pin a version in production; "jev-latest" is fine while prototyping.
    static let model = "jev-latest"

    static let severityLevels = [
        "On task: screen content directly serves the focus goal",
        "Slight drift: related work, but not the stated goal (email, Slack, docs, tangents)",
        "Off task: unrelated work or browsing",
        "Entertainment / doom-scrolling: social feeds, video, news, shopping, games",
    ]
    /// Short names shown on the island / in logs, one per severity level.
    static let severityNames = ["On task", "Slight drift", "Off task", "Doom-scrolling"]

    static func judge(goal: String, context: ActiveContext, screenText: String) async throws -> JevVerdict {
        guard let key = Settings.apiKey else { throw JevError.noApiKey }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE HH:mm"

        // Nested by signal quality so the model sees the hierarchy, not just a flat bag of keys.
        var activeWindow: [String: Any] = [
            "app": context.appName,
            "bundle_id": context.bundleId,
            "title": context.windowTitle.isEmpty ? "(no title)" : context.windowTitle,
        ]
        if let url = context.url { activeWindow["url"] = url }

        let state: [String: Any] = [
            "focus_goal": goal.isEmpty ? "(user did not set a goal; assume general productive work)" : goal,
            "local_time": fmt.string(from: Date()),
            "active_window": [
                "reliability": "HIGH — exact metadata from macOS about the window the user is interacting with. Primary evidence.",
                "details": activeWindow,
            ],
            "screen_text": [
                "reliability": "LOW — noisy on-device OCR of the active window only. May contain quoted text, test data, chat history, or code that merely mentions unrelated topics. Use to refine the verdict, never to overrule active_window.",
                "text": screenText,
            ],
        ]

        let questions: [String: Any] = [
            "distracted": [
                "type": "noul",
                "instructions": "Is the user currently distracted from their focus_goal? Decide primarily from active_window (app, title, url); use screen_text only to refine what they are doing inside that window. Being in a terminal, IDE, code editor, docs, or an AI coding assistant counts as working on the goal unless the content is clearly unrelated. Brief goal-related lookups are NOT distraction.",
                "criteria": [
                    "true": "The active window is unrelated to the focus goal, or is entertainment / social media / news / shopping.",
                    "false": "The active window serves the focus goal or is a reasonable supporting task for it.",
                ],
            ],
            "severity": [
                "type": "score",
                "instructions": "How far is the user's current activity from the focus_goal? Judge the activity (active_window.app + what they are doing in it), not isolated words in screen_text.",
                "criteria": severityLevels,
            ],
        ]

        let body: [String: Any] = ["state": state, "model": model, "questions": questions]
        // Debug: keep the last request on disk so prompts can be tuned against real screens.
        if let dbg = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            try? dbg.write(to: Settings.configDir.appendingPathComponent("last_request.json"))
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)

        guard let http = resp as? HTTPURLResponse else { throw JevError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw JevError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let d = answers["distracted"] as? [String: Any],
              let noul = d["noul"] as? Double,
              let s = answers["severity"] as? [String: Any],
              let score = s["score"] as? Double
        else { throw JevError.badResponse }

        let idx = max(0, min(severityLevels.count - 1, Int(score.rounded())))
        let usage = json["usage"] as? [String: Any]

        return JevVerdict(
            distracted: noul,
            severity: score,
            severityIndex: idx,
            severityLabel: severityNames[idx],
            severityConfidence: s["confidence"] as? Double ?? 0,
            model: json["model"] as? String ?? model,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            latencyMs: ms
        )
    }
}
