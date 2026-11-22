import Foundation
import Testing
import WPEWebKit

/// URL schemes a page's host answers, in WPE WebKit itself. Schemes are
/// registered once for the whole process, so each test has its own.
@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WPEURLSchemeTests {

    /// An image three points wide and two high.
    static let image = Array("<svg xmlns='http://www.w3.org/2000/svg' width='3' height='2'></svg>".utf8)

    /// A script that loads `url` as an image and returns its width, or
    /// throws when it fails.
    static func loadImage(_ url: String) -> String {
        """
        const image = new Image();
        image.src = '\(url)';
        await new Promise((resolve, reject) => {
            image.onload = resolve;
            image.onerror = () => reject(new Error('the image failed'));
        });
        return image.naturalWidth;
        """
    }

    @Test func servesImagesToAnHTTPSPage() throws {
        let page = try Page()
        #expect(page.content.registerURLScheme("test-image"))
        var requests: [(path: String, method: String, body: [UInt8]?)] = []
        page.content.onURLSchemeRequest = { task in
            requests.append((task.path, task.method, task.body))
            task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        }
        // An https page, which would block an insecure scheme's images.
        try page.load(html: "<p>Text</p>", baseURL: "https://example.invalid/article")
        #expect(try page.callAsync(WPEURLSchemeTests.loadImage("test-image:/icons/feed.svg")) == "3")
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/icons/feed.svg")
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.body == nil)
    }

    @Test func servesImagesWithoutTheNetwork() throws {
        WPEEngine.isNetworkAllowed = false
        defer { WPEEngine.isNetworkAllowed = true }
        let page = try Page()
        page.content.registerURLScheme("test-offline")
        page.content.onURLSchemeRequest = { task in
            task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        }
        try page.load(html: "<p>Text</p>", baseURL: "https://example.invalid/article")
        #expect(try page.callAsync(WPEURLSchemeTests.loadImage("test-offline:/icon.svg")) == "3")
    }

    @Test func answersFetchWithItsStatusHeadersAndBody() throws {
        let page = try Page()
        page.content.registerURLScheme("test-data")
        var received: (method: String, contentType: String?, body: [UInt8]?)?
        page.content.onURLSchemeRequest = { task in
            received = (task.method, task.headers.first { $0.name.lowercased() == "content-type" }?.value, task.body)
            task.finish(status: 201, contentType: "text/plain", headers: [
                ("Access-Control-Allow-Origin", "*"),
                ("Access-Control-Expose-Headers", "X-Reply"),
                ("X-Reply", "yes"),
            ], body: Array("pong".utf8))
        }
        try page.load(html: "<p>Text</p>", baseURL: "https://example.invalid/article")
        let result = try page.callAsync("""
            const response = await fetch('test-data:/echo', { method: 'POST', body: 'hello', headers: { 'Content-Type': 'text/plain' } });
            return [response.status, response.headers.get('content-type'), response.headers.get('x-reply'), await response.text()];
            """)
        #expect(result == #"[201,"text/plain","yes","pong"]"#)
        #expect(received?.method == "POST")
        #expect(received?.contentType?.hasPrefix("text/plain") == true)
        #expect(received?.body == Array("hello".utf8))
    }

    @Test func loadsAPageFromAScheme() throws {
        let page = try Page()
        page.content.registerURLScheme("test-page")
        page.content.onURLSchemeRequest = { task in
            task.finish(contentType: "text/html", body: Array("<title>From the host</title><p>Text</p>".utf8))
        }
        page.content.load("test-page:/index.html")
        try wait(for: "the page") { page.delegate.title == "From the host" && page.delegate.finishes == 1 }
        #expect(page.delegate.url == "test-page:/index.html")
        #expect(!page.delegate.events.contains { $0.hasPrefix("fail") })
    }

    @Test func reportsTheHostsFailure() throws {
        let page = try Page()
        page.content.registerURLScheme("test-fail")
        page.content.onURLSchemeRequest = { task in
            task.fail(.notPermitted, message: "not for you")
        }
        page.content.load("test-fail:/index.html")
        try wait(for: "the failure") { page.delegate.events.contains { $0.hasPrefix("fail") } }
        #expect(page.delegate.events.contains("fail \(WPEWebContent.ErrorCode.notPermitted.rawValue)"))
    }

    @Test func refusesPagesThatDidNotRegister() throws {
        let owner = try Page(), other = try Page()
        owner.content.registerURLScheme("test-owned")
        var requests = 0
        owner.content.onURLSchemeRequest = { task in
            requests += 1
            task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        }
        other.content.onURLSchemeRequest = { task in
            requests += 1
            task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        }
        try other.load(html: "<p>Text</p>")
        #expect(throws: WPEError.self) { try other.callAsync(WPEURLSchemeTests.loadImage("test-owned:/icon.svg")) }
        #expect(requests == 0)
        #expect(other.content.urlSchemes.isEmpty)
    }

    @Test func refusesNamesThatArentItsToRegister() throws {
        let page = try Page()
        for name in ["https", "HTTP", "file", "data", "blob", "about", "javascript", "", "1icon", "an icon", "icon:"] {
            #expect(!page.content.registerURLScheme(name), "\(name)")
        }
        #expect(page.content.urlSchemes.isEmpty)
        #expect(page.content.registerURLScheme("Test-Mixed.Case+1"))
        #expect(page.content.urlSchemes == ["test-mixed.case+1"])
    }

    @Test func registersAfterThePageHasLoaded() throws {
        let page = try Page()
        try page.load(html: "<p>Text</p>", baseURL: "https://example.invalid/article")
        // The web process is running; a new scheme still reaches the host.
        page.content.registerURLScheme("test-late")
        page.content.onURLSchemeRequest = { task in
            task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        }
        try page.load(html: "<p>Again</p>", baseURL: "https://example.invalid/article")
        #expect(try page.callAsync(WPEURLSchemeTests.loadImage("test-late:/icon.svg")) == "3")
    }

    @Test func answersLaterAndOnlyOnce() throws {
        let page = try Page()
        page.content.registerURLScheme("test-later")
        var tasks: [WPEURLSchemeTask] = []
        page.content.onURLSchemeRequest = { tasks.append($0) }
        try page.load(html: "<p>Text</p>")
        var outcome: Result<String?, WPEError>?
        page.content.callAsyncJavaScript(WPEURLSchemeTests.loadImage("test-later:/icon.svg")) { outcome = $0 }
        try wait(for: "the request") { !tasks.isEmpty }
        let task = try #require(tasks.first)
        #expect(!task.isFinished)
        task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
        #expect(task.isFinished)
        // Answering again does nothing.
        task.finish(contentType: "image/svg+xml", body: [])
        task.fail(.unknown, message: "too late")
        try wait(for: "the image") { outcome != nil }
        #expect(try outcome?.get() == "3")
    }

    @Test func failsARequestItsHostLetsGo() throws {
        let page = try Page()
        page.content.registerURLScheme("test-dropped")
        var requests = 0
        page.content.onURLSchemeRequest = { _ in requests += 1 }
        try page.load(html: "<p>Text</p>")
        #expect(throws: WPEError.self) { try page.callAsync(WPEURLSchemeTests.loadImage("test-dropped:/icon.svg")) }
        #expect(requests == 1)
    }

    @Test func failsRequestsWithoutAHandler() throws {
        let page = try Page()
        page.content.registerURLScheme("test-unanswered")
        try page.load(html: "<p>Text</p>")
        #expect(throws: WPEError.self) { try page.callAsync(WPEURLSchemeTests.loadImage("test-unanswered:/icon.svg")) }
    }

    @Test func endsItsRequestsWhenItGoes() throws {
        var tasks: [WPEURLSchemeTask] = []
        do {
            let page = try Page()
            page.content.registerURLScheme("test-gone")
            page.content.onURLSchemeRequest = { tasks.append($0) }
            try page.load(html: "<p>Text</p>")
            _ = try page.evaluate("new Image().src = 'test-gone:/icon.svg'; true")
            try wait(for: "the request") { !tasks.isEmpty }
            #expect(tasks.first?.isFinished == false)
        }
        let task = try #require(tasks.first)
        #expect(task.isFinished)
        // Nothing to answer now.
        task.finish(contentType: "image/svg+xml", body: WPEURLSchemeTests.image)
    }
}
