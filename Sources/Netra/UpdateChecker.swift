import Foundation
import Observation

/// Checks GitHub Releases once a day and surfaces a quiet "new version"
/// notice. Updates themselves flow through Homebrew (`brew upgrade`) — this
/// only closes the awareness gap of pull-based updates.
@MainActor
@Observable
final class UpdateChecker {
    static let owner = "sahabji0P"
    static let repo = "netra"

    /// Set only when a release newer than the running build exists.
    private(set) var availableVersion: String?

    var currentVersion: String? {
        // nil when running unbundled via `swift run`/`swift build` — no
        // meaningful version to compare, so checks are skipped in dev.
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    init() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check() async {
        guard let currentVersion else { return }
        var request = URLRequest(url: URL(
            string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        availableVersion = Self.isVersion(latest, newerThan: currentVersion) ? latest : nil
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
