import Foundation
import WPEWebKit

// WebKit's main thread is the first that calls it. The tests are on the main
// actor, so it is the main thread, as it is in an app.

struct TimedOut: Error, CustomStringConvertible {
    var waitingFor: String
    var description: String { "timed out waiting for \(waitingFor)" }
}

/// Runs the engine's loop until `condition` holds.
@MainActor
func wait(for what: String, seconds: Double = 20, until condition: () -> Bool) throws {
    guard WPEEngine.dispatch(for: seconds, until: condition) else {
        throw TimedOut(waitingFor: what)
    }
}

/// Records what a page tells its delegate, and answers `shouldNavigate`.
final class RecordingDelegate: WPEWebContentDelegate {

    var events: [String] = []

    var allows = true

    var scripts: [Int32: (result: String?, error: String?)] = [:]

    func shouldNavigate(_ content: WPEWebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        events.append("should \(kind) \(url)")
        return allows
    }

    func didChangeURL(_ content: WPEWebContent, url: String?) {
        events.append("url \(url ?? "nil")")
    }

    func didChangeTitle(_ content: WPEWebContent, title: String) {
        events.append("title \(title)")
    }

    func didChangeLoading(_ content: WPEWebContent, isLoading: Bool, progress: Double) {
        events.append(isLoading ? "loading" : "loaded \(progress)")
    }

    func didChangeHistory(_ content: WPEWebContent, canGoBack: Bool, canGoForward: Bool) {
        events.append("history \(canGoBack) \(canGoForward)")
    }

    func didFinishNavigation(_ content: WPEWebContent) {
        events.append("finish")
    }

    func didFailNavigation(_ content: WPEWebContent, error: Int32, message: String) {
        events.append("fail \(error)")
    }

    func didEvaluateJavaScript(_ content: WPEWebContent, request: Int32, result: String?, error: String?) {
        scripts[request] = (result, error)
    }

    var finishes: Int { events.filter { $0 == "finish" }.count }

    var title: String? {
        events.last { $0.hasPrefix("title ") }.map { String($0.dropFirst(6)) }
    }

    var url: String? {
        events.last { $0.hasPrefix("url ") }.map { String($0.dropFirst(4)) }
    }
}

/// A page and the delegate that records it.
@MainActor
struct Page {

    let delegate = RecordingDelegate()

    let content: WPEWebContent

    init() throws {
        guard let content = WPEWebContent(delegate: delegate) else {
            throw TimedOut(waitingFor: "a page from WPE WebKit")
        }
        self.content = content
    }

    /// Shows markup and waits for the load to finish.
    func load(html: String, baseURL: String? = nil) throws {
        let before = delegate.finishes
        content.loadHTML(html, baseURL: baseURL)
        try wait(for: "the load") { delegate.finishes > before }
    }

    /// Runs a script and waits for its value as JSON.
    func evaluate(_ script: String) throws -> String? {
        var outcome: Result<String?, WPEError>?
        content.evaluateJavaScript(script) { outcome = $0 }
        try wait(for: "the script") { outcome != nil }
        return try outcome!.get()
    }

    /// Runs a script as an async function's body and waits for what it
    /// returns, as JSON.
    func callAsync(_ body: String) throws -> String? {
        var outcome: Result<String?, WPEError>?
        content.callAsyncJavaScript(body) { outcome = $0 }
        try wait(for: "the function") { outcome != nil }
        return try outcome!.get()
    }
}
