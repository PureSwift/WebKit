import CacaoHost
import Foundation
import Observation
import WPEWebKit

/// A page of web content: what it shows, how far it has loaded, and where
/// it can go. Show it with `WebView(page)`.
///
/// It's observable, so a view that reads `title` or `estimatedProgress`
/// updates as the page loads:
///
/// ```swift
/// let page = WebPage()
/// page.load("https://swift.org")
///
/// // In a view's body:
/// if page.isLoading {
///     ProgressView(value: page.estimatedProgress)
/// }
/// WebView(page)
/// ```
///
/// This is AppRuntime's `WebPage`, over WPE WebKit. The page lives in the
/// engine (`WPEWebContent`), which is made the first time the page is loaded
/// or shown. It keeps loading while it's off screen, and is destroyed when
/// the `WebPage` is released.
@MainActor
@Observable
public final class WebPage {

    /// Whether WPE WebKit is installed. Without it a load fails, and the
    /// page's view says so.
    public nonisolated static var isAvailable: Bool { WPEEngine.isAvailable }

    // MARK: State

    /// The main frame's URL, once a navigation has committed.
    public private(set) var url: String?

    public private(set) var title: String = ""

    public private(set) var isLoading = false

    /// 0…1.
    public private(set) var estimatedProgress: Double = 0

    public private(set) var canGoBack = false

    public private(set) var canGoForward = false

    /// Why the last navigation failed; `nil` again once another starts.
    public private(set) var error: WebError?

    /// Decides whether the page may follow a navigation it or the user
    /// started: a link, a form, a script, back and forward. Called before
    /// each one; `nil` allows them all. `load` isn't asked about.
    ///
    /// ```swift
    /// page.navigationDecider = { $0.url.hasPrefix("https://example.com/") }
    /// ```
    @ObservationIgnored
    public var navigationDecider: ((WebNavigation) -> Bool)?

    /// Called when the main frame finishes loading.
    @ObservationIgnored
    public var onFinish: (() -> Void)?

    public init() { }

    isolated deinit {
        receiver.page = nil
        for (_, completion) in scripts {
            completion(.failure(WebError(.cancelled)))
        }
    }

    // MARK: Loading

    /// Loads `url`. A remote one fails with `WebError.Code.notPermitted`
    /// while the network isn't allowed.
    public func load(_ url: String) {
        guard let content else { return unavailable() }
        content.load(url)
        WebLoop.pump()
    }

    /// Shows `html`. Relative URLs in it resolve against `baseURL`.
    public func load(html: String, baseURL: String? = nil) {
        guard let content else { return unavailable() }
        content.loadHTML(html, baseURL: baseURL)
        WebLoop.pump()
    }

    /// Loads a file from the app bundle's resources, such as
    /// `"help/index.html"`. Files beside it are readable to the page.
    public func load(resource path: String) {
        guard let content else { return unavailable() }
        guard let file = WebPage.resourceFile(path) else {
            error = WebError(.badURL, message: "no resource \(path) in the app's bundle")
            return
        }
        content.load(URL(fileURLWithPath: file).absoluteString)
        WebLoop.pump()
    }

    public func reload() {
        content?.reload()
        WebLoop.pump()
    }

    public func stopLoading() {
        content?.stopLoading()
        WebLoop.pump()
    }

    public func goBack() {
        content?.goBack()
        WebLoop.pump()
    }

    public func goForward() {
        content?.goForward()
        WebLoop.pump()
    }

    private func unavailable() {
        error = WebError(.unknown, message: "WPE WebKit isn't installed")
    }

    /// A resource's file in the bundle's resources, if it's there and
    /// inside them.
    static func resourceFile(_ path: String, in bundle: Bundle = .main) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        let root = resources.standardizedFileURL.path
        let file = URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL.path
        guard file.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return file
    }

    // MARK: Scripts

    /// Evaluates `script` in the page. `completion` gets its value as JSON
    /// text (`nil` for `undefined` and values JSON can't hold), or the
    /// exception it threw. Pass `nil` to run a script for its effect.
    public func evaluateJavaScript(_ script: String, completion: ((Result<String?, WebError>) -> Void)?) {
        guard let content else {
            completion?(.failure(WebError(.unknown, message: "WPE WebKit isn't installed")))
            return
        }
        let request = nextRequest
        nextRequest = nextRequest == .max ? 1 : nextRequest + 1
        if let completion {
            scripts[request] = completion
        }
        content.evaluateJavaScript(script, request: request)
        WebLoop.pump()
    }

    /// Evaluates `script` in the page and returns its value as JSON text:
    /// `nil` for `undefined` and values JSON can't hold.
    ///
    /// ```swift
    /// let height = try await page.evaluateJavaScript("document.body.scrollHeight")
    /// ```
    ///
    /// - Throws: `WebError` with `.javaScript` when the script throws.
    public func evaluateJavaScript(_ script: String) async throws(WebError) -> String? {
        let result: Result<String?, WebError> = await withCheckedContinuation { continuation in
            evaluateJavaScript(script) { continuation.resume(returning: $0) }
        }
        return try result.get()
    }

    // MARK: The engine's page

    /// The engine's page, for what this class doesn't cover: user scripts,
    /// script messages, the user agent. Asking makes it. Nil where WPE
    /// WebKit isn't installed.
    public var content: WPEWebContent? {
        if let made {
            return made
        }
        guard !triedMaking else { return nil }
        triedMaking = true
        receiver.page = self
        made = WPEWebContent.make(receiver)
        if made != nil {
            WebLoop.start()
        }
        return made
    }

    /// The engine page's identifier, as AppRuntime's hosts name pages.
    public var identifier: Int32 {
        content?.identifier() ?? 0
    }

    @ObservationIgnored
    private var made: WPEWebContent?

    @ObservationIgnored
    private var triedMaking = false

    @ObservationIgnored
    private let receiver = Receiver()

    @ObservationIgnored
    private var nextRequest: Int32 = 1

    @ObservationIgnored
    private var scripts: [Int32: (Result<String?, WebError>) -> Void] = [:]

    @ObservationIgnored
    let input = WebInput()

    // MARK: The view

    /// A view shows the page at a size in points and a scale.
    func show(size: CGSize, scale: CGFloat) {
        guard let content else { return }
        content.attach(width: UInt32(max(1, size.width.rounded())), height: UInt32(max(1, size.height.rounded())), scale: Float(scale))
        WebLoop.pump()
    }

    /// The view went: the page stays loaded, hidden and unfocused.
    func hide() {
        input.reset()
        made?.detach()
        WebLoop.pump()
    }

    // MARK: From the engine

    fileprivate func decide(_ navigation: WebNavigation) -> Bool {
        navigationDecider?(navigation) ?? true
    }

    fileprivate func update(url: String?) {
        if url != self.url { self.url = url }
    }

    fileprivate func update(title: String) {
        if title != self.title { self.title = title }
    }

    fileprivate func update(isLoading: Bool, progress: Double) {
        if isLoading, !self.isLoading, error != nil {
            // Another navigation started.
            error = nil
        }
        if isLoading != self.isLoading { self.isLoading = isLoading }
        if progress != estimatedProgress { estimatedProgress = progress }
    }

    fileprivate func update(canGoBack: Bool, canGoForward: Bool) {
        if canGoBack != self.canGoBack { self.canGoBack = canGoBack }
        if canGoForward != self.canGoForward { self.canGoForward = canGoForward }
    }

    fileprivate func finished() {
        onFinish?()
    }

    fileprivate func failed(_ error: WebError) {
        self.error = error
    }

    fileprivate func evaluated(_ request: Int32, _ result: Result<String?, WebError>) {
        scripts.removeValue(forKey: request)?(result)
    }
}

/// The delegate the engine's page holds. It doesn't keep the `WebPage`
/// alive: the page owns the engine's page, which owns this.
private final class Receiver: WPEWebContentDelegate, @unchecked Sendable {

    nonisolated(unsafe) weak var page: WebPage?

    /// The engine calls on the main thread, where the page lives.
    private func onPage<Result: Sendable>(_ body: @MainActor @Sendable (WebPage) -> Result) -> Result? {
        let page = page
        return MainActor.assumeIsolated {
            guard let page else { return nil }
            return body(page)
        }
    }

    func shouldNavigate(_ content: WPEWebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        let navigation = WebNavigation(url: url, kind: WebNavigationKind(rawValue: kind) ?? .other, isMainFrame: isMainFrame)
        return onPage { $0.decide(navigation) } ?? true
    }

    func didChangeURL(_ content: WPEWebContent, url: String?) {
        onPage { $0.update(url: url) }
    }

    func didChangeTitle(_ content: WPEWebContent, title: String) {
        onPage { $0.update(title: title) }
    }

    func didChangeLoading(_ content: WPEWebContent, isLoading: Bool, progress: Double) {
        onPage { $0.update(isLoading: isLoading, progress: progress) }
    }

    func didChangeHistory(_ content: WPEWebContent, canGoBack: Bool, canGoForward: Bool) {
        onPage { $0.update(canGoBack: canGoBack, canGoForward: canGoForward) }
    }

    func didFinishNavigation(_ content: WPEWebContent) {
        onPage { $0.finished() }
    }

    func didFailNavigation(_ content: WPEWebContent, error: Int32, message: String) {
        onPage { $0.failed(WebError(WebError.Code(rawValue: error) ?? .unknown, message: message)) }
    }

    func didEvaluateJavaScript(_ content: WPEWebContent, request: Int32, result: String?, error: String?) {
        onPage {
            if let error {
                $0.evaluated(request, .failure(WebError(.javaScript, message: error)))
            } else {
                $0.evaluated(request, .success(result))
            }
        }
    }
}

/// The engine's loop inside Cacao's: the host's loop runs the pages each
/// time it wakes, and the engine wakes it when they have work.
@MainActor
enum WebLoop {

    private static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true
        WPEEngine.onReady = { HostRuntime.wake() }
        HostRuntime.addWakeHook { WPEEngine.pump() }
    }

    /// Runs the pages now, and watches for what a call just set off.
    static func pump() {
        WPEEngine.pump()
    }
}
