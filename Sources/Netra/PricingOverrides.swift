import Foundation
import os

/// ccusage's --offline mode prices models missing from its embedded table at
/// $0, silently corrupting every total (e.g. claude-opus-5 on ccusage 20.0.19).
/// Running online instead re-downloads the multi-MB LiteLLM pricing DB on
/// every invocation (~11s, uncached), far too heavy for a 60s refresh loop.
///
/// So: stay offline, but when a report shows a model with tokens and $0 cost,
/// fetch that model's pricing from LiteLLM once and persist it into a generated
/// ccusage config (`defaults.pricingOverrides`) passed via --config.
enum PricingOverrides {
    private static let log = Logger(subsystem: "com.sahabji0P.netra", category: "pricing")
    private static let litellmURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    /// Retry window for models LiteLLM doesn't know yet (brand-new releases).
    private static let attemptTTL: TimeInterval = 6 * 3600

    private static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configURL: URL { supportDir.appendingPathComponent("ccusage-config.json") }
    private static var metaURL: URL { supportDir.appendingPathComponent("pricing-meta.json") }

    /// Extra ccusage arguments; empty until the first override is written.
    static var arguments: [String] {
        FileManager.default.fileExists(atPath: configURL.path) ? ["--config", configURL.path] : []
    }

    /// Models that used tokens but were priced $0 — the signature of a model
    /// missing from the embedded pricing table. (A genuinely free local model
    /// also matches; it just won't be found in LiteLLM and stays at $0.)
    static func unpricedModels(in report: CCUnifiedReport) -> [String] {
        var names = Set<String>()
        for row in (report.daily ?? []) + (report.weekly ?? []) + (report.monthly ?? []) {
            for model in row.modelBreakdowns ?? [] where model.cost == 0 {
                let tokens = model.inputTokens + model.outputTokens
                    + model.cacheCreationTokens + model.cacheReadTokens
                if tokens > 0 { names.insert(model.modelName) }
            }
        }
        return names.sorted()
    }

    /// Makes sure overrides exist for `models`, fetching LiteLLM pricing when
    /// needed. Returns true when new overrides were written — the caller
    /// should then re-run the scan so the numbers correct themselves now
    /// rather than on the next refresh.
    static func ensure(for models: [String]) async -> Bool {
        let existing = currentOverrides()
        var missing = models.filter { existing[$0] == nil }
        guard !missing.isEmpty else { return false }

        // Don't hammer LiteLLM for models it didn't have last time we looked.
        let attempts = readAttempts()
        missing = missing.filter { attempts[$0].map { Date.now.timeIntervalSince($0) > attemptTTL } ?? true }
        guard !missing.isEmpty else { return false }
        recordAttempts(for: missing)

        guard let table = await fetchLiteLLM() else { return false }
        var overrides = existing
        var added = false
        for model in missing {
            if let priced = pricing(for: model, in: table) {
                overrides[model] = priced
                added = true
                log.info("priced \(model, privacy: .public) from LiteLLM")
            } else {
                log.info("no LiteLLM pricing for \(model, privacy: .public); stays $0")
            }
        }
        guard added else { return false }
        write(overrides: overrides)
        return true
    }

    // MARK: LiteLLM lookup

    private static func fetchLiteLLM() async -> [String: Any]? {
        var request = URLRequest(url: litellmURL)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("LiteLLM pricing fetch failed")
            return nil
        }
        return object
    }

    /// LiteLLM keys the same model many ways ("claude-opus-5" may appear as
    /// "anthropic.claude-opus-5", "global.anthropic.…", region-prefixed with
    /// different prices, …). Prefer exact, then the vendor's canonical entry,
    /// then the shortest suffix match — regional variants are longer.
    static func pricing(for model: String, in table: [String: Any]) -> [String: Double]? {
        var candidates = [model, "anthropic.\(model)", "global.anthropic.\(model)"]
        candidates += table.keys
            .filter { $0.hasSuffix("/\(model)") || $0.hasSuffix(".\(model)") }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        for key in candidates {
            guard let entry = table[key] as? [String: Any] else { continue }
            func cost(_ field: String) -> Double? { (entry[field] as? NSNumber)?.doubleValue }
            guard let input = cost("input_cost_per_token"),
                  let output = cost("output_cost_per_token") else { continue }
            var priced = ["inputCostPerToken": input, "outputCostPerToken": output]
            if let cacheWrite = cost("cache_creation_input_token_cost") {
                priced["cacheCreationInputTokenCost"] = cacheWrite
            }
            if let cacheRead = cost("cache_read_input_token_cost") {
                priced["cacheReadInputTokenCost"] = cacheRead
            }
            return priced
        }
        return nil
    }

    // MARK: Config + meta files

    private static func currentOverrides() -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = object["defaults"] as? [String: Any],
              let raw = defaults["pricingOverrides"] as? [String: [String: Double]] else {
            return [:]
        }
        return raw
    }

    private static func write(overrides: [String: [String: Double]]) {
        let config: [String: Any] = ["defaults": ["pricingOverrides": overrides]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private static func readAttempts() -> [String: Date] {
        guard let data = try? Data(contentsOf: metaURL),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return raw
    }

    private static func recordAttempts(for models: [String]) {
        var attempts = readAttempts()
        for model in models { attempts[model] = .now }
        if let data = try? JSONEncoder().encode(attempts) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }
}
