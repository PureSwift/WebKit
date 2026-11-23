import CacaoRender
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// A page of web content: a `WebKitWebView` that draws into an external
/// surface, without its place on screen.
///
/// This is AppRuntime's `WebContent` contract over WPE WebKit, so a host for
/// it is a thin layer on top. The page loads whether or not anything shows
/// it. A view attaches it with its size in points, shows `surface`, and
/// forwards its input. The delegate is called from `WPEEngine.dispatch`, on
/// WebKit's main thread, which is the only thread a page is for.
public final class WPEWebContent {

    typealias Pointer = UnsafeMutableRawPointer

    public let delegate: any WPEWebContentDelegate

    private let id: Int32
    private let library: WPELibrary
    private let exportable: Pointer
    private let backend: Pointer
    private let view: Pointer
    /// The exportable's client data: this page, until it goes.
    private let slot: UnsafeMutablePointer<Pointer?>
    private var handlers: [UInt] = []
    private var messageHandlers: [String: UInt] = [:]

    /// The page's frames: BGRA, premultiplied, top row first, published as
    /// the web process draws them while the page is attached.
    public let surface = ExternalSurface()

    // MARK: What the delegate was last told

    private var reportedURL: String?
    private var reportedTitle = ""
    private var reportedHistory = (canGoBack: false, canGoForward: false)
    private var isLoading = false
    /// A navigation started and hasn't committed: WebKit's `uri` is what
    /// was asked for, not where the page is yet.
    private var isProvisional = false
    /// The navigation in progress failed, so it doesn't finish.
    private var failed = false
    /// The host asked for the next navigation itself (`load`, `loadHTML`,
    /// or a new window it agreed to), so it isn't asked about it.
    private var expectsOwnNavigation = false

    // MARK: Beyond the contract

    /// Asks about a navigation in place of the delegate's `shouldNavigate`,
    /// with the keys and button behind it and an answer that can come
    /// later.
    public var onNavigation: ((WPENavigation, WPEPolicyDecision) -> Void)?

    /// A script posted to `window.webkit.messageHandlers[name]`: the
    /// handler's name and the message as JSON, nil for `undefined`.
    public var onScriptMessage: ((String, String?) -> Void)?

    /// A script posted to a handler that replies, and awaits the reply: the
    /// handler's name, the message as JSON (nil for `undefined`), and the
    /// reply to give, at once or later. Without it, the page's promise
    /// rejects.
    public var onScriptMessageWithReply: ((String, String?, WPEScriptMessageReply) -> Void)?

    /// A request for a URL in one of `urlSchemes`, to finish or fail, at
    /// once or later. Without it, requests fail.
    public var onURLSchemeRequest: ((WPEURLSchemeTask) -> Void)?

    /// The schemes this page's host answers, lowercased.
    public private(set) var urlSchemes: Set<String> = []

    /// Whether the host's own loads (`load`, `loadHTML`) are asked about
    /// too, as other navigations are, for a host whose API asks about its
    /// own loads, as UIWebView's delegate is asked about `loadRequest:`.
    public var asksAboutOwnLoads = false

    /// Each of the main frame's load events, as WebKit gives it, before the
    /// delegate hears what it means: for a host whose own API tells a
    /// navigation's start, commit and finish apart.
    public var onLoadEvent: ((WPELoadEvent) -> Void)?

    /// A load failed, with WebKit's own error (cancellations and
    /// navigations a policy stopped included, which the delegate doesn't
    /// hear) and whether it had committed: for a host that reports errors
    /// in its own terms.
    public var onLoadError: ((WPEError, _ committed: Bool) -> Void)?

    /// Requests not yet answered, failed if the page goes first.
    private var openTasks: [ObjectIdentifier: WeakTask] = [:]

    /// Replies not yet given, rejected if the page goes first.
    private var openReplies: [ObjectIdentifier: WeakReply] = [:]

    // MARK: Making a page

    /// A page that reports to a delegate, which it keeps; nil where WPE
    /// WebKit isn't installed or can't make a view.
    public init?(delegate: any WPEWebContentDelegate) {
        guard let library = WPELibrary.shared else { return nil }
        let slot = UnsafeMutablePointer<Pointer?>.allocate(capacity: 1)
        slot.initialize(to: nil)
        // WebKit destroys the exportable when it is done with the backend.
        guard let exportable = library.exportableCreate(WPEWebContent.client, slot, 800, 600),
              let backend = library.exportableGetViewBackend(exportable),
              let webBackend = library.webViewBackendNew(backend, unsafeBitCast(WPEWebContent.onBackendDestroyed, to: Pointer.self),
                                                         exportable),
              let view = library.webViewNew(webBackend) else {
            WPEEngine.log("can't make a WPE web view")
            return nil
        }
        self.delegate = delegate
        self.library = library
        self.exportable = exportable
        self.backend = backend
        self.view = view
        self.slot = slot
        id = WPEWebContent.nextID
        WPEWebContent.nextID &+= 1
        slot.pointee = Unmanaged.passUnretained(self).toOpaque()
        WPEEngine.applyNetworkPolicy()
        library.viewBackendAddActivityState(backend, WPELibrary.inWindow)
        connect("load-changed", unsafeBitCast(WPEWebContent.onLoadChangedSignal, to: UnsafeRawPointer.self))
        connect("load-failed", unsafeBitCast(WPEWebContent.onLoadFailedSignal, to: UnsafeRawPointer.self))
        connect("load-failed-with-tls-errors", unsafeBitCast(WPEWebContent.onTLSErrorsSignal, to: UnsafeRawPointer.self))
        connect("decide-policy", unsafeBitCast(WPEWebContent.onDecidePolicySignal, to: UnsafeRawPointer.self))
        for property in ["title", "uri", "estimated-load-progress"] {
            connect("notify::\(property)", unsafeBitCast(WPEWebContent.onNotifySignal, to: UnsafeRawPointer.self))
        }
        WPEWebContent.contents[id] = Weak(self)
        WPEWebContent.contentsByView[view] = Weak(self)
        WPEEngine.pageCount += 1
    }

    /// As the contract makes one.
    public static func make(_ delegate: any WPEWebContentDelegate) -> WPEWebContent? {
        WPEWebContent(delegate: delegate)
    }

    private func connect(_ signal: String, _ callback: UnsafeRawPointer) {
        handlers.append(library.signalConnectData(view, signal, callback, Unmanaged.passUnretained(self).toOpaque(), nil, 0))
    }

    deinit {
        for task in openTasks.values {
            task.task?.abandon()
        }
        for reply in openReplies.values {
            reply.reply?.abandon()
        }
        if let manager = contentManager {
            for (name, handler) in messageHandlers {
                library.signalHandlerDisconnect(manager, handler)
                library.unregisterScriptMessageHandler(manager, name, nil)
            }
        }
        for handler in handlers {
            library.signalHandlerDisconnect(view, handler)
        }
        // The slot stays, empty, for a frame still on its way.
        slot.pointee = nil
        WPEWebContent.contentsByView[view] = nil
        library.objectUnref(view)
        WPEWebContent.contents[id] = nil
        WPEEngine.pageCount -= 1
    }

    // MARK: Pages

    private struct Weak {
        weak var content: WPEWebContent?
        init(_ content: WPEWebContent) { self.content = content }
    }

    nonisolated(unsafe) private static var contents: [Int32: Weak] = [:]

    /// The pages by their `WebKitWebView`, for the requests WebKit makes for
    /// them.
    nonisolated(unsafe) private static var contentsByView: [Pointer: Weak] = [:]

    nonisolated(unsafe) private static var nextID: Int32 = 1

    /// What a view carries to say which page it shows. Unique among the
    /// process's pages while this one is alive.
    public func identifier() -> Int32 {
        id
    }

    /// The live page with an identifier.
    public static func content(identifier: Int32) -> WPEWebContent? {
        contents[identifier]?.content
    }

    // MARK: Loading

    /// Starts loading `url`. Progress and failure arrive through the
    /// delegate. A remote URL fails as not permitted while
    /// `WPEEngine.isNetworkAllowed` is off.
    public func load(_ url: String) {
        guard let scheme = WPEWebContent.scheme(of: url) else {
            return delegate.didFailNavigation(self, error: ErrorCode.badURL.rawValue, message: "\(url) isn't a URL")
        }
        if WPEWebContent.remoteSchemes.contains(scheme), !WPEEngine.isNetworkAllowed {
            return delegate.didFailNavigation(self, error: ErrorCode.notPermitted.rawValue, message: WPEWebContent.noNetwork)
        }
        WPEEngine.applyNetworkPolicy()
        startOwnNavigation()
        library.webViewLoadURI(view, url)
    }

    /// Shows `html`. Relative URLs in it resolve against `baseURL`; without
    /// one the page has no origin and can't load relative resources.
    public func loadHTML(_ html: String, baseURL: String?) {
        startOwnNavigation()
        if let baseURL {
            library.webViewLoadHTML(view, html, baseURL)
        } else {
            library.webViewLoadHTML(view, html, nil)
        }
    }

    public func reload() {
        isProvisional = true
        library.webViewReload(view)
    }

    public func stopLoading() {
        library.webViewStopLoading(view)
    }

    /// Does nothing at the end of the history. WebKit moves its `uri` to
    /// the history item before asking about the navigation, so it's
    /// provisional from here.
    public func goBack() {
        guard library.webViewCanGoBack(view) != 0 else { return }
        isProvisional = true
        library.webViewGoBack(view)
    }

    public func goForward() {
        guard library.webViewCanGoForward(view) != 0 else { return }
        isProvisional = true
        library.webViewGoForward(view)
    }

    /// The host's own load: it isn't asked about, and WebKit's `uri`,
    /// which changes at once, isn't where the page is until it commits.
    private func startOwnNavigation() {
        expectsOwnNavigation = true
        isProvisional = true
    }

    static let noNetwork = "the network isn't allowed"

    /// Schemes that reach the network.
    static let remoteSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp"]

    /// A URL's scheme, lowercased: letters, digits, `+`, `-` and `.` before
    /// the first colon, starting with a letter.
    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return nil
        }
        return scheme.lowercased()
    }

    // MARK: Scripts

    /// Evaluates `script` in the page's main frame. The result arrives as
    /// the delegate's `didEvaluateJavaScript` with the same `request`.
    public func evaluateJavaScript(_ script: String, request: Int32) {
        evaluateJavaScript(script) { [unowned self] result in
            switch result {
            case let .success(json):
                delegate.didEvaluateJavaScript(self, request: request, result: json, error: nil)
            case let .failure(error):
                delegate.didEvaluateJavaScript(self, request: request, result: nil, error: error.message)
            }
        }
    }

    /// Evaluates a script. The completion hears its value as JSON, nil for
    /// `undefined` and what JSON has no form for, or the exception. The
    /// page stays alive until then.
    public func evaluateJavaScript(_ script: String, completion: @escaping (Result<String?, WPEError>) -> Void) {
        let box = Unmanaged.passRetained(Evaluation(content: self, completion: completion)).toOpaque()
        library.webViewEvaluateJavaScript(view, script, -1, nil, nil, nil, unsafeBitCast(WPEWebContent.onEvaluated, to: Pointer.self), box)
    }

    /// Runs a script as the body of an async function and awaits what it
    /// returns; the completion hears that as `evaluateJavaScript`'s does.
    public func callAsyncJavaScript(_ body: String, completion: @escaping (Result<String?, WPEError>) -> Void) {
        let box = Unmanaged.passRetained(Evaluation(content: self, completion: completion)).toOpaque()
        library.webViewCallAsyncJavaScriptFunction(view, body, -1, nil, nil, nil, nil,
                                                   unsafeBitCast(WPEWebContent.onCalled, to: Pointer.self), box)
    }

    private var contentManager: Pointer? {
        library.webViewGetUserContentManager(view)
    }

    /// Adds a script the page runs on every load, when its document starts
    /// or when it ends, in every frame or the main one alone.
    public func addUserScript(_ source: String, atDocumentStart: Bool = false, mainFrameOnly: Bool = true) {
        guard let manager = contentManager,
              let script = library.userScriptNew(source, mainFrameOnly ? 1 : 0, atDocumentStart ? 0 : 1, nil, nil) else { return }
        library.userContentManagerAddScript(manager, script)
        library.userScriptUnref(script)
    }

    public func removeAllUserScripts() {
        guard let manager = contentManager else { return }
        library.userContentManagerRemoveAllScripts(manager)
    }

    /// Makes `window.webkit.messageHandlers[name].postMessage` reach
    /// `onScriptMessage`, from the next load on. A handler that replies
    /// reaches `onScriptMessageWithReply` instead, and `postMessage`
    /// returns a promise of the reply.
    public func addScriptMessageHandler(_ name: String, replies: Bool = false) {
        guard messageHandlers[name] == nil, let manager = contentManager else { return }
        let source = Unmanaged.passRetained(MessageSource(content: self, name: name)).toOpaque()
        let destroy = unsafeBitCast(WPEWebContent.onMessageSourceDestroyed, to: Pointer.self)
        if replies {
            guard library.registerScriptMessageHandlerWithReply(manager, name, nil) != 0 else {
                return Unmanaged<MessageSource>.fromOpaque(source).release()
            }
            messageHandlers[name] = library.signalConnectData(
                manager, "script-message-with-reply-received::\(name)",
                unsafeBitCast(WPEWebContent.onScriptMessageWithReplySignal, to: UnsafeRawPointer.self), source, destroy, 0)
        } else {
            guard library.registerScriptMessageHandler(manager, name, nil) != 0 else {
                return Unmanaged<MessageSource>.fromOpaque(source).release()
            }
            messageHandlers[name] = library.signalConnectData(
                manager, "script-message-received::\(name)", unsafeBitCast(WPEWebContent.onScriptMessageSignal, to: UnsafeRawPointer.self),
                source, destroy, 0)
        }
    }

    public func removeScriptMessageHandler(_ name: String) {
        guard let handler = messageHandlers.removeValue(forKey: name), let manager = contentManager else { return }
        library.signalHandlerDisconnect(manager, handler)
        library.unregisterScriptMessageHandler(manager, name, nil)
    }

    // MARK: URL schemes

    /// Makes requests for URLs in `scheme`, such as `app-icon:/a.png`, reach
    /// `onURLSchemeRequest`. Pages with an `https` URL load them without
    /// mixed-content blocking, and `fetch` reaches them.
    ///
    /// Register a scheme before the page loads what uses it. Returns false
    /// for a name that isn't a scheme, and for schemes WebKit loads itself,
    /// such as `https`, `file` and `data`. Schemes are compared lowercased.
    @discardableResult
    public func registerURLScheme(_ scheme: String) -> Bool {
        let scheme = scheme.lowercased()
        // The whole name is a scheme: nothing after a colon.
        guard WPEWebContent.scheme(of: scheme + ":") == scheme else { return false }
        guard !WPEWebContent.reservedSchemes.contains(scheme) else { return false }
        if !WPEWebContent.registeredSchemes.contains(scheme) {
            // WebKit keeps a scheme for every page that shares a context,
            // and can't forget one, so each is registered once, for all.
            guard let context = library.webViewGetContext(view) else { return false }
            library.webContextRegisterURIScheme(context, scheme, unsafeBitCast(WPEWebContent.onURISchemeRequest, to: UnsafeRawPointer.self),
                                                nil, nil)
            if let security = library.webContextGetSecurityManager(context) {
                library.securityManagerRegisterURISchemeAsSecure(security, scheme)
                library.securityManagerRegisterURISchemeAsCORSEnabled(security, scheme)
            }
            WPEWebContent.registeredSchemes.insert(scheme)
        }
        urlSchemes.insert(scheme)
        return true
    }

    /// Schemes WebKit loads itself, which can't be registered.
    static let reservedSchemes: Set<String> = remoteSchemes.union(["file", "about", "data", "blob", "javascript", "resource"])

    /// The schemes registered in WebKit, for every page.
    nonisolated(unsafe) private static var registeredSchemes: Set<String> = []

    private struct WeakTask {
        weak var task: WPEURLSchemeTask?
    }

    /// A request for one of the pages: to its host, if it registered the
    /// scheme.
    private func received(_ request: Pointer) {
        let task = WPEURLSchemeTask(library: library, request: request)
        guard let scheme = WPEWebContent.scheme(of: task.url), urlSchemes.contains(scheme) else {
            return task.fail(.notPermitted, message: "this page doesn't load \(task.url)")
        }
        guard let onURLSchemeRequest else {
            return task.fail(.badURL, message: "nothing answers \(task.url)")
        }
        openTasks = openTasks.filter { $0.value.task?.isFinished == false }
        openTasks[ObjectIdentifier(task)] = WeakTask(task: task)
        onURLSchemeRequest(task)
    }

    /// `WebKitURISchemeRequestCallback`, for every scheme: the request goes
    /// to the page whose view made it.
    private static let onURISchemeRequest: @convention(c) (Pointer?, Pointer?) -> Void = { request, _ in
        guard let request, let library = WPELibrary.shared else { return }
        guard let view = library.uriSchemeRequestGetWebView(request), let content = contentsByView[view]?.content else {
            return WPEURLSchemeTask(library: library, request: request).fail(.notPermitted, message: "no page made this request")
        }
        content.received(request)
    }

    // MARK: Settings

    /// The user agent the page sends, or nil for WPE WebKit's own.
    public func setUserAgent(_ agent: String?) {
        guard let settings = library.webViewGetSettings(view) else { return }
        if let agent {
            library.settingsSetUserAgent(settings, agent)
        } else {
            library.settingsSetUserAgent(settings, nil)
        }
    }

    /// Whether a page from a file can read other files.
    public func setAllowsFileAccessFromFileURLs(_ allowed: Bool) {
        guard let settings = library.webViewGetSettings(view) else { return }
        library.settingsSetAllowFileAccessFromFileURLs(settings, allowed ? 1 : 0)
    }

    // MARK: The view

    /// The view's size in points and its scale, while attached.
    public private(set) var size: (width: UInt32, height: UInt32, scale: Float)?

    public var isAttached: Bool { size != nil }

    /// What the engine was last told of the view's size, or nil for the
    /// size a page is made at.
    private var applied: (width: UInt32, height: UInt32, scale: Float)?

    /// The page was shown and hasn't drawn since. A page loses a size it is
    /// given as it is shown, and then draws nothing new, so the size waits
    /// for the first frame.
    private var awaitsFrame = false

    /// Puts the page on screen at a size in points: it's visible, draws at
    /// that size, and publishes its frames to `surface`.
    public func attach(width: UInt32, height: UInt32, scale: Float) {
        guard !isAttached else {
            return resize(width: width, height: height, scale: scale)
        }
        size = (max(width, 1), max(height, 1), scale)
        awaitsFrame = true
        library.viewBackendAddActivityState(backend, WPELibrary.visible)
    }

    public func resize(width: UInt32, height: UInt32, scale: Float) {
        guard isAttached else { return }
        size = (max(width, 1), max(height, 1), scale)
        if !awaitsFrame {
            applySize()
        }
    }

    /// Tells the engine the view's size, where it has another.
    private func applySize() {
        guard let size else { return }
        let applied = applied ?? (800, 600, 1)
        if size.scale != applied.scale {
            library.viewBackendDispatchSetDeviceScaleFactor(backend, size.scale)
        }
        if size.width != applied.width || size.height != applied.height {
            library.viewBackendDispatchSetSize(backend, size.width, size.height)
        }
        self.applied = size
    }

    /// The view is gone: the page stays loaded, hidden and unfocused.
    public func detach() {
        guard isAttached else { return }
        focus(false)
        library.viewBackendRemoveActivityState(backend, WPELibrary.visible)
        size = nil
        awaitsFrame = false
    }

    /// Keyboard focus came to the page or left it.
    public func focus(_ focused: Bool) {
        if focused {
            library.viewBackendAddActivityState(backend, WPELibrary.focused)
        } else {
            library.viewBackendRemoveActivityState(backend, WPELibrary.focused)
        }
    }

    // MARK: Input

    /// The pointer moved to a place in points from the page's top left.
    public func pointerMoved(x: Double, y: Double, modifiers: WPEModifiers = []) {
        guard isAttached else { return }
        var event = PointerEvent(type: 1, time: WPEWebContent.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()),
                                 button: 0, state: 0, modifiers: modifiers.rawValue)
        withUnsafeBytes(of: &event) { library.viewBackendDispatchPointerEvent(backend, $0.baseAddress!) }
    }

    /// A button went down or up at a place in points. The modifiers name
    /// the buttons held after the event, as well as the keys.
    public func pointerButton(_ button: WPEButton = .primary, pressed: Bool, x: Double, y: Double, modifiers: WPEModifiers = []) {
        guard isAttached else { return }
        var event = PointerEvent(type: 2, time: WPEWebContent.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()),
                                 button: button.rawValue, state: pressed ? 1 : 0, modifiers: modifiers.rawValue)
        withUnsafeBytes(of: &event) { library.viewBackendDispatchPointerEvent(backend, $0.baseAddress!) }
    }

    /// Scrolls what is under a place by a distance in points, smoothly:
    /// positive is toward the page's end. A scroll of nothing ends the
    /// gesture. The page animates the movement, and drops a scroll that
    /// comes before it has laid itself out.
    public func scroll(x: Double, y: Double, dx: Double, dy: Double, modifiers: WPEModifiers = []) {
        guard let size else { return }
        // libwpe takes the distance in device pixels, positive toward the
        // page's start.
        var event = AxisEvent2D(time: WPEWebContent.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()),
                                modifiers: modifiers.rawValue, xAxis: -dx * Double(size.scale), yAxis: -dy * Double(size.scale))
        withUnsafeBytes(of: &event) { library.viewBackendDispatchAxisEvent(backend, $0.baseAddress!) }
    }

    /// A key went down or up, by its XKB key symbol. Pages make text of
    /// keys themselves.
    public func key(keysym: UInt32, hardwareKeyCode: UInt32 = 0, pressed: Bool, modifiers: WPEModifiers = []) {
        guard isAttached else { return }
        var event = KeyboardEvent(time: WPEWebContent.milliseconds, keyCode: keysym, hardwareKeyCode: hardwareKeyCode, pressed: pressed,
                                  modifiers: modifiers.rawValue)
        withUnsafeBytes(of: &event) { library.viewBackendDispatchKeyboardEvent(backend, $0.baseAddress!) }
    }

    /// Types text as a key pressed and released for each character.
    public func type(_ text: String) {
        for scalar in text.unicodeScalars {
            let keysym = WPEKeysym.keysym(for: scalar) ?? library.unicodeToKeyCode(scalar.value)
            key(keysym: keysym, pressed: true)
            key(keysym: keysym, pressed: false)
        }
    }

    /// Milliseconds, as libwpe's events carry them.
    private static var milliseconds: UInt32 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt32(truncatingIfNeeded: Int(time.tv_sec) * 1000 + Int(time.tv_nsec) / 1_000_000)
    }

    // MARK: Reporting

    /// Where the page is: not while a navigation is provisional, nor an
    /// empty URI WebKit has after a failed first load.
    private func reportURL() {
        guard !isProvisional else { return }
        let uri = library.webViewGetURI(view).map { String(cString: $0) }
        let url = uri?.isEmpty == false ? uri : nil
        guard url != reportedURL else { return }
        reportedURL = url
        delegate.didChangeURL(self, url: url)
        reportHistory()
    }

    private func reportTitle() {
        let title = library.webViewGetTitle(view).map { String(cString: $0) } ?? ""
        guard title != reportedTitle else { return }
        reportedTitle = title
        delegate.didChangeTitle(self, title: title)
    }

    private func reportProgress() {
        guard isLoading else { return }
        delegate.didChangeLoading(self, isLoading: true, progress: library.webViewGetEstimatedLoadProgress(view))
    }

    private func reportHistory() {
        let history = (canGoBack: library.webViewCanGoBack(view) != 0, canGoForward: library.webViewCanGoForward(view) != 0)
        guard history != reportedHistory else { return }
        reportedHistory = history
        delegate.didChangeHistory(self, canGoBack: history.canGoBack, canGoForward: history.canGoForward)
    }

    private func loadChanged(_ event: WPELoadEvent) {
        onLoadEvent?(event)
        switch event {
        case .started:
            failed = false
            isLoading = true
            isProvisional = true
            reportProgress()
        case .redirected:
            // The redirect is followed: the page is going there.
            isProvisional = false
            reportURL()
            isProvisional = true
        case .committed:
            isProvisional = false
            reportURL()
            reportHistory()
        case .finished:
            isLoading = false
            isProvisional = false
            reportURL()
            reportHistory()
            delegate.didChangeLoading(self, isLoading: false, progress: 1)
            if !failed {
                delegate.didFinishNavigation(self)
            }
            failed = false
        }
    }

    private func loadFailed(_ error: WPEError) {
        // Stopped, or replaced by another navigation, is not a failure.
        guard let code = ErrorCode(error) else { return }
        fail(code, error.message)
    }

    private func fail(_ code: ErrorCode, _ message: String) {
        failed = true
        delegate.didFailNavigation(self, error: code.rawValue, message: message)
    }

    /// Asks about a navigation the page or the user started, and answers
    /// WebKit. False leaves the decision to WebKit.
    private func decide(_ decision: Pointer, type: Int32) -> Bool {
        // WebKitPolicyDecisionType: 0 a navigation, 1 a new window.
        guard type == 0 || type == 1, let action = library.navigationPolicyDecisionGetNavigationAction(decision) else {
            return false
        }
        let url = library.navigationActionGetRequest(action).flatMap(library.uriRequestGetURI).map { String(cString: $0) } ?? ""
        let navigationType = library.navigationActionGetNavigationType(action)
        if type == 0, expectsOwnNavigation {
            expectsOwnNavigation = false
            if !asksAboutOwnLoads {
                library.policyDecisionUse(decision)
                return true
            }
        }
        if let scheme = WPEWebContent.scheme(of: url), WPEWebContent.remoteSchemes.contains(scheme), !WPEEngine.isNetworkAllowed {
            library.policyDecisionIgnore(decision)
            delegate.didFailNavigation(self, error: ErrorCode.notPermitted.rawValue, message: WPEWebContent.noNetwork)
            return true
        }
        if let onNavigation {
            let navigation = WPENavigation(
                uri: url,
                kind: WPENavigation.Kind(rawValue: navigationType) ?? .other,
                opensNewWindow: type == 1,
                modifiers: WPEModifiers(rawValue: library.navigationActionGetModifiers(action)),
                button: WPEButton(rawValue: library.navigationActionGetMouseButton(action))
            )
            isProvisional = true
            onNavigation(navigation, WPEPolicyDecision(library: library, decision: decision))
            return true
        }
        let allowed = delegate.shouldNavigate(self, url: url, kind: NavigationKind(type: navigationType).rawValue, isMainFrame: true)
        if type == 1 {
            // New windows load in this page.
            library.policyDecisionIgnore(decision)
            if allowed {
                startOwnNavigation()
                library.webViewLoadURI(view, url)
            }
        } else if allowed {
            isProvisional = true
            library.policyDecisionUse(decision)
        } else {
            library.policyDecisionIgnore(decision)
        }
        return true
    }

    // MARK: Frames

    /// `wpe_view_backend_exportable_fdo_client`: frames in shared memory
    /// only.
    nonisolated(unsafe) private static let client: UnsafeRawPointer = {
        let client = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 5)
        client.initialize(repeating: nil, count: 5)
        client[2] = unsafeBitCast(WPEWebContent.onShmBuffer, to: UnsafeRawPointer.self)
        return UnsafeRawPointer(client)
    }()

    /// A frame, to the page in the exportable's slot.
    private static let onShmBuffer: @convention(c) (Pointer?, Pointer?) -> Void = { data, buffer in
        guard let buffer, let content = data?.assumingMemoryBound(to: Pointer?.self).pointee else { return }
        Unmanaged<WPEWebContent>.fromOpaque(content).takeUnretainedValue().receive(buffer)
    }

    private static let onBackendDestroyed: @convention(c) (Pointer?) -> Void = { exportable in
        if let exportable {
            WPELibrary.shared?.exportableDestroy(exportable)
        }
    }

    private func receive(_ buffer: Pointer) {
        defer {
            library.exportableReleaseShmBuffer(exportable, buffer)
            library.exportableFrameComplete(exportable)
        }
        guard let size, let shm = library.shmExportedBufferGetShmBuffer(buffer) else { return }
        library.shmBufferBeginAccess(shm)
        defer { library.shmBufferEndAccess(shm) }
        let width = Int(library.shmBufferGetWidth(shm)), height = Int(library.shmBufferGetHeight(shm))
        let stride = Int(library.shmBufferGetStride(shm))
        if awaitsFrame {
            awaitsFrame = false
            let isCurrent = Float(width) == Float(size.width) * size.scale && Float(height) == Float(size.height) * size.scale
            applySize()
            // The frame of a size the view no longer has isn't shown.
            guard isCurrent else { return }
        }
        guard width > 0, height > 0, stride >= width * 4, let pixels = library.shmBufferGetData(shm) else { return }
        // Wayland's ARGB8888 is blue first in memory.
        surface.publish(pixels: UnsafeRawBufferPointer(start: pixels, count: stride * height), width: width, height: height,
                        bytesPerRow: stride, format: .bgra, rowOrder: .topFirst)
    }

    // MARK: Signals

    private static func content(_ data: Pointer?) -> WPEWebContent? {
        data.map { Unmanaged<WPEWebContent>.fromOpaque($0).takeUnretainedValue() }
    }

    private static let onLoadChangedSignal: @convention(c) (Pointer?, Int32, Pointer?) -> Void = { _, event, data in
        guard let content = content(data), let event = WPELoadEvent(rawValue: event) else { return }
        content.loadChanged(event)
    }

    /// load-failed: the view, the step it failed at, the URI and the
    /// GError; true, as handled.
    private static let onLoadFailedSignal: @convention(c) (Pointer?, Int32, UnsafePointer<CChar>?, Pointer?, Pointer?) -> Int32 = {
        _, event, _, error, data in
        guard let content = content(data) else { return 1 }
        let described = error.map(content.library.error) ?? .unknown
        content.onLoadError?(described, event >= WPELoadEvent.committed.rawValue)
        content.loadFailed(described)
        return 1
    }

    /// load-failed-with-tls-errors: the view, the URI, the certificate and
    /// its errors; true, as handled, so load-failed doesn't follow.
    private static let onTLSErrorsSignal: @convention(c) (Pointer?, UnsafePointer<CChar>?, Pointer?, UInt32, Pointer?) -> Int32 = {
        _, uri, _, _, data in
        let url = uri.map { String(cString: $0) } ?? ""
        content(data)?.fail(.security, "the certificate for \(url) isn't trusted")
        return 1
    }

    private static let onDecidePolicySignal: @convention(c) (Pointer?, Pointer?, Int32, Pointer?) -> Int32 = { _, decision, type, data in
        guard let content = content(data), let decision else { return 0 }
        return content.decide(decision, type: type) ? 1 : 0
    }

    private static let onNotifySignal: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { _, spec, data in
        guard let content = content(data), let spec, let name = content.library.paramSpecGetName(spec) else { return }
        switch String(cString: name) {
        case "title": content.reportTitle()
        case "uri": content.reportURL()
        case "estimated-load-progress": content.reportProgress()
        default: break
        }
    }

    // MARK: Script results

    private final class Evaluation {
        let content: WPEWebContent
        let completion: (Result<String?, WPEError>) -> Void
        init(content: WPEWebContent, completion: @escaping (Result<String?, WPEError>) -> Void) {
            self.content = content
            self.completion = completion
        }
    }

    private static let onEvaluated: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { source, result, data in
        finish(source, result, data) { $0.webViewEvaluateJavaScriptFinish($1, $2, $3) }
    }

    private static let onCalled: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { source, result, data in
        finish(source, result, data) { $0.webViewCallAsyncJavaScriptFunctionFinish($1, $2, $3) }
    }

    /// A script's value as JSON, or its error.
    private static func finish(
        _ source: Pointer?, _ result: Pointer?, _ data: Pointer?,
        _ finish: (WPELibrary, Pointer, Pointer, UnsafeMutablePointer<Pointer?>) -> Pointer?
    ) {
        guard let data else { return }
        let evaluation = Unmanaged<Evaluation>.fromOpaque(data).takeRetainedValue()
        let library = evaluation.content.library
        var error: Pointer?
        guard let source, let result, let value = finish(library, source, result, &error) else {
            return evaluation.completion(.failure(library.takeError(error) ?? .unknown))
        }
        defer { library.objectUnref(value) }
        evaluation.completion(.success(json(value, library)))
    }

    /// A JSCValue as JSON; nil for `undefined` and what JSON can't hold.
    private static func json(_ value: Pointer, _ library: WPELibrary) -> String? {
        guard library.valueIsUndefined(value) == 0, let text = library.valueToJSON(value, 0) else { return nil }
        defer { library.free(text) }
        return String(cString: text)
    }

    // MARK: Script messages

    private final class MessageSource {
        unowned let content: WPEWebContent
        let name: String
        init(content: WPEWebContent, name: String) {
            self.content = content
            self.name = name
        }
    }

    /// script-message-received: the content manager, the message's JSCValue
    /// and the source.
    private static let onScriptMessageSignal: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { _, value, data in
        guard let data else { return }
        let source = Unmanaged<MessageSource>.fromOpaque(data).takeUnretainedValue()
        source.content.onScriptMessage?(source.name, value.flatMap { json($0, source.content.library) })
    }

    /// script-message-with-reply-received: the content manager, the
    /// message's JSCValue, the WebKitScriptMessageReply and the source; true,
    /// as it will be answered.
    private static let onScriptMessageWithReplySignal: @convention(c) (Pointer?, Pointer?, Pointer?, Pointer?) -> Int32 = {
        _, value, reply, data in
        guard let data, let reply else { return 0 }
        let source = Unmanaged<MessageSource>.fromOpaque(data).takeUnretainedValue()
        source.content.receivedMessage(source.name, value: value, reply: reply)
        return 1
    }

    private struct WeakReply {
        weak var reply: WPEScriptMessageReply?
    }

    private func receivedMessage(_ name: String, value: Pointer?, reply: Pointer) {
        let reply = WPEScriptMessageReply(library: library, reply: reply, context: value.flatMap(library.valueGetContext))
        guard let onScriptMessageWithReply else {
            return reply.returnError("nothing answers \(name)")
        }
        openReplies = openReplies.filter { $0.value.reply?.isAnswered == false }
        openReplies[ObjectIdentifier(reply)] = WeakReply(reply: reply)
        onScriptMessageWithReply(name, value.flatMap { WPEWebContent.json($0, library) }, reply)
    }

    private static let onMessageSourceDestroyed: @convention(c) (Pointer?, Pointer?) -> Void = { data, _ in
        if let data {
            Unmanaged<MessageSource>.fromOpaque(data).release()
        }
    }
}
