import AppKit

/// Looks for a newer release on GitHub once a day. No automatic install: it only tells the user.
final class UpdateChecker: ObservableObject {
    struct Release {
        let version: String
        let url: URL
    }

    /// "owner/repo", written into Info.plist by scripts/build.sh. Nil in builds without a GitHub remote.
    static let repository = Bundle.main.object(forInfoDictionaryKey: "DuckproofRepository") as? String
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var releasesPage: URL? { repository.flatMap { URL(string: "https://github.com/\($0)/releases/latest") } }

    @Published private(set) var available: Release?

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    func start() {
        guard Self.repository != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check { _ in }
    }

    /// `completion` receives the newer release, nil when up to date, or an error.
    func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        guard let repository = Self.repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.success(nil))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                result = .success(Self.isNewer(version, than: Self.currentVersion) ? Release(version: version, url: page) : nil)
            } else {
                result = .failure(URLError(.cannotParseResponse))
            }
            DispatchQueue.main.async {
                self.defaults.set(Date(), forKey: "lastUpdateCheck")
                if case .success(let release) = result { self.found(release) }
                completion(result)
            }
        }.resume()
    }

    private func found(_ release: Release?) {
        available = release
        // One notification per new version, not one per day.
        guard let release, defaults.string(forKey: "notifiedVersion") != release.version else { return }
        defaults.set(release.version, forKey: "notifiedVersion")
        Notifier.shared.post("Duckproof \(release.version) is available", "Click to download it from GitHub.",
                             id: "duckproof.update", url: release.url)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
