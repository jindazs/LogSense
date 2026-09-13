import Foundation

struct ScrapboxPageAppendRequest: Equatable {
    let contextURL: URL
    let pageURL: URL
    let verificationURL: URL
    let expectedFragments: [String]
}

struct TodayPageRequest: Equatable {
    let contextURL: URL
    let pageURL: URL
    let creationURL: URL
    let verificationURL: URL
}

enum TodayPageContent {
    static func heading(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return "" }
        return "#\(month)月\(day)日"
    }
}

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

    static func makePageAppendRequest(
        project: String,
        append: PhotoImportAppend
    ) -> ScrapboxPageAppendRequest? {
        guard let contextURL = makeProjectURL(project: project),
        let pageURL = makePageURL(
            project: project,
            title: append.pageTitle,
            body: append.body
        ),
        let verificationURL = makePageTextAPIURL(
            project: project,
            title: append.pageTitle
        ),
        !append.verificationFragments.isEmpty else {
            return nil
        }
        return ScrapboxPageAppendRequest(
            contextURL: contextURL,
            pageURL: pageURL,
            verificationURL: verificationURL,
            expectedFragments: append.verificationFragments
        )
    }

    static func makeTodayPageRequest(
        project: String,
        title: String,
        date: Date,
        calendar: Calendar = .current
    ) -> TodayPageRequest? {
        let heading = TodayPageContent.heading(for: date, calendar: calendar)
        guard !heading.isEmpty,
              let contextURL = makeProjectURL(project: project),
              let pageURL = makePageURL(project: project, title: title),
              let creationURL = makePageURL(project: project, title: title, body: heading),
              let verificationURL = makePageTextAPIURL(project: project, title: title) else {
            return nil
        }
        return TodayPageRequest(
            contextURL: contextURL,
            pageURL: pageURL,
            creationURL: creationURL,
            verificationURL: verificationURL
        )
    }

    static func makeProjectURL(project: String) -> URL? {
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty,
              let encodedProject = encodePathComponent(project) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "scrapbox.io"
        components.percentEncodedPath = "/\(encodedProject)"
        return components.url
    }

    static func makePageTextAPIURL(project: String, title: String) -> URL? {
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty,
              let encodedProject = encodePathComponent(project),
              let encodedTitle = encodePathComponent(title) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "scrapbox.io"
        components.percentEncodedPath = "/api/pages/\(encodedProject)/\(encodedTitle)/text"
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
