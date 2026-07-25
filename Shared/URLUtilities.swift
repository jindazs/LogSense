import Foundation

enum ScrapboxURLBuilder {
    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func makePageURL(project: String, title: String, body: String? = nil) -> URL? {
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty,
              let encodedProject = encodePathComponent(project),
              let encodedTitle = encodePathComponent(title) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "scrapbox.io"
        components.percentEncodedPath = "/\(encodedProject)/\(encodedTitle)"

        if let body {
            components.queryItems = [URLQueryItem(name: "body", value: body)]
        }

        return components.url
    }

    private static func encodePathComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed)
    }
}

enum WebURLPolicy {
    private static let contentDomains = ["scrapbox.io"]
    private static let inAppDomains = contentDomains + [
        "google.com",
        "googleusercontent.com",
        "gstatic.com"
    ]

    static func isAllowedContentURL(_ url: URL) -> Bool {
        isHTTPSURL(url, allowedDomains: contentDomains)
    }

    static func isAllowedInAppURL(_ url: URL) -> Bool {
        isHTTPSURL(url, allowedDomains: inAppDomains)
    }

    private static func isHTTPSURL(_ url: URL, allowedDomains: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        return allowedDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
