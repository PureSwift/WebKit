// What a page is made with, before its first load: AppRuntime's
// `WebPage.Configuration`, as Apple's SwiftUI `WebPage` has one.

extension WebPage {

    /// What a page is made with: scripts it runs in every document, and URL
    /// schemes its app answers. Pass it to `WebPage(configuration:)`; it
    /// can't change after.
    ///
    /// ```swift
    /// var configuration = WebPage.Configuration()
    /// configuration.userScripts = [WebUserScript(source: articleScript, injectionTime: .atDocumentStart)]
    /// configuration.urlSchemeHandlers["app-icon"] = { request, respond in
    ///     respond(.success(WebURLSchemeResponse(contentType: "image/png", body: icons[request.path] ?? [])))
    /// }
    /// let page = WebPage(configuration: configuration)
    /// ```
    public struct Configuration {

        /// Scripts that run in every document the page loads, in order.
        public var userScripts: [WebUserScript] = []

        /// Handlers for URL schemes the app answers, by scheme, such as
        /// `"app-icon"` for `app-icon:/feed.png`. The page loads their URLs
        /// as images, documents and `fetch` responses, even while the
        /// network isn't allowed. Schemes are compared lowercased, and the
        /// ones WebKit loads itself, such as `https` and `file`, are left
        /// to it.
        public var urlSchemeHandlers: [String: WebURLSchemeHandler] = [:]

        public init() { }
    }
}

/// A script a page runs in every document it loads.
public struct WebUserScript: Equatable, Sendable {

    /// When a script runs.
    public enum InjectionTime: Equatable, Sendable {
        /// Before the document's own scripts, once its element exists.
        case atDocumentStart
        /// Once the document has loaded, before its subresources.
        case atDocumentEnd
    }

    public var source: String

    public var injectionTime: InjectionTime

    /// Whether it runs in the main frame alone, or in every frame.
    public var forMainFrameOnly: Bool

    public init(source: String, injectionTime: InjectionTime, forMainFrameOnly: Bool = true) {
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
    }
}

/// Answers a request for a URL in a scheme the app registered: call
/// `respond` once, at once or later. A request whose `respond` is let go
/// uncalled fails, as one answered after its page went away does nothing.
public typealias WebURLSchemeHandler = @MainActor (
    _ request: WebURLSchemeRequest,
    _ respond: @escaping @MainActor (Result<WebURLSchemeResponse, WebError>) -> Void
) -> Void

/// A request a page made for a URL in a scheme its app answers.
public struct WebURLSchemeRequest: Sendable {

    /// The URL, as the page asked for it.
    public var url: String

    /// The URL's path: what follows the scheme, without its query.
    public var path: String

    /// `GET`, or `POST` for a form or a `fetch` with a body.
    public var method: String

    /// The request's headers, in order.
    public var headers: [(name: String, value: String)]

    /// The request's body; nil when it has none.
    public var body: [UInt8]?

    public init(url: String, path: String, method: String = "GET", headers: [(name: String, value: String)] = [], body: [UInt8]? = nil) {
        self.url = url
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// What a page gets for a URL in a scheme its app answers.
public struct WebURLSchemeResponse: Sendable {

    public var status: Int

    /// The type of what's in `body`, such as `image/png`.
    public var contentType: String?

    /// Other headers. `Content-Type` is sent from `contentType` unless it's
    /// here.
    public var headers: [(name: String, value: String)]

    public var body: [UInt8]

    public init(status: Int = 200, contentType: String?, headers: [(name: String, value: String)] = [], body: [UInt8]) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }
}
