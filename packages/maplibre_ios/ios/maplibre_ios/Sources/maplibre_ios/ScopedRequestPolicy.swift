import Foundation

/// Immutable, opt-in request policy. Values come from an approved provider
/// contract, never copied browser identities or runtime remote configuration.
struct ScopedRequestPolicy {
    let host: String
    let pathPrefix: String
    let headers: [String: String]

    init?(configuration: [String: Any]) {
        guard let host = configuration["Host"] as? String,
              !host.isEmpty, host == host.lowercased(),
              host.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
              let prefix = configuration["PathPrefix"] as? String,
              prefix.hasPrefix("/"), prefix.hasSuffix("/"),
              !prefix.contains(".."), !prefix.contains("%"),
              let headers = configuration["Headers"] as? [String: String],
              !headers.isEmpty else { return nil }
        let allowed = Set(["accept", "user-agent", "referer", "origin"])
        var seen = Set<String>()
        for (key, value) in headers {
            guard allowed.contains(key.lowercased()), seen.insert(key.lowercased()).inserted,
                  !value.isEmpty, value.utf8.count <= 1024,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { return nil }
        }
        self.host = host
        self.pathPrefix = prefix
        self.headers = headers
    }

    func matches(_ url: URL?) -> Bool {
        guard let url = url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == host,
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil,
              parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix(pathPrefix),
              !parts.percentEncodedPath.contains("%"),
              !parts.path.split(separator: "/").contains("..") else { return false }
        return true
    }

    func apply(to original: URLRequest) -> URLRequest {
        guard matches(original.url) else { return original }
        var request = original
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    func redirect(original: URLRequest?, current: URLRequest?, proposed: URLRequest) -> URLRequest? {
        if (matches(original?.url) || matches(current?.url)) && !matches(proposed.url) {
            return nil // Never forward provider headers outside the approved scope.
        }
        return apply(to: proposed)
    }
}
