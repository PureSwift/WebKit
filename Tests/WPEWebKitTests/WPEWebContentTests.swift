import Foundation
import Testing
import WPEWebKit

/// Pages in WPE WebKit itself, where it is installed. Nothing here reaches
/// the network.
@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WPEWebContentTests {

    // MARK: The contract

    @Test func tellsItsDelegateAboutALoad() throws {
        let page = try Page()
        try page.load(html: "<title>Hello</title><p>Text</p>", baseURL: "https://example.invalid/page")
        try wait(for: "the title") { page.delegate.title == "Hello" }
        let events = page.delegate.events
        #expect(events.first == "loading")
        #expect(events.contains("url https://example.invalid/page"))
        #expect(events.contains("loaded 1.0"))
        #expect(events.contains("finish"))
        // The host's own load isn't asked about.
        #expect(!events.contains { $0.hasPrefix("should") })
        #expect(!events.contains { $0.hasPrefix("fail") })
        let loaded = try #require(events.firstIndex(of: "loaded 1.0"))
        let finish = try #require(events.firstIndex(of: "finish"))
        #expect(loaded < finish)
    }

    @Test func identifiesItsPages() throws {
        let first = try Page(), second = try Page()
        #expect(first.content.identifier() != second.content.identifier())
        #expect(WPEWebContent.content(identifier: first.content.identifier()) === first.content)
        #expect(WPEWebContent.make(RecordingDelegate()) != nil)
    }

    @Test func countsPages() throws {
        let before = WPEEngine.pageCount
        var counts: [Int] = []
        WPEEngine.onPageCountChanged = { counts.append($0) }
        defer { WPEEngine.onPageCountChanged = nil }
        var identifier: Int32 = 0
        do {
            let page = try Page()
            identifier = page.content.identifier()
            withExtendedLifetime(page) {
                #expect(WPEEngine.pageCount == before + 1)
            }
        }
        #expect(counts == [before + 1, before])
        #expect(WPEWebContent.content(identifier: identifier) == nil)
    }

    @Test func answersScriptsByRequest() throws {
        let page = try Page()
        try page.load(html: "<p id=a>Text</p>")
        page.content.evaluateJavaScript("document.getElementById('a').textContent", request: 7)
        page.content.evaluateJavaScript("undefined", request: 8)
        page.content.evaluateJavaScript("missing()", request: 9)
        try wait(for: "the scripts") { page.delegate.scripts.count == 3 }
        #expect(page.delegate.scripts[7]?.result == #""Text""#)
        #expect(page.delegate.scripts[7]?.error == nil)
        #expect(page.delegate.scripts[8]?.result == nil)
        #expect(page.delegate.scripts[8]?.error == nil)
        #expect(page.delegate.scripts[9]?.error?.contains("missing") == true)
    }

    @Test func asksItsDelegateAboutNavigations() throws {
        let page = try Page()
        try page.load(html: "<a id=link href='https://example.invalid/next'>Next</a>")
        page.delegate.allows = false
        _ = try page.evaluate("document.getElementById('link').click()")
        try wait(for: "the question") { page.delegate.events.contains { $0.hasPrefix("should") } }
        #expect(page.delegate.events.contains("should 0 https://example.invalid/next"))
        // Refused, the page stays where it was, and nothing failed.
        #expect(try page.evaluate("document.getElementById('link') != null") == "true")
        #expect(!page.delegate.events.contains { $0.hasPrefix("fail") })
    }

    @Test func followsNavigationsAndGoesBack() throws {
        // Files, because a page can't send its top frame to a data URI.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try Data("<title>First</title><a id=link href='second.html'>Next</a>".utf8).write(to: first)
        try Data("<title>Second</title>".utf8).write(to: second)

        let page = try Page()
        page.content.load(first.absoluteString)
        try wait(for: "the first page") { page.delegate.title == "First" && page.delegate.finishes == 1 }
        #expect(page.delegate.url == first.absoluteString)

        _ = try page.evaluate("document.getElementById('link').click()")
        try wait(for: "the second page") { page.delegate.title == "Second" && page.delegate.finishes == 2 }
        #expect(page.delegate.events.contains("should 0 \(second.absoluteString)"))
        #expect(page.delegate.url == second.absoluteString)
        #expect(page.delegate.events.contains("history true false"))

        page.content.goBack()
        try wait(for: "the first page again") { page.delegate.title == "First" && page.delegate.finishes == 3 }
        #expect(page.delegate.events.contains("should 2 \(first.absoluteString)"))
        #expect(page.delegate.url == first.absoluteString)
        #expect(page.delegate.events.last { $0.hasPrefix("history") } == "history false true")

        // At the end of the history, going back does nothing.
        let count = page.delegate.events.count
        page.content.goBack()
        WPEEngine.dispatch(for: 0.3) { false }
        #expect(page.delegate.events.count == count)
    }

    @Test func failsLoadsItCannotMake() throws {
        let page = try Page()
        page.content.load("not a url")
        #expect(page.delegate.events == ["fail \(WPEWebContent.ErrorCode.badURL.rawValue)"])
        page.content.load("file:///nonexistent/\(UUID().uuidString).html")
        try wait(for: "the failure") { page.delegate.events.contains("loaded 1.0") }
        #expect(page.delegate.events.filter { $0.hasPrefix("fail") }.count == 2)
        // A load that failed doesn't finish.
        #expect(page.delegate.finishes == 0)
    }

    @Test func refusesTheNetworkWhenItIsNotAllowed() throws {
        WPEEngine.isNetworkAllowed = false
        defer { WPEEngine.isNetworkAllowed = true }
        let page = try Page()
        page.content.load("https://example.invalid/")
        #expect(page.delegate.events == ["fail \(WPEWebContent.ErrorCode.notPermitted.rawValue)"])
        // What isn't remote still loads, and its links out are refused too.
        try page.load(html: "<title>Local</title><a id=link href='https://example.invalid/next'>Next</a>")
        _ = try page.evaluate("document.getElementById('link').click()")
        try wait(for: "the refusal") { page.delegate.events.filter { $0 == "fail 7" }.count == 2 }
        #expect(!page.delegate.events.contains { $0.hasPrefix("should") })
    }

    @Test func mapsErrorsToCodes() {
        func code(_ domain: String, _ code: Int) -> WPEWebContent.ErrorCode? {
            WPEWebContent.ErrorCode(WPEError(domain: domain, code: code, message: ""))
        }
        #expect(code("WebKitNetworkError", 302) == nil)
        #expect(code("WebKitNetworkError", 300) == .network)
        #expect(code("WebKitNetworkError", 303) == .badURL)
        #expect(code("WebKitPolicyError", 102) == nil)
        #expect(code("WebKitPolicyError", 101) == .badURL)
        #expect(code("g-resolver-error-quark", 0) == .network)
        #expect(code("g-io-error-quark", 24) == .timedOut)
        #expect(code("g-tls-error-quark", 1) == .security)
        #expect(code("other", 1) == .unknown)
    }

    // MARK: Beyond the contract

    @Test func awaitsAsyncScripts() throws {
        let page = try Page()
        try page.load(html: "<p>Text</p>")
        var outcome: Result<String?, WPEError>?
        page.content.callAsyncJavaScript("return await new Promise(resolve => setTimeout(() => resolve(7), 10))") { outcome = $0 }
        try wait(for: "the function") { outcome != nil }
        #expect(try outcome?.get() == "7")
        #expect(try page.evaluate("({ list: [1, true] })") == #"{"list":[1,true]}"#)
        #expect(throws: WPEError.self) { try page.evaluate("missing()") }
    }

    @Test func answersNavigationsLater() throws {
        let page = try Page()
        try page.load(html: "<a id=link href='https://example.invalid/next'>Next</a>")
        var asked: [WPENavigation] = []
        var decisions: [WPEPolicyDecision] = []
        page.content.onNavigation = { navigation, decision in
            asked.append(navigation)
            decisions.append(decision)
        }
        _ = try page.evaluate("document.getElementById('link').click()")
        try wait(for: "the question") { !asked.isEmpty }
        #expect(asked.first?.uri == "https://example.invalid/next")
        #expect(asked.first?.kind == .linkClicked)
        #expect(asked.first?.opensNewWindow == false)
        // The delegate isn't asked as well.
        #expect(!page.delegate.events.contains { $0.hasPrefix("should") })
        decisions.removeFirst().cancel()
        #expect(try page.evaluate("document.getElementById('link') != null") == "true")
    }

    @Test func runsUserScriptsAndHearsTheirMessages() throws {
        let page = try Page()
        var messages: [String] = []
        page.content.onScriptMessage = { name, body in messages.append("\(name) \(body ?? "undefined")") }
        page.content.addScriptMessageHandler("host")
        page.content.addUserScript("window.fromUserScript = 5; window.webkit.messageHandlers.host.postMessage({ ready: true })",
                                   atDocumentStart: true)
        try page.load(html: "<p>Text</p>")
        try wait(for: "the message") { !messages.isEmpty }
        #expect(messages == [#"host {"ready":true}"#])
        #expect(try page.evaluate("window.fromUserScript") == "5")
        page.content.removeScriptMessageHandler("host")
        page.content.removeAllUserScripts()
        try page.load(html: "<p>Again</p>")
        #expect(try page.evaluate("typeof window.fromUserScript") == #""undefined""#)
    }

    // MARK: The view

    @Test func drawsFramesWhileAttached() throws {
        let page = try Page()
        try page.load(html: "<body style='margin: 0; background: rgb(255, 0, 0)'>")
        // Not shown, a page publishes nothing.
        WPEEngine.dispatch(for: 0.3) { false }
        #expect(page.content.surface.takeFrame() == nil)
        #expect(!page.content.isAttached)

        page.content.attach(width: 200, height: 100, scale: 1)
        #expect(page.content.isAttached)
        // The first frames can come before the page has painted.
        var frame = page.content.surface.takeFrame()
        try wait(for: "a red frame") {
            if let next = page.content.surface.takeFrame() { frame = next }
            guard let frame, frame.pixels.count >= 4 else { return false }
            return Array(frame.pixels.prefix(4)) == [0, 0, 255, 255]
        }
        let drawn = try #require(frame)
        #expect(drawn.width == 200)
        #expect(drawn.height == 100)
        #expect(drawn.format == .bgra)
        #expect(drawn.rowOrder == .topFirst)

        page.content.detach()
        #expect(page.content.size == nil)
    }

    @Test func drawsAtItsScaleAndSize() throws {
        let page = try Page()
        page.content.attach(width: 100, height: 50, scale: 2)
        try page.load(html: "<body style='margin: 0; background: white'>")
        try wait(for: "a frame at the scale") { page.content.surface.pixelSize == CGSize(width: 200, height: 100) }
        #expect(try page.evaluate("window.innerWidth") == "100")
        page.content.resize(width: 150, height: 80, scale: 1)
        try wait(for: "a frame at the new size") { page.content.surface.pixelSize == CGSize(width: 150, height: 80) }
        #expect(try page.evaluate("window.innerWidth") == "150")
        #expect(page.content.size?.width == 150)
    }

    @Test func takesPointerAndKeyInput() throws {
        let page = try Page()
        page.content.attach(width: 300, height: 200, scale: 1)
        page.content.focus(true)
        try page.load(html: """
            <body style='margin: 0'>
            <input id=field style='position: absolute; left: 0; top: 0; width: 200px; height: 40px'>
            <script>
            var clicks = 0;
            document.getElementById('field').addEventListener('click', () => clicks += 1);
            </script>
            """)
        page.content.pointerMoved(x: 50, y: 20)
        page.content.pointerButton(.primary, pressed: true, x: 50, y: 20, modifiers: .button1)
        page.content.pointerButton(.primary, pressed: false, x: 50, y: 20)
        try wait(for: "the click") { (try? page.evaluate("clicks")) == "1" }
        #expect(try page.evaluate("document.activeElement.id") == #""field""#)
        page.content.type("Hi é")
        try wait(for: "the text") { (try? page.evaluate("document.getElementById('field').value")) == #""Hi é""# }
        page.content.key(keysym: WPEKeysym.backspace, pressed: true)
        page.content.key(keysym: WPEKeysym.backspace, pressed: false)
        try wait(for: "the deletion") { (try? page.evaluate("document.getElementById('field').value")) == #""Hi ""# }
    }

    @Test func scrolls() throws {
        let page = try Page()
        page.content.attach(width: 300, height: 200, scale: 1)
        try page.load(html: "<body style='margin: 0'><div style='height: 5000px'>Tall</div>")
        func offset() -> Double? {
            (try? page.evaluate("window.scrollY")).flatMap { $0 }.flatMap(Double.init)
        }
        page.content.pointerMoved(x: 100, y: 100)
        // A page drops the scrolls that come before it can scroll, and
        // animates the ones it takes, so this asks until it has moved and
        // checks only which way.
        var scrolled: Double = 0
        for _ in 0 ..< 40 where scrolled == 0 {
            page.content.scroll(x: 100, y: 100, dx: 0, dy: 120)
            page.content.scroll(x: 100, y: 100, dx: 0, dy: 0)
            WPEEngine.dispatch(for: 0.5) { false }
            scrolled = offset() ?? 0
        }
        #expect(scrolled > 0)
        for _ in 0 ..< 40 where scrolled != 0 {
            page.content.scroll(x: 100, y: 100, dx: 0, dy: -5000)
            page.content.scroll(x: 100, y: 100, dx: 0, dy: 0)
            WPEEngine.dispatch(for: 0.5) { false }
            scrolled = offset() ?? -1
        }
        #expect(scrolled == 0)
    }
}

@Suite struct WPEKeysymTests {

    @Test func mapsCharactersToKeySymbols() {
        #expect(WPEKeysym.keysym(for: "a") == 0x61)
        #expect(WPEKeysym.keysym(for: "é") == 0xE9)
        #expect(WPEKeysym.keysym(for: "日") == 0x0100_65E5)
        #expect(WPEKeysym.keysym(for: "\n") == WPEKeysym.return)
        #expect(WPEKeysym.keysym(for: "\u{1}") == nil)
        #expect(WPEKeysym.keysym(for: "\u{F700}") == nil)
    }

    @Test func namesTheModifierOfAButton() {
        #expect(WPEButton.primary.modifier == .button1)
        #expect(WPEButton(rawValue: 0) == nil)
    }
}
