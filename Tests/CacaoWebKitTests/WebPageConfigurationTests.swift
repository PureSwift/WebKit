import Foundation
import Testing
import WPEWebKit
@testable import CacaoWebKit

/// A page's configuration and message handlers, over real pages in WPE
/// WebKit.
@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WebPageConfigurationTests {

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// An image three points wide and two high.
    static let image = Array("<svg xmlns='http://www.w3.org/2000/svg' width='3' height='2'></svg>".utf8)

    /// Runs the engine's loop, and the main actor's tasks, until `condition`
    /// holds.
    func wait(for what: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else {
                throw Failure(description: "timed out waiting for \(what)")
            }
            WPEEngine.dispatch()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Shows `html` and waits for it to load.
    func load(_ page: WebPage, html: String, baseURL: String? = "https://example.invalid/article") async throws {
        var finished = false
        page.onFinish = { finished = true }
        page.load(html: html, baseURL: baseURL)
        try await wait(for: "the load") { finished }
        page.onFinish = nil
    }

    /// Runs `body` as an async function in the page and returns what it
    /// returns, as JSON.
    func callAsync(_ page: WebPage, _ body: String) async throws -> String? {
        let content = try #require(page.content)
        var outcome: Result<String?, WPEError>?
        content.callAsyncJavaScript(body) { outcome = $0 }
        try await wait(for: "the function") { outcome != nil }
        return try outcome?.get()
    }

    /// Evaluates `script` through the page, running the engine's loop while
    /// it waits, as Cacao's host would.
    func evaluate(_ page: WebPage, _ script: String) async throws -> String? {
        var outcome: Result<String?, WebError>?
        page.evaluateJavaScript(script) { outcome = $0 }
        try await wait(for: "the script") { outcome != nil }
        return try outcome?.get()
    }

    /// A script that loads `url` as an image and returns its width, or
    /// `"failed"`.
    static func loadImage(_ url: String) -> String {
        """
        const image = new Image();
        image.src = '\(url)';
        const loaded = await new Promise(resolve => {
            image.onload = () => resolve(true);
            image.onerror = () => resolve(false);
        });
        return loaded ? image.naturalWidth : 'failed';
        """
    }

    /// A script that posts `message` to `handler` and returns what it
    /// resolves to, or `{ error: message }`.
    static func post(_ handler: String, _ message: String) -> String {
        """
        try {
            const value = await window.webkit.messageHandlers.\(handler).postMessage(\(message));
            return value === undefined ? 'undefined' : value;
        } catch (error) {
            return { error: String(error && error.message !== undefined ? error.message : error) };
        }
        """
    }

    // MARK: User scripts

    @Test func runsItsUserScriptsAroundThePagesOwn() async throws {
        var configuration = WebPage.Configuration()
        configuration.userScripts = [
            WebUserScript(source: "window.order = ['start']", injectionTime: .atDocumentStart),
            WebUserScript(source: "window.order.push('end')", injectionTime: .atDocumentEnd),
        ]
        let page = WebPage(configuration: configuration)
        #expect(page.configuration.userScripts.count == 2)
        try await load(page, html: "<script>window.order.push('page')</script><p>Text</p>")
        #expect(try await evaluate(page, "window.order") == #"["start","page","end"]"#)
    }

    // MARK: URL schemes

    @Test func answersItsSchemes() async throws {
        var requests: [WebURLSchemeRequest] = []
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers["Test-Page-Icon"] = { request, respond in
            requests.append(request)
            respond(.success(WebURLSchemeResponse(contentType: "image/svg+xml", body: WebPageConfigurationTests.image)))
        }
        let page = WebPage(configuration: configuration)
        try await load(page, html: "<p>Text</p>")
        #expect(try await callAsync(page, Self.loadImage("test-page-icon:/feeds/1.svg")) == "3")
        #expect(requests.map(\.path) == ["/feeds/1.svg"])
        #expect(requests.first?.method == "GET")
    }

    @Test func respondsLaterWithAFailure() async throws {
        var responders: [(Result<WebURLSchemeResponse, WebError>) -> Void] = []
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers["test-page-later"] = { _, respond in responders.append(respond) }
        let page = WebPage(configuration: configuration)
        page.load("test-page-later:/index.html")
        try await wait(for: "the request") { !responders.isEmpty }
        responders[0](.failure(WebError(.notPermitted, message: "not for you")))
        try await wait(for: "the failure") { page.error != nil }
        #expect(page.error?.code == .notPermitted)
    }

    @Test func servesAPageAndItsFetches() async throws {
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers["test-page-app"] = { request, respond in
            switch request.path {
            case "/index.html":
                respond(.success(WebURLSchemeResponse(contentType: "text/html", body: Array("<title>App</title>".utf8))))
            default:
                respond(.success(WebURLSchemeResponse(status: 404, contentType: "text/plain", headers: [("Access-Control-Allow-Origin", "*")],
                                                      body: Array("missing".utf8))))
            }
        }
        let page = WebPage(configuration: configuration)
        var finished = false
        page.onFinish = { finished = true }
        page.load("test-page-app:/index.html")
        try await wait(for: "the page") { finished && page.title == "App" }
        #expect(page.url == "test-page-app:/index.html")
        let result = try await callAsync(page, """
            const response = await fetch('test-page-app:/missing');
            return [response.status, await response.text()];
            """)
        #expect(result == #"[404,"missing"]"#)
    }

    @Test func leavesSchemesWebKitLoadsToIt() async throws {
        var logged: [String] = []
        let logger = WPEEngine.logger
        WPEEngine.logger = { logged.append($0) }
        defer { WPEEngine.logger = logger }
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers["https"] = { _, respond in
            respond(.failure(WebError(.unknown, message: "never asked")))
        }
        let page = WebPage(configuration: configuration)
        try await load(page, html: "<title>Plain</title>")
        #expect(page.title == "Plain")
        #expect(logged.contains { $0.contains("https") })
    }

    // MARK: Messages

    @Test func hearsMessagesFromHandlersAddedBeforeItLoads() async throws {
        let page = WebPage()
        var messages: [String?] = []
        page.addMessageHandler(named: "note") { messages.append($0) }
        try await load(page, html: "<script>window.webkit.messageHandlers.note.postMessage({ seen: true })</script>")
        try await wait(for: "the message") { !messages.isEmpty }
        #expect(messages == [#"{"seen":true}"#])
    }

    @Test func repliesToMessages() async throws {
        let page = WebPage()
        try await load(page, html: "<p>Text</p>")
        // Added after the engine's page is made, so from the next load on.
        page.addMessageHandler(named: "ask") { body async throws(WebError) -> String? in
            guard body != "0" else {
                throw WebError(.unknown, message: "no zeros")
            }
            return #"{"echo":\#(body ?? "null")}"#
        }
        page.addMessageHandler(named: "quiet") { _ async throws(WebError) -> String? in nil }
        try await load(page, html: "<p>Again</p>")
        #expect(try await callAsync(page, Self.post("ask", "5")) == #"{"echo":5}"#)
        #expect(try await callAsync(page, Self.post("ask", "0")) == #"{"error":"no zeros"}"#)
        #expect(try await callAsync(page, Self.post("quiet", "1")) == #""undefined""#)
    }

    @Test func changesAndRemovesHandlers() async throws {
        let page = WebPage()
        var oneWay: [String?] = []
        page.addMessageHandler(named: "host") { oneWay.append($0) }
        try await load(page, html: "<p>Text</p>")
        _ = try await evaluate(page, "window.webkit.messageHandlers.host.postMessage(1); true")
        try await wait(for: "the one-way message") { !oneWay.isEmpty }

        // The same name, now replying.
        page.addMessageHandler(named: "host") { _ async throws(WebError) -> String? in #""replied""# }
        try await load(page, html: "<p>Again</p>")
        #expect(try await callAsync(page, Self.post("host", "2")) == #""replied""#)
        #expect(oneWay == ["1"])

        page.removeMessageHandler(named: "host")
        try await load(page, html: "<p>Gone</p>")
        // With no handlers left, WPE WebKit takes `window.webkit` away too.
        #expect(try await evaluate(page, "window.webkit === undefined || window.webkit.messageHandlers.host === undefined") == "true")
    }
}
