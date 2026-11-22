import Foundation
import Testing
import WPEWebKit

/// Pages in WPE WebKit itself, where it is installed. Nothing here reaches
/// the network.
@Suite(.enabled(if: WebThread.isAvailable, "WPE WebKit isn't installed"))
struct WPEPageTests {

    @Test func loadsMarkup() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            var events: [WPELoadEvent] = []
            var properties: Set<WPEPageProperty> = []
            page.onLoadChanged = { events.append($0) }
            page.onPropertyChanged = { properties.insert($0) }
            try page.loadAndWait(html: "<title>Hello</title><p>Text</p>")
            try wait(for: "the title") { page.title == "Hello" }
            #expect(events == [.started, .committed, .finished])
            #expect(properties.isSuperset(of: [.title, .isLoading, .estimatedLoadProgress]))
            #expect(!page.isLoading)
            #expect(page.estimatedLoadProgress == 1)
            #expect(!page.canGoBack)
        }
    }

    @Test func countsPages() throws {
        try WebThread.shared.run {
            let before = WPEEngine.pageCount
            var counts: [Int] = []
            WPEEngine.onPageCountChanged = { counts.append($0) }
            defer { WPEEngine.onPageCountChanged = nil }
            do {
                let page = try #require(WPEPage())
                withExtendedLifetime(page) {
                    #expect(WPEEngine.pageCount == before + 1)
                }
            }
            #expect(counts == [before + 1, before])
        }
    }

    @Test func evaluatesScripts() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            try page.loadAndWait(html: "<p id=a>Text</p>")
            #expect(try page.evaluate("1 + 2") == "3")
            #expect(try page.evaluate("document.getElementById('a').textContent") == #""Text""#)
            #expect(try page.evaluate("({ list: [1, true] })") == #"{"list":[1,true]}"#)
            #expect(try page.evaluate("undefined") == nil)
            let error = try #require(throws: WPEError.self) { try page.evaluate("missing()") }
            #expect(error.message.contains("missing"))
        }
    }

    @Test func awaitsAsyncScripts() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            try page.loadAndWait(html: "<p>Text</p>")
            var outcome: Result<String?, WPEError>?
            page.callAsyncJavaScript("return await new Promise(resolve => setTimeout(() => resolve(7), 10))") { outcome = $0 }
            try wait(for: "the function") { outcome != nil }
            #expect(try outcome?.get() == "7")
        }
    }

    @Test func drawsFramesIntoItsSurface() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage(width: 200, height: 100, scale: 1))
            page.isVisible = true
            try page.loadAndWait(html: "<body style='margin: 0; background: rgb(255, 0, 0)'>")
            // The first frames can come before the page has painted.
            var frame = page.surface.takeFrame()
            try wait(for: "a red frame") {
                if let next = page.surface.takeFrame() { frame = next }
                guard let frame, frame.pixels.count >= 4 else { return false }
                return Array(frame.pixels.prefix(4)) == [0, 0, 255, 255]
            }
            let drawn = try #require(frame)
            #expect(drawn.width == 200)
            #expect(drawn.height == 100)
            #expect(drawn.format == .bgra)
            #expect(drawn.rowOrder == .topFirst)
        }
    }

    @Test func drawsAtItsScaleAndSize() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage(width: 100, height: 50, scale: 2))
            page.isVisible = true
            try page.loadAndWait(html: "<body style='margin: 0; background: white'>")
            try wait(for: "a frame at the scale") { page.surface.pixelSize == CGSize(width: 200, height: 100) }
            #expect(try page.evaluate("window.innerWidth") == "100")
            page.resize(width: 150, height: 80, scale: 1)
            try wait(for: "a frame at the new size") { page.surface.pixelSize == CGSize(width: 150, height: 80) }
            #expect(try page.evaluate("window.innerWidth") == "150")
            #expect(page.size.width == 150)
        }
    }

    @Test func asksAboutNavigations() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            try page.loadAndWait(html: "<a id=link href='https://example.invalid/next'>Next</a>")
            var asked: [WPENavigation] = []
            page.onNavigation = { navigation, decision in
                asked.append(navigation)
                decision.cancel()
            }
            _ = try page.evaluate("document.getElementById('link').click()")
            try wait(for: "the question") { !asked.isEmpty }
            #expect(asked.first?.uri == "https://example.invalid/next")
            #expect(asked.first?.kind == .linkClicked)
            #expect(asked.first?.opensNewWindow == false)
            // Cancelled, the page stays where it was.
            #expect(try page.evaluate("document.getElementById('link') != null") == "true")
        }
    }

    @Test func followsNavigationsItAllows() throws {
        try WebThread.shared.run {
            // Files, because a page can't send its top frame to a data URI.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.html")
            try Data("<title>First</title><a id=link href='second.html'>Next</a>".utf8).write(to: first)
            try Data("<title>Second</title>".utf8).write(to: directory.appendingPathComponent("second.html"))
            let page = try #require(WPEPage())
            page.load(uri: first.absoluteString)
            try wait(for: "the first page") { page.title == "First" && !page.isLoading }
            var decisions: [WPEPolicyDecision] = []
            page.onNavigation = { _, decision in decisions.append(decision) }
            _ = try page.evaluate("document.getElementById('link').click()")
            try wait(for: "the question") { !decisions.isEmpty }
            // Answered later, as a host that asks its user would.
            #expect(page.title == "First")
            decisions.removeFirst().allow()
            try wait(for: "the second page") { page.title == "Second" }
            #expect(page.canGoBack)
            // Going back is a navigation too, asked about as any other.
            page.onNavigation = { navigation, decision in
                #expect(navigation.kind == .backForward)
                decision.allow()
            }
            page.goBack()
            try wait(for: "the first page again") { page.title == "First" }
            #expect(page.canGoForward)
        }
    }

    @Test func runsUserScriptsAndHearsTheirMessages() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            var messages: [String] = []
            page.onScriptMessage = { name, body in messages.append("\(name) \(body ?? "undefined")") }
            page.addScriptMessageHandler("host")
            page.addUserScript("window.fromUserScript = 5; window.webkit.messageHandlers.host.postMessage({ ready: true })",
                               atDocumentStart: true)
            try page.loadAndWait(html: "<p>Text</p>")
            try wait(for: "the message") { !messages.isEmpty }
            #expect(messages == [#"host {"ready":true}"#])
            #expect(try page.evaluate("window.fromUserScript") == "5")
            page.removeScriptMessageHandler("host")
            page.removeAllUserScripts()
            try page.loadAndWait(html: "<p>Again</p>")
            #expect(try page.evaluate("typeof window.fromUserScript") == #""undefined""#)
        }
    }

    @Test func takesPointerAndKeyInput() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage(width: 300, height: 200, scale: 1))
            page.isVisible = true
            page.isFocused = true
            try page.loadAndWait(html: """
                <body style='margin: 0'>
                <input id=field style='position: absolute; left: 0; top: 0; width: 200px; height: 40px'>
                <script>
                var clicks = 0;
                document.getElementById('field').addEventListener('click', () => clicks += 1);
                </script>
                """)
            page.pointerMoved(x: 50, y: 20)
            page.pointerButton(.primary, pressed: true, x: 50, y: 20, modifiers: .button1)
            page.pointerButton(.primary, pressed: false, x: 50, y: 20)
            try wait(for: "the click") { (try? page.evaluate("clicks")) == "1" }
            #expect(try page.evaluate("document.activeElement.id") == #""field""#)
            page.type("Hi é")
            try wait(for: "the text") { (try? page.evaluate("document.getElementById('field').value")) == #""Hi é""# }
            page.key(keysym: WPEKeysym.backspace, pressed: true)
            page.key(keysym: WPEKeysym.backspace, pressed: false)
            try wait(for: "the deletion") { (try? page.evaluate("document.getElementById('field').value")) == #""Hi ""# }
        }
    }

    @Test func scrolls() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage(width: 300, height: 200, scale: 1))
            page.isVisible = true
            try page.loadAndWait(html: "<body style='margin: 0'><div style='height: 5000px'>Tall</div>")
            func offset() -> Double? {
                (try? page.evaluate("window.scrollY")).flatMap { $0 }.flatMap(Double.init)
            }
            page.pointerMoved(x: 100, y: 100)
            // A page drops the scrolls that come before it can scroll, and
            // animates the ones it takes, so this asks until it has moved
            // and checks only which way.
            var scrolled: Double = 0
            for _ in 0 ..< 40 where scrolled == 0 {
                page.scroll(x: 100, y: 100, dx: 0, dy: 120)
                page.scroll(x: 100, y: 100, dx: 0, dy: 0)
                WPEEngine.dispatch(for: 0.5) { false }
                scrolled = offset() ?? 0
            }
            #expect(scrolled > 0)
            for _ in 0 ..< 40 where scrolled != 0 {
                page.scroll(x: 100, y: 100, dx: 0, dy: -5000)
                page.scroll(x: 100, y: 100, dx: 0, dy: 0)
                WPEEngine.dispatch(for: 0.5) { false }
                scrolled = offset() ?? -1
            }
            #expect(scrolled == 0)
        }
    }

    @Test func reportsFailedLoads() throws {
        try WebThread.shared.run {
            let page = try #require(WPEPage())
            var failures: [WPEError] = []
            var finished = false
            page.onLoadFailed = { _, error in failures.append(error) }
            page.onLoadChanged = { if $0 == .finished { finished = true } }
            page.load(uri: "file:///nonexistent/\(UUID().uuidString).html")
            try wait(for: "the failure") { finished }
            #expect(failures.count == 1)
            #expect(failures.first?.message.isEmpty == false)
        }
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
