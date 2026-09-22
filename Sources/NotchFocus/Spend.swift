import Foundation

/// Today's Jev spend, derived locally: TypeSafe has no usage/billing endpoint, only per-call
/// `usage.input_tokens` / `output_tokens`, so we sum what `verdicts.jsonl` recorded for the
/// current local day and price it at `Settings.priceUsdPerMTokens`.
enum Spend {
    struct Day {
        var date: String        // yyyy-MM-dd, local
        var checks = 0          // real Jev calls (cache replays excluded)
        var inputTokens = 0
        var outputTokens = 0

        var usd: Double { Double(inputTokens + outputTokens) / 1_000_000 * Settings.priceUsdPerMTokens }

        var summary: String {
            let tok = inputTokens + outputTokens
            let tokStr = tok >= 1_000_000 ? String(format: "%.1fM", Double(tok) / 1_000_000)
                       : tok >= 1_000 ? String(format: "%.0fk", Double(tok) / 1_000) : "\(tok)"
            let usdStr = usd < 1 ? String(format: "$%.3f", usd) : String(format: "$%.2f", usd)
            return "\(usdStr) today · \(checks) checks · \(tokStr) tokens"
        }
    }

    private static var cached: Day?

    private static var localDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Totals for today; scanned from the log on first use and after midnight, then kept in memory.
    static func today() -> Day {
        let date = localDay.string(from: Date())
        if let c = cached, c.date == date { return c }
        let day = scan(date: date)
        cached = day
        return day
    }

    /// Called for every fresh (non-replayed) verdict so the menu stays live without rereading the file.
    static func record(inputTokens: Int, outputTokens: Int) {
        var day = today()
        day.checks += 1
        day.inputTokens += inputTokens
        day.outputTokens += outputTokens
        cached = day
    }

    private static func scan(date: String) -> Day {
        var day = Day(date: date)
        let file = Settings.configDir.appendingPathComponent("verdicts.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return day }
        let iso = ISO8601DateFormatter()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["ts"] as? String, let when = iso.date(from: ts),
                  localDay.string(from: when) == date else { continue }
            let input = obj["input_tokens"] as? Int ?? 0
            guard input > 0 else { continue }   // cache replays log 0 tokens
            day.checks += 1
            day.inputTokens += input
            day.outputTokens += obj["output_tokens"] as? Int ?? 0
        }
        return day
    }
}
