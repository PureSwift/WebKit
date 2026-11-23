import Foundation
import Testing
import WPEWebKit
@testable import Cacao
@testable import CacaoWebKit

/// `WebView` over an engine's page made elsewhere, in a Cacao view graph.
@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WebViewTests {

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// What the host's own page heard, as a host's delegate would.
    final class Host: WPEWebContentDelegate {
        var title = ""
        var finished = false
        var scripts: [Int32: String?] = [:]
        func shouldNavigate(_ content: WPEWebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool { true }
        func didChangeURL(_ content: WPEWebContent, url: String?) { }
        func didChangeTitle(_ content: WPEWebContent, title: String) { self.title = title }
        func didChangeLoading(_ content: WPEWebContent, isLoading: Bool, progress: Double) { }
        func didChangeHistory(_ content: WPEWebContent, canGoBack: Bool, canGoForward: Bool) { }
        func didFinishNavigation(_ content: WPEWebContent) { finished = true }
        func didFailNavigation(_ content: WPEWebContent, error: Int32, message: String) { }
        func didEvaluateJavaScript(_ content: WPEWebContent, request: Int32, result: String?, error: String?) {
            scripts[request] = result
        }
    }

    struct Root: View {
        var content: WPEWebContent
        var shown: Bool
        var body: some View {
            VStack {
                if shown {
                    WebView(content: content)
                        .frame(width: 200, height: 100)
                }
            }
        }
    }

    func wait(for what: String, until condition: () -> Bool) throws {
        guard WPEEngine.dispatch(for: 20, until: condition) else {
            throw Failure(description: "timed out waiting for \(what)")
        }
    }

    @Test func showsAndSendsInputToAPageMadeElsewhere() throws {
        let host = Host()
        let content = try #require(WPEWebContent(delegate: host))
        content.loadHTML("""
            <title>Shown</title>
            <body style='margin: 0'>
            <button style='position: absolute; left: 0; top: 0; width: 200px; height: 100px'
                    onclick='document.title = "Clicked"'>Go</button>
            """, baseURL: nil)
        try wait(for: "the load") { host.finished && host.title == "Shown" }
        #expect(!content.isAttached)

        let graph = ViewGraph(rootView: Root(content: content, shown: true))
        graph.layout(in: CGSize(width: 200, height: 100))
        _ = graph.displayList()
        #expect(content.isAttached)
        try wait(for: "a frame") { content.surface.pixelSize == CGSize(width: 200, height: 100) }

        let point = CGPoint(x: 100, y: 50)
        #expect(graph.externalPointer(.began, button: .primary, at: point))
        #expect(graph.externalPointer(.ended, button: .primary, at: point))
        try wait(for: "the click") { host.title == "Clicked" }

        graph.setRootView(Root(content: content, shown: false))
        graph.update()
        #expect(!content.isAttached)
        // The page stays loaded, for whoever made it.
        content.evaluateJavaScript("document.title", request: 1)
        try wait(for: "the script") { host.scripts[1] != nil }
        #expect(host.scripts[1] == #""Clicked""#)
    }

    @Test func scrollsThePageWithTheWheel() throws {
        let host = Host()
        let content = try #require(WPEWebContent(delegate: host))
        content.loadHTML("<body style='margin: 0'><div style='height: 5000px'></div>", baseURL: nil)
        try wait(for: "the load") { host.finished }
        let graph = ViewGraph(rootView: Root(content: content, shown: true))
        graph.layout(in: CGSize(width: 200, height: 100))
        _ = graph.displayList()
        try wait(for: "a frame") { content.surface.pixelSize == CGSize(width: 200, height: 100) }

        var request: Int32 = 0
        func scrollY() -> String? {
            request += 1
            let asked = request
            content.evaluateJavaScript("window.scrollY", request: asked)
            _ = WPEEngine.dispatch(for: 5) { host.scripts[asked] != nil }
            return host.scripts[asked] ?? nil
        }
        #expect(scrollY() == "0")
        let point = CGPoint(x: 100, y: 50)
        // A notch toward the user moves down the page by one notch's points.
        #expect(graph.externalScroll(x: 0, y: -1, at: point))
        try wait(for: "the scroll down") { scrollY() == "\(Int(WebInput.notch))" }
        #expect(graph.externalScroll(x: 0, y: 1, at: point))
        try wait(for: "the scroll back") { scrollY() == "0" }
    }
}
