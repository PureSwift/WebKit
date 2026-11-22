import Cacao
import Foundation
import Observation
import Testing
import WPEWebKit
@testable import CacaoWebKit

/// Runs the engine's loop until `condition` holds, as Cacao's host would.
@MainActor
private func wait(for what: String, until condition: () -> Bool) throws {
    struct TimedOut: Error, CustomStringConvertible {
        var description: String
    }
    guard WPEEngine.dispatch(for: 20, until: condition) else {
        throw TimedOut(description: "timed out waiting for \(what)")
    }
}

/// Runs the engine's loop while an async call waits on it.
@MainActor
private func pumping<Result>(_ body: @MainActor () async throws -> Result) async rethrows -> Result {
    let pump = Task { @MainActor in
        while !Task.isCancelled {
            WPEEngine.dispatch()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    defer { pump.cancel() }
    return try await body()
}

@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WebPageTests {

    @Test func followsALoad() throws {
        let page = WebPage()
        #expect(page.title == "")
        #expect(page.url == nil)
        #expect(!page.isLoading)
        var finishes = 0
        page.onFinish = { finishes += 1 }
        page.load(html: "<title>Hello</title><p>Text</p>", baseURL: "https://example.invalid/page")
        try wait(for: "the load") { finishes == 1 && page.title == "Hello" }
        #expect(page.url == "https://example.invalid/page")
        #expect(!page.isLoading)
        #expect(page.estimatedProgress == 1)
        #expect(page.error == nil)
        #expect(!page.canGoBack)
        #expect(page.identifier != 0)
    }

    @Test func tellsViewsWhatChanged() throws {
        let page = WebPage()
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = page.title
        } onChange: {
            changed = true
        }
        page.load(html: "<title>Observed</title>")
        try wait(for: "the title") { page.title == "Observed" }
        #expect(changed)
    }

    @Test func reportsAFailedLoad() throws {
        let page = WebPage()
        page.load("not a url")
        #expect(page.error?.code == .badURL)
        page.load("file:///nonexistent/\(UUID().uuidString).html")
        try wait(for: "the failure") { page.error != nil && !page.isLoading && page.error?.code != .badURL || page.estimatedProgress == 1 }
        #expect(page.error != nil)
        page.load(html: "<title>After</title>")
        try wait(for: "the next load") { page.title == "After" && !page.isLoading }
        #expect(page.error == nil)
    }

    @Test func refusesResourcesOutsideTheBundle() {
        let page = WebPage()
        page.load(resource: "../../../etc/passwd")
        #expect(page.error?.code == .badURL)
        #expect(WebPage.resourceFile("nothing-\(UUID().uuidString).html") == nil)
    }

    @Test func evaluatesJavaScript() async throws {
        let page = WebPage()
        page.load(html: "<title>Script</title>")
        try wait(for: "the load") { !page.isLoading && page.title == "Script" }
        var heard: Result<String?, WebError>?
        page.evaluateJavaScript("6 * 7") { heard = $0 }
        try wait(for: "the completion") { heard != nil }
        #expect(try heard?.get() == "42")
        try await pumping {
            #expect(try await page.evaluateJavaScript("document.title") == #""Script""#)
            #expect(try await page.evaluateJavaScript("undefined") == nil)
            do {
                _ = try await page.evaluateJavaScript("missing()")
                Issue.record("the script should have thrown")
            } catch let error as WebError {
                #expect(error.code == .javaScript)
                #expect(error.message.contains("missing"))
            }
        }
    }

    @Test func asksItsDeciderAboutNavigations() throws {
        let page = WebPage()
        page.load(html: "<title>Start</title><a id=link href='https://example.invalid/next'>Next</a>")
        try wait(for: "the load") { !page.isLoading && page.title == "Start" }
        var asked: [WebNavigation] = []
        page.navigationDecider = { navigation in
            asked.append(navigation)
            return false
        }
        page.evaluateJavaScript("document.getElementById('link').click()", completion: nil)
        try wait(for: "the question") { !asked.isEmpty }
        #expect(asked == [WebNavigation(url: "https://example.invalid/next", kind: .linkActivated, isMainFrame: true)])
        #expect(page.title == "Start")
        #expect(page.error == nil)
    }

    @Test func sendsTheViewsInputToThePage() async throws {
        let page = WebPage()
        let content = try #require(page.content)
        page.show(size: CGSize(width: 300, height: 200), scale: 1)
        page.load(html: """
            <title>Input</title>
            <body style='margin: 0'>
            <input id=field style='position: absolute; left: 0; top: 0; width: 200px; height: 40px'>
            <script>
            var clicks = 0;
            document.getElementById('field').addEventListener('click', () => clicks += 1);
            </script>
            """)
        try wait(for: "the load") { !page.isLoading && page.title == "Input" }
        func eventually(_ what: String, _ script: String, is expected: String) throws {
            var value: String?
            let held = WPEEngine.dispatch(for: 20) {
                var outcome: Result<String?, WPEError>?
                content.evaluateJavaScript("String(\(script))") { outcome = $0 }
                WPEEngine.dispatch(for: 5) { outcome != nil }
                value = (try? outcome?.get()) ?? nil
                return value == "\"\(expected)\""
            }
            if !held {
                Issue.record("timed out waiting for \(what): \(value ?? "nil")")
            }
        }
        let point = CGPoint(x: 50, y: 20)
        page.input.handle(.focus(true), for: content)
        page.input.handle(.hover(location: point), for: content)
        page.input.handle(.pointer(.began, button: .primary, location: point), for: content)
        page.input.handle(.pointer(.ended, button: .primary, location: point), for: content)
        try eventually("the click", "clicks", is: "1")
        page.input.handle(.text("Hi é"), for: content)
        try eventually("the text", "document.getElementById('field').value", is: "Hi é")
        // Backspace, by its usage on a USB keyboard.
        page.input.handle(.key(.init(isDown: true, usage: 0x2A, keyCode: 8)), for: content)
        page.input.handle(.key(.init(isDown: false, usage: 0x2A, keyCode: 8)), for: content)
        try eventually("the deletion", "document.getElementById('field').value", is: "Hi ")
        // A letter alone arrives as text, so its key is not sent as well.
        page.input.handle(.key(.init(isDown: true, usage: 0x04, keyCode: 0x61)), for: content)
        page.input.handle(.key(.init(isDown: false, usage: 0x04, keyCode: 0x61)), for: content)
        // A finger that doesn't move taps.
        page.input.handle(.touch(.began, finger: 1, location: point), for: content)
        page.input.handle(.touch(.ended, finger: 1, location: point), for: content)
        try eventually("the tap", "clicks", is: "2")
        try eventually("the unchanged text", "document.getElementById('field').value", is: "Hi ")
        page.hide()
        #expect(!content.isAttached)
    }

    @Test func mapsInputToTheEngines() {
        #expect(WebInput.modifiers([.control, .option]) == [.control, .alt])
        #expect(WebInput.modifiers([.shift, .command]) == [.shift, .meta])
        #expect(WebInput.modifiers([]) == [])
        #expect(WebInput.button(.secondary) == .secondary)
        #expect(WebInput.keysyms[0x52] == WPEKeysym.up)
    }

    @Test func numbersItsTypesAsTheEngineDoes() {
        #expect(WebError.Code.notPermitted.rawValue == WPEWebContent.ErrorCode.notPermitted.rawValue)
        #expect(WebError.Code.security.rawValue == WPEWebContent.ErrorCode.security.rawValue)
        #expect(WebNavigationKind.other.rawValue == WPEWebContent.NavigationKind.other.rawValue)
        #expect(WebNavigationKind.backForward.rawValue == WPEWebContent.NavigationKind.backForward.rawValue)
    }
}
