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

/// A web page: a `WebKitWebView` that draws into an external surface.
///
/// The page loads whether or not anything shows it. A view shows `surface`,
/// keeps the page at its own size with `resize`, says when it is visible
/// and focused, and forwards its input. The page's callbacks run from
/// `WPEEngine.dispatch`, on WebKit's main thread, which is the only thread
/// a page is for.
public final class WPEPage {

    typealias Pointer = UnsafeMutableRawPointer

    private let library: WPELibrary
    private let exportable: Pointer
    private let backend: Pointer
    private let view: Pointer
    /// The exportable's client data: this page, until it goes.
    private let slot: UnsafeMutablePointer<Pointer?>
    private var handlers: [UInt] = []
    private var messageHandlers: [String: UInt] = [:]

    /// The page's frames: BGRA, premultiplied, top row first, published as
    /// the web process draws them.
    public let surface = ExternalSurface()

    // MARK: What the page reports

    /// A load reached a step.
    public var onLoadChanged: ((WPELoadEvent) -> Void)?

    /// A load failed, at the step given, with WebKit's or the network's
    /// error. A load that was stopped or replaced fails too, with
    /// `WebKitNetworkError` 302.
    public var onLoadFailed: ((WPELoadEvent, WPEError) -> Void)?

    /// A load was refused because the server's certificate isn't trusted,
    /// for the URI given. Without this, `onLoadFailed` hears of it.
    public var onCertificateRejected: ((String) -> Void)?

    /// The title, URI, loading state or progress changed.
    public var onPropertyChanged: ((WPEPageProperty) -> Void)?

    /// Asks whether a navigation goes ahead, now or later. Without this,
    /// every navigation does.
    public var onNavigation: ((WPENavigation, WPEPolicyDecision) -> Void)?

    /// A script posted to `window.webkit.messageHandlers[name]`: the
    /// handler's name and the message as JSON, nil for `undefined`.
    public var onScriptMessage: ((String, String?) -> Void)?

    // MARK: Making a page

    /// A page of a size in points, at a number of pixels per point; nil
    /// where WPE WebKit isn't installed or can't make a view.
    public init?(width: UInt32 = 800, height: UInt32 = 600, scale: Float = 1) {
        guard let library = WPELibrary.shared else { return nil }
        let size = (width: max(width, 1), height: max(height, 1))
        let slot = UnsafeMutablePointer<Pointer?>.allocate(capacity: 1)
        slot.initialize(to: nil)
        // WebKit destroys the exportable when it is done with the backend.
        guard let exportable = library.exportableCreate(WPEPage.client, slot, size.width, size.height),
              let backend = library.exportableGetViewBackend(exportable),
              let webBackend = library.webViewBackendNew(backend, unsafeBitCast(WPEPage.onBackendDestroyed, to: Pointer.self), exportable),
              let view = library.webViewNew(webBackend) else {
            WPEEngine.log("can't make a WPE web view")
            return nil
        }
        self.library = library
        self.exportable = exportable
        self.backend = backend
        self.view = view
        self.slot = slot
        self.size = size
        self.scale = scale
        slot.pointee = Unmanaged.passUnretained(self).toOpaque()
        library.viewBackendDispatchSetDeviceScaleFactor(backend, scale)
        library.viewBackendAddActivityState(backend, WPELibrary.inWindow)
        connect("load-changed", unsafeBitCast(WPEPage.onLoadChangedSignal, to: UnsafeRawPointer.self))
        connect("load-failed", unsafeBitCast(WPEPage.onLoadFailedSignal, to: UnsafeRawPointer.self))
        connect("load-failed-with-tls-errors", unsafeBitCast(WPEPage.onTLSErrorsSignal, to: UnsafeRawPointer.self))
        connect("decide-policy", unsafeBitCast(WPEPage.onDecidePolicySignal, to: UnsafeRawPointer.self))
        for property in ["title", "uri", "is-loading", "estimated-load-progress"] {
            connect("notify::\(property)", unsafeBitCast(WPEPage.onNotifySignal, to: UnsafeRawPointer.self))
        }
        WPEEngine.pageCount += 1
    }

    private func connect(_ signal: String, _ callback: UnsafeRawPointer) {
        handlers.append(library.signalConnectData(view, signal, callback, Unmanaged.passUnretained(self).toOpaque(), nil, 0))
    }

    deinit {
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
        library.objectUnref(view)
        WPEEngine.pageCount -= 1
    }

    // MARK: Loading

    public func load(uri: String) {
        library.webViewLoadURI(view, uri)
    }

    /// Loads markup as the page, with the URI its relative links are from.
    public func load(html: String, baseURI: String? = nil) {
        if let baseURI {
            library.webViewLoadHTML(view, html, baseURI)
        } else {
            library.webViewLoadHTML(view, html, nil)
        }
    }

    public func reload() {
        library.webViewReload(view)
    }

    public func stopLoading() {
        library.webViewStopLoading(view)
    }

    public func goBack() {
        library.webViewGoBack(view)
    }

    public func goForward() {
        library.webViewGoForward(view)
    }

    public var title: String? {
        library.webViewGetTitle(view).map { String(cString: $0) }
    }

    /// Where the page is, or where it is headed while a load has started
    /// and not committed.
    public var uri: String? {
        library.webViewGetURI(view).map { String(cString: $0) }
    }

    public var isLoading: Bool {
        library.webViewIsLoading(view) != 0
    }

    /// How much of the load is done, from 0 to 1.
    public var estimatedLoadProgress: Double {
        library.webViewGetEstimatedLoadProgress(view)
    }

    public var canGoBack: Bool {
        library.webViewCanGoBack(view) != 0
    }

    public var canGoForward: Bool {
        library.webViewCanGoForward(view) != 0
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

    // MARK: Scripts

    /// Runs a script in the page. The completion hears its value as JSON,
    /// nil for `undefined` and what JSON has no form for, or the exception.
    public func evaluateJavaScript(_ script: String, completion: @escaping (Result<String?, WPEError>) -> Void) {
        let box = Unmanaged.passRetained(Evaluation(library: library, completion: completion)).toOpaque()
        library.webViewEvaluateJavaScript(view, script, -1, nil, nil, nil, unsafeBitCast(WPEPage.onEvaluated, to: Pointer.self), box)
    }

    /// Runs a script as the body of an async function and awaits what it
    /// returns; the completion hears that as `evaluateJavaScript`'s does.
    public func callAsyncJavaScript(_ body: String, completion: @escaping (Result<String?, WPEError>) -> Void) {
        let box = Unmanaged.passRetained(Evaluation(library: library, completion: completion)).toOpaque()
        library.webViewCallAsyncJavaScriptFunction(view, body, -1, nil, nil, nil, nil, unsafeBitCast(WPEPage.onCalled, to: Pointer.self), box)
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
    /// `onScriptMessage`, from the next load on.
    public func addScriptMessageHandler(_ name: String) {
        guard messageHandlers[name] == nil, let manager = contentManager,
              library.registerScriptMessageHandler(manager, name, nil) != 0 else { return }
        let source = Unmanaged.passRetained(MessageSource(page: self, name: name)).toOpaque()
        messageHandlers[name] = library.signalConnectData(
            manager, "script-message-received::\(name)", unsafeBitCast(WPEPage.onScriptMessageSignal, to: UnsafeRawPointer.self), source,
            unsafeBitCast(WPEPage.onMessageSourceDestroyed, to: Pointer.self), 0)
    }

    public func removeScriptMessageHandler(_ name: String) {
        guard let handler = messageHandlers.removeValue(forKey: name), let manager = contentManager else { return }
        library.signalHandlerDisconnect(manager, handler)
        library.unregisterScriptMessageHandler(manager, name, nil)
    }

    // MARK: The view

    /// The page's size in points.
    public private(set) var size: (width: UInt32, height: UInt32)

    /// The pixels the page draws per point.
    public private(set) var scale: Float

    /// Gives the page a size in points and a scale, which its next frames
    /// have.
    public func resize(width: UInt32, height: UInt32, scale: Float) {
        let size = (width: max(width, 1), height: max(height, 1))
        if scale != self.scale {
            self.scale = scale
            library.viewBackendDispatchSetDeviceScaleFactor(backend, scale)
        }
        guard size != self.size else { return }
        self.size = size
        library.viewBackendDispatchSetSize(backend, size.width, size.height)
    }

    /// Whether the page is on screen. A page draws no frames while it is
    /// not, and its timers slow.
    public var isVisible = false {
        didSet { setActivity(WPELibrary.visible, isVisible, was: oldValue) }
    }

    /// Whether the page has keyboard focus, which its carets and focus
    /// rings follow.
    public var isFocused = false {
        didSet { setActivity(WPELibrary.focused, isFocused, was: oldValue) }
    }

    private func setActivity(_ state: UInt32, _ on: Bool, was: Bool) {
        guard on != was else { return }
        if on {
            library.viewBackendAddActivityState(backend, state)
        } else {
            library.viewBackendRemoveActivityState(backend, state)
        }
    }

    // MARK: Input

    /// The pointer moved to a place in points from the page's top left.
    public func pointerMoved(x: Double, y: Double, modifiers: WPEModifiers = []) {
        var event = PointerEvent(type: 1, time: WPEPage.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()),
                                 button: 0, state: 0, modifiers: modifiers.rawValue)
        withUnsafeBytes(of: &event) { library.viewBackendDispatchPointerEvent(backend, $0.baseAddress!) }
    }

    /// A button went down or up at a place in points. The modifiers name
    /// the buttons held after the event, as well as the keys.
    public func pointerButton(_ button: WPEButton, pressed: Bool, x: Double, y: Double, modifiers: WPEModifiers = []) {
        var event = PointerEvent(type: 2, time: WPEPage.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()),
                                 button: button.rawValue, state: pressed ? 1 : 0, modifiers: modifiers.rawValue)
        withUnsafeBytes(of: &event) { library.viewBackendDispatchPointerEvent(backend, $0.baseAddress!) }
    }

    /// Scrolls what is under a place by a distance in points, smoothly:
    /// positive is toward the page's end. A scroll of nothing ends the
    /// gesture. The page animates the movement, and drops a scroll that
    /// comes before it has laid itself out.
    public func scroll(x: Double, y: Double, dx: Double, dy: Double, modifiers: WPEModifiers = []) {
        // libwpe takes the distance in device pixels, positive toward the
        // page's start.
        var event = AxisEvent2D(time: WPEPage.milliseconds, x: Int32(x.rounded()), y: Int32(y.rounded()), modifiers: modifiers.rawValue,
                                xAxis: -dx * Double(scale), yAxis: -dy * Double(scale))
        withUnsafeBytes(of: &event) { library.viewBackendDispatchAxisEvent(backend, $0.baseAddress!) }
    }

    /// A key went down or up, by its XKB key symbol. Pages make text of
    /// keys themselves.
    public func key(keysym: UInt32, hardwareKeyCode: UInt32 = 0, pressed: Bool, modifiers: WPEModifiers = []) {
        var event = KeyboardEvent(time: WPEPage.milliseconds, keyCode: keysym, hardwareKeyCode: hardwareKeyCode, pressed: pressed,
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

    // MARK: Frames

    /// `wpe_view_backend_exportable_fdo_client`: frames in shared memory
    /// only.
    nonisolated(unsafe) private static let client: UnsafeRawPointer = {
        let client = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 5)
        client.initialize(repeating: nil, count: 5)
        client[2] = unsafeBitCast(WPEPage.onShmBuffer, to: UnsafeRawPointer.self)
        return UnsafeRawPointer(client)
    }()

    /// A frame, to the page in the exportable's slot.
    private static let onShmBuffer: @convention(c) (Pointer?, Pointer?) -> Void = { data, buffer in
        guard let buffer, let page = data?.assumingMemoryBound(to: Pointer?.self).pointee else { return }
        Unmanaged<WPEPage>.fromOpaque(page).takeUnretainedValue().receive(buffer)
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
        guard let shm = library.shmExportedBufferGetShmBuffer(buffer) else { return }
        library.shmBufferBeginAccess(shm)
        defer { library.shmBufferEndAccess(shm) }
        let width = Int(library.shmBufferGetWidth(shm)), height = Int(library.shmBufferGetHeight(shm))
        let stride = Int(library.shmBufferGetStride(shm))
        guard width > 0, height > 0, stride >= width * 4, let pixels = library.shmBufferGetData(shm) else { return }
        // Wayland's ARGB8888 is blue first in memory.
        surface.publish(pixels: UnsafeRawBufferPointer(start: pixels, count: stride * height), width: width, height: height,
                        bytesPerRow: stride, format: .bgra, rowOrder: .topFirst)
    }

    // MARK: Signals

    private static func page(_ data: Pointer?) -> WPEPage? {
        data.map { Unmanaged<WPEPage>.fromOpaque($0).takeUnretainedValue() }
    }

    private static let onLoadChangedSignal: @convention(c) (Pointer?, Int32, Pointer?) -> Void = { _, event, data in
        guard let page = page(data), let event = WPELoadEvent(rawValue: event) else { return }
        page.onLoadChanged?(event)
    }

    /// load-failed: the view, the step it failed at, the URI and the
    /// GError; true, as handled.
    private static let onLoadFailedSignal: @convention(c) (Pointer?, Int32, UnsafePointer<CChar>?, Pointer?, Pointer?) -> Int32 = {
        _, event, _, error, data in
        guard let page = page(data) else { return 1 }
        page.onLoadFailed?(WPELoadEvent(rawValue: event) ?? .started, error.map(page.library.error) ?? .unknown)
        return 1
    }

    /// load-failed-with-tls-errors: the view, the URI, the certificate and
    /// its errors; true when handled, so load-failed doesn't follow.
    private static let onTLSErrorsSignal: @convention(c) (Pointer?, UnsafePointer<CChar>?, Pointer?, UInt32, Pointer?) -> Int32 = {
        _, uri, _, _, data in
        guard let rejected = page(data)?.onCertificateRejected else { return 0 }
        rejected(uri.map { String(cString: $0) } ?? "")
        return 1
    }

    /// decide-policy: navigations and new windows ask `onNavigation`; the
    /// rest, and all of them without it, take WebKit's default.
    private static let onDecidePolicySignal: @convention(c) (Pointer?, Pointer?, Int32, Pointer?) -> Int32 = { _, decision, type, data in
        // WebKitPolicyDecisionType: 0 a navigation, 1 a new window.
        guard let page = page(data), let decision, type == 0 || type == 1, let ask = page.onNavigation else { return 0 }
        let library = page.library
        guard let action = library.navigationPolicyDecisionGetNavigationAction(decision) else { return 0 }
        let uri = library.navigationActionGetRequest(action).flatMap(library.uriRequestGetURI).map { String(cString: $0) } ?? ""
        let navigation = WPENavigation(
            uri: uri,
            kind: WPENavigation.Kind(rawValue: library.navigationActionGetNavigationType(action)) ?? .other,
            opensNewWindow: type == 1,
            modifiers: WPEModifiers(rawValue: library.navigationActionGetModifiers(action)),
            button: WPEButton(rawValue: library.navigationActionGetMouseButton(action))
        )
        ask(navigation, WPEPolicyDecision(library: library, decision: decision))
        return 1
    }

    private static let onNotifySignal: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { _, spec, data in
        guard let page = page(data), let spec, let name = page.library.paramSpecGetName(spec),
              let property = WPEPageProperty(rawValue: String(cString: name)) else { return }
        page.onPropertyChanged?(property)
    }

    // MARK: Script results

    private final class Evaluation {
        let library: WPELibrary
        let completion: (Result<String?, WPEError>) -> Void
        init(library: WPELibrary, completion: @escaping (Result<String?, WPEError>) -> Void) {
            self.library = library
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
        let library = evaluation.library
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
        unowned let page: WPEPage
        let name: String
        init(page: WPEPage, name: String) {
            self.page = page
            self.name = name
        }
    }

    /// script-message-received: the content manager, the message's JSCValue
    /// and the source.
    private static let onScriptMessageSignal: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { _, value, data in
        guard let data else { return }
        let source = Unmanaged<MessageSource>.fromOpaque(data).takeUnretainedValue()
        source.page.onScriptMessage?(source.name, value.flatMap { json($0, source.page.library) })
    }

    private static let onMessageSourceDestroyed: @convention(c) (Pointer?, Pointer?) -> Void = { data, _ in
        if let data {
            Unmanaged<MessageSource>.fromOpaque(data).release()
        }
    }
}
