#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// WPE WebKit's libraries, opened at run time, and the functions of theirs
/// the engine calls.
///
/// Each page is a `WebKitWebView` over a view backend from WPEBackend-fdo in
/// its shared-memory mode, which hands every frame the web process draws to
/// this process as a `wl_shm` buffer: no GL. Pages run in WPE's web and
/// network processes, and their signals and replies come through GLib's main
/// context.
final class WPELibrary: Sendable {

    typealias Pointer = UnsafeMutableRawPointer
    typealias CString = UnsafePointer<CChar>

    // MARK: libwpe and WPEBackend-fdo

    let viewBackendAddActivityState: @convention(c) (Pointer, UInt32) -> Void
    let viewBackendRemoveActivityState: @convention(c) (Pointer, UInt32) -> Void
    let viewBackendDispatchSetSize: @convention(c) (Pointer, UInt32, UInt32) -> Void
    let viewBackendDispatchSetDeviceScaleFactor: @convention(c) (Pointer, Float) -> Void
    let viewBackendDispatchPointerEvent: @convention(c) (Pointer, UnsafeRawPointer) -> Void
    let viewBackendDispatchAxisEvent: @convention(c) (Pointer, UnsafeRawPointer) -> Void
    let viewBackendDispatchKeyboardEvent: @convention(c) (Pointer, UnsafeRawPointer) -> Void
    let unicodeToKeyCode: @convention(c) (UInt32) -> UInt32
    let exportableCreate: @convention(c) (UnsafeRawPointer, Pointer?, UInt32, UInt32) -> Pointer?
    let exportableDestroy: @convention(c) (Pointer) -> Void
    let exportableGetViewBackend: @convention(c) (Pointer) -> Pointer?
    let exportableFrameComplete: @convention(c) (Pointer) -> Void
    let exportableReleaseShmBuffer: @convention(c) (Pointer, Pointer) -> Void
    let shmExportedBufferGetShmBuffer: @convention(c) (Pointer) -> Pointer?

    // MARK: libwayland-server's shared-memory buffers

    let shmBufferGetData: @convention(c) (Pointer) -> Pointer?
    let shmBufferGetWidth: @convention(c) (Pointer) -> Int32
    let shmBufferGetHeight: @convention(c) (Pointer) -> Int32
    let shmBufferGetStride: @convention(c) (Pointer) -> Int32
    let shmBufferBeginAccess: @convention(c) (Pointer) -> Void
    let shmBufferEndAccess: @convention(c) (Pointer) -> Void

    // MARK: WPE WebKit's web views

    let webViewBackendNew: @convention(c) (Pointer, Pointer?, Pointer?) -> Pointer?
    let webViewNew: @convention(c) (Pointer) -> Pointer?
    let webViewLoadHTML: @convention(c) (Pointer, CString, CString?) -> Void
    let webViewLoadURI: @convention(c) (Pointer, CString) -> Void
    let webViewGetTitle: @convention(c) (Pointer) -> CString?
    let webViewGetURI: @convention(c) (Pointer) -> CString?
    let webViewIsLoading: @convention(c) (Pointer) -> Int32
    let webViewGetEstimatedLoadProgress: @convention(c) (Pointer) -> Double
    let webViewCanGoBack: @convention(c) (Pointer) -> Int32
    let webViewCanGoForward: @convention(c) (Pointer) -> Int32
    let webViewGoBack: @convention(c) (Pointer) -> Void
    let webViewGoForward: @convention(c) (Pointer) -> Void
    let webViewReload: @convention(c) (Pointer) -> Void
    let webViewStopLoading: @convention(c) (Pointer) -> Void
    let webViewGetSettings: @convention(c) (Pointer) -> Pointer?
    let settingsSetUserAgent: @convention(c) (Pointer, CString?) -> Void
    let settingsSetAllowFileAccessFromFileURLs: @convention(c) (Pointer, Int32) -> Void

    // MARK: Scripts, and their values in WPE's JavaScriptCore

    let webViewEvaluateJavaScript: @convention(c) (Pointer, CString, Int, CString?, CString?, Pointer?, Pointer?, Pointer?) -> Void
    let webViewEvaluateJavaScriptFinish: @convention(c) (Pointer, Pointer, UnsafeMutablePointer<Pointer?>) -> Pointer?
    let webViewCallAsyncJavaScriptFunction: @convention(c) (Pointer, CString, Int, Pointer?, CString?, CString?, Pointer?, Pointer?,
                                                            Pointer?) -> Void
    let webViewCallAsyncJavaScriptFunctionFinish: @convention(c) (Pointer, Pointer, UnsafeMutablePointer<Pointer?>) -> Pointer?
    let valueIsUndefined: @convention(c) (Pointer) -> Int32
    let valueToJSON: @convention(c) (Pointer, UInt32) -> UnsafeMutablePointer<CChar>?
    let webViewGetUserContentManager: @convention(c) (Pointer) -> Pointer?
    let registerScriptMessageHandler: @convention(c) (Pointer, CString, CString?) -> Int32
    let unregisterScriptMessageHandler: @convention(c) (Pointer, CString, CString?) -> Void
    let registerScriptMessageHandlerWithReply: @convention(c) (Pointer, CString, CString?) -> Int32
    let scriptMessageReplyRef: @convention(c) (Pointer) -> Pointer?
    let scriptMessageReplyUnref: @convention(c) (Pointer) -> Void
    let scriptMessageReplyReturnValue: @convention(c) (Pointer, Pointer) -> Void
    let scriptMessageReplyReturnErrorMessage: @convention(c) (Pointer, CString) -> Void
    let valueGetContext: @convention(c) (Pointer) -> Pointer?
    let valueNewFromJSON: @convention(c) (Pointer, CString) -> Pointer?
    let valueNewUndefined: @convention(c) (Pointer) -> Pointer?
    let contextClearException: @convention(c) (Pointer) -> Void
    let userScriptNew: @convention(c) (CString, Int32, Int32, UnsafeRawPointer?, UnsafeRawPointer?) -> Pointer?
    let userScriptUnref: @convention(c) (Pointer) -> Void
    let userContentManagerAddScript: @convention(c) (Pointer, Pointer) -> Void
    let userContentManagerRemoveAllScripts: @convention(c) (Pointer) -> Void

    // MARK: URI schemes

    let webViewGetContext: @convention(c) (Pointer) -> Pointer?
    let webContextRegisterURIScheme: @convention(c) (Pointer, CString, UnsafeRawPointer, Pointer?, Pointer?) -> Void
    let webContextGetSecurityManager: @convention(c) (Pointer) -> Pointer?
    let securityManagerRegisterURISchemeAsSecure: @convention(c) (Pointer, CString) -> Void
    let securityManagerRegisterURISchemeAsCORSEnabled: @convention(c) (Pointer, CString) -> Void
    let uriSchemeRequestGetURI: @convention(c) (Pointer) -> CString?
    let uriSchemeRequestGetPath: @convention(c) (Pointer) -> CString?
    let uriSchemeRequestGetWebView: @convention(c) (Pointer) -> Pointer?
    let uriSchemeRequestGetHTTPMethod: @convention(c) (Pointer) -> CString?
    let uriSchemeRequestGetHTTPHeaders: @convention(c) (Pointer) -> Pointer?
    let uriSchemeRequestGetHTTPBody: @convention(c) (Pointer) -> Pointer?
    let uriSchemeRequestFinishWithResponse: @convention(c) (Pointer, Pointer) -> Void
    let uriSchemeRequestFinishError: @convention(c) (Pointer, Pointer) -> Void
    let uriSchemeResponseNew: @convention(c) (Pointer, Int64) -> Pointer?
    let uriSchemeResponseSetStatus: @convention(c) (Pointer, UInt32, CString?) -> Void
    let uriSchemeResponseSetContentType: @convention(c) (Pointer, CString) -> Void
    let uriSchemeResponseSetHTTPHeaders: @convention(c) (Pointer, Pointer) -> Void

    // MARK: Navigation policy

    let navigationPolicyDecisionGetNavigationAction: @convention(c) (Pointer) -> Pointer?
    let navigationActionGetRequest: @convention(c) (Pointer) -> Pointer?
    let navigationActionGetNavigationType: @convention(c) (Pointer) -> Int32
    let navigationActionGetModifiers: @convention(c) (Pointer) -> UInt32
    let navigationActionGetMouseButton: @convention(c) (Pointer) -> UInt32
    let uriRequestGetURI: @convention(c) (Pointer) -> CString?
    let policyDecisionUse: @convention(c) (Pointer) -> Void
    let policyDecisionIgnore: @convention(c) (Pointer) -> Void

    // MARK: The network

    let networkSessionGetDefault: @convention(c) () -> Pointer?
    let networkSessionSetProxySettings: @convention(c) (Pointer, Int32, Pointer?) -> Void
    let networkProxySettingsNew: @convention(c) (CString?, UnsafePointer<CString?>?) -> Pointer?
    let networkProxySettingsFree: @convention(c) (Pointer) -> Void

    // MARK: GLib and GObject

    let mainContextIteration: @convention(c) (Pointer?, Int32) -> Int32
    let mainContextAcquire: @convention(c) (Pointer?) -> Int32
    let mainContextPrepare: @convention(c) (Pointer?, UnsafeMutablePointer<Int32>) -> Int32
    let mainContextQuery: @convention(c) (Pointer?, Int32, UnsafeMutablePointer<Int32>, UnsafeMutableRawPointer?, Int32) -> Int32
    let signalConnectData: @convention(c) (Pointer, CString, UnsafeRawPointer, Pointer?, Pointer?, Int32) -> UInt
    let signalHandlerDisconnect: @convention(c) (Pointer, UInt) -> Void
    let objectRef: @convention(c) (Pointer) -> Pointer?
    let objectUnref: @convention(c) (Pointer) -> Void
    let free: @convention(c) (Pointer?) -> Void
    let errorFree: @convention(c) (Pointer) -> Void
    let quarkToString: @convention(c) (UInt32) -> CString?
    let paramSpecGetName: @convention(c) (Pointer) -> CString?
    let bytesNew: @convention(c) (UnsafeRawPointer?, Int) -> Pointer?
    let bytesUnref: @convention(c) (Pointer) -> Void
    let errorNewLiteral: @convention(c) (UInt32, Int32, CString) -> Pointer?
    let quarkFromString: @convention(c) (CString) -> UInt32

    // MARK: GIO's streams, for bodies

    let memoryInputStreamNewFromBytes: @convention(c) (Pointer) -> Pointer?
    let inputStreamRead: @convention(c) (Pointer, Pointer, Int, Pointer?, UnsafeMutablePointer<Pointer?>?) -> Int

    // MARK: libsoup's headers

    let soupMessageHeadersNew: @convention(c) (Int32) -> Pointer?
    let soupMessageHeadersAppend: @convention(c) (Pointer, CString, CString) -> Void
    let soupMessageHeadersForeach: @convention(c) (Pointer, UnsafeRawPointer, Pointer?) -> Void

    // MARK: Constants

    /// `wpe_view_activity_state`.
    static let visible: UInt32 = 1, focused: UInt32 = 2, inWindow: UInt32 = 4
    /// `WebKitNetworkProxyMode`.
    static let proxyModeDefault: Int32 = 0, proxyModeCustom: Int32 = 2
    /// `SoupMessageHeadersType`.
    static let responseHeaders: Int32 = 1

    /// The libraries, initialized; nil when WPE WebKit isn't installed.
    static let shared: WPELibrary? = WPELibrary()

    private init?() {
        // GIO and libsoup are WPE WebKit's own dependencies, so they're
        // there wherever it is.
        let names = ["libwpe-1.0.so.1", "libWPEBackend-fdo-1.0.so.1", "libwayland-server.so.0", "libWPEWebKit-2.0.so.1",
                     "libglib-2.0.so.0", "libgobject-2.0.so.0", "libgio-2.0.so.0", "libsoup-3.0.so.0"]
        // Local, so WPE's libraries, its JavaScriptCore among them, never
        // stand in for others of the same names in the process.
        let libraries = names.map { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
        guard let wpe = libraries[0], let fdo = libraries[1], let wayland = libraries[2], let webkit = libraries[3],
              let glib = libraries[4], let gobject = libraries[5], let gio = libraries[6], let soup = libraries[7] else {
            let absent = zip(names, libraries).filter { $0.1 == nil }.map(\.0)
            WPEEngine.log("WPE WebKit isn't installed (no \(absent.joined(separator: ", ")))")
            return nil
        }
        var missing: [String] = []
        func bind<Function>(_ library: Pointer, _ name: String) -> Function {
            guard let symbol = dlsym(library, name) else {
                missing.append(name)
                return unsafeBitCast(WPELibrary.missingFunction, to: Function.self)
            }
            return unsafeBitCast(symbol, to: Function.self)
        }
        let loaderInit: @convention(c) (CString) -> Int32 = bind(wpe, "wpe_loader_init")
        let initializeShm: @convention(c) () -> Int32 = bind(fdo, "wpe_fdo_initialize_shm")

        viewBackendAddActivityState = bind(wpe, "wpe_view_backend_add_activity_state")
        viewBackendRemoveActivityState = bind(wpe, "wpe_view_backend_remove_activity_state")
        viewBackendDispatchSetSize = bind(wpe, "wpe_view_backend_dispatch_set_size")
        viewBackendDispatchSetDeviceScaleFactor = bind(wpe, "wpe_view_backend_dispatch_set_device_scale_factor")
        viewBackendDispatchPointerEvent = bind(wpe, "wpe_view_backend_dispatch_pointer_event")
        viewBackendDispatchAxisEvent = bind(wpe, "wpe_view_backend_dispatch_axis_event")
        viewBackendDispatchKeyboardEvent = bind(wpe, "wpe_view_backend_dispatch_keyboard_event")
        unicodeToKeyCode = bind(wpe, "wpe_unicode_to_key_code")
        exportableCreate = bind(fdo, "wpe_view_backend_exportable_fdo_create")
        exportableDestroy = bind(fdo, "wpe_view_backend_exportable_fdo_destroy")
        exportableGetViewBackend = bind(fdo, "wpe_view_backend_exportable_fdo_get_view_backend")
        exportableFrameComplete = bind(fdo, "wpe_view_backend_exportable_fdo_dispatch_frame_complete")
        exportableReleaseShmBuffer = bind(fdo, "wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer")
        shmExportedBufferGetShmBuffer = bind(fdo, "wpe_fdo_shm_exported_buffer_get_shm_buffer")

        shmBufferGetData = bind(wayland, "wl_shm_buffer_get_data")
        shmBufferGetWidth = bind(wayland, "wl_shm_buffer_get_width")
        shmBufferGetHeight = bind(wayland, "wl_shm_buffer_get_height")
        shmBufferGetStride = bind(wayland, "wl_shm_buffer_get_stride")
        shmBufferBeginAccess = bind(wayland, "wl_shm_buffer_begin_access")
        shmBufferEndAccess = bind(wayland, "wl_shm_buffer_end_access")

        webViewBackendNew = bind(webkit, "webkit_web_view_backend_new")
        webViewNew = bind(webkit, "webkit_web_view_new")
        webViewLoadHTML = bind(webkit, "webkit_web_view_load_html")
        webViewLoadURI = bind(webkit, "webkit_web_view_load_uri")
        webViewGetTitle = bind(webkit, "webkit_web_view_get_title")
        webViewGetURI = bind(webkit, "webkit_web_view_get_uri")
        webViewIsLoading = bind(webkit, "webkit_web_view_is_loading")
        webViewGetEstimatedLoadProgress = bind(webkit, "webkit_web_view_get_estimated_load_progress")
        webViewCanGoBack = bind(webkit, "webkit_web_view_can_go_back")
        webViewCanGoForward = bind(webkit, "webkit_web_view_can_go_forward")
        webViewGoBack = bind(webkit, "webkit_web_view_go_back")
        webViewGoForward = bind(webkit, "webkit_web_view_go_forward")
        webViewReload = bind(webkit, "webkit_web_view_reload")
        webViewStopLoading = bind(webkit, "webkit_web_view_stop_loading")
        webViewGetSettings = bind(webkit, "webkit_web_view_get_settings")
        settingsSetUserAgent = bind(webkit, "webkit_settings_set_user_agent")
        settingsSetAllowFileAccessFromFileURLs = bind(webkit, "webkit_settings_set_allow_file_access_from_file_urls")

        webViewEvaluateJavaScript = bind(webkit, "webkit_web_view_evaluate_javascript")
        webViewEvaluateJavaScriptFinish = bind(webkit, "webkit_web_view_evaluate_javascript_finish")
        webViewCallAsyncJavaScriptFunction = bind(webkit, "webkit_web_view_call_async_javascript_function")
        webViewCallAsyncJavaScriptFunctionFinish = bind(webkit, "webkit_web_view_call_async_javascript_function_finish")
        valueIsUndefined = bind(webkit, "jsc_value_is_undefined")
        valueToJSON = bind(webkit, "jsc_value_to_json")
        webViewGetUserContentManager = bind(webkit, "webkit_web_view_get_user_content_manager")
        registerScriptMessageHandler = bind(webkit, "webkit_user_content_manager_register_script_message_handler")
        unregisterScriptMessageHandler = bind(webkit, "webkit_user_content_manager_unregister_script_message_handler")
        registerScriptMessageHandlerWithReply = bind(webkit, "webkit_user_content_manager_register_script_message_handler_with_reply")
        scriptMessageReplyRef = bind(webkit, "webkit_script_message_reply_ref")
        scriptMessageReplyUnref = bind(webkit, "webkit_script_message_reply_unref")
        scriptMessageReplyReturnValue = bind(webkit, "webkit_script_message_reply_return_value")
        scriptMessageReplyReturnErrorMessage = bind(webkit, "webkit_script_message_reply_return_error_message")
        valueGetContext = bind(webkit, "jsc_value_get_context")
        valueNewFromJSON = bind(webkit, "jsc_value_new_from_json")
        valueNewUndefined = bind(webkit, "jsc_value_new_undefined")
        contextClearException = bind(webkit, "jsc_context_clear_exception")
        userScriptNew = bind(webkit, "webkit_user_script_new")
        userScriptUnref = bind(webkit, "webkit_user_script_unref")
        userContentManagerAddScript = bind(webkit, "webkit_user_content_manager_add_script")
        userContentManagerRemoveAllScripts = bind(webkit, "webkit_user_content_manager_remove_all_scripts")

        webViewGetContext = bind(webkit, "webkit_web_view_get_context")
        webContextRegisterURIScheme = bind(webkit, "webkit_web_context_register_uri_scheme")
        webContextGetSecurityManager = bind(webkit, "webkit_web_context_get_security_manager")
        securityManagerRegisterURISchemeAsSecure = bind(webkit, "webkit_security_manager_register_uri_scheme_as_secure")
        securityManagerRegisterURISchemeAsCORSEnabled = bind(webkit, "webkit_security_manager_register_uri_scheme_as_cors_enabled")
        uriSchemeRequestGetURI = bind(webkit, "webkit_uri_scheme_request_get_uri")
        uriSchemeRequestGetPath = bind(webkit, "webkit_uri_scheme_request_get_path")
        uriSchemeRequestGetWebView = bind(webkit, "webkit_uri_scheme_request_get_web_view")
        uriSchemeRequestGetHTTPMethod = bind(webkit, "webkit_uri_scheme_request_get_http_method")
        uriSchemeRequestGetHTTPHeaders = bind(webkit, "webkit_uri_scheme_request_get_http_headers")
        uriSchemeRequestGetHTTPBody = bind(webkit, "webkit_uri_scheme_request_get_http_body")
        uriSchemeRequestFinishWithResponse = bind(webkit, "webkit_uri_scheme_request_finish_with_response")
        uriSchemeRequestFinishError = bind(webkit, "webkit_uri_scheme_request_finish_error")
        uriSchemeResponseNew = bind(webkit, "webkit_uri_scheme_response_new")
        uriSchemeResponseSetStatus = bind(webkit, "webkit_uri_scheme_response_set_status")
        uriSchemeResponseSetContentType = bind(webkit, "webkit_uri_scheme_response_set_content_type")
        uriSchemeResponseSetHTTPHeaders = bind(webkit, "webkit_uri_scheme_response_set_http_headers")

        navigationPolicyDecisionGetNavigationAction = bind(webkit, "webkit_navigation_policy_decision_get_navigation_action")
        navigationActionGetRequest = bind(webkit, "webkit_navigation_action_get_request")
        navigationActionGetNavigationType = bind(webkit, "webkit_navigation_action_get_navigation_type")
        navigationActionGetModifiers = bind(webkit, "webkit_navigation_action_get_modifiers")
        navigationActionGetMouseButton = bind(webkit, "webkit_navigation_action_get_mouse_button")
        uriRequestGetURI = bind(webkit, "webkit_uri_request_get_uri")
        policyDecisionUse = bind(webkit, "webkit_policy_decision_use")
        policyDecisionIgnore = bind(webkit, "webkit_policy_decision_ignore")

        networkSessionGetDefault = bind(webkit, "webkit_network_session_get_default")
        networkSessionSetProxySettings = bind(webkit, "webkit_network_session_set_proxy_settings")
        networkProxySettingsNew = bind(webkit, "webkit_network_proxy_settings_new")
        networkProxySettingsFree = bind(webkit, "webkit_network_proxy_settings_free")

        mainContextIteration = bind(glib, "g_main_context_iteration")
        mainContextAcquire = bind(glib, "g_main_context_acquire")
        mainContextPrepare = bind(glib, "g_main_context_prepare")
        mainContextQuery = bind(glib, "g_main_context_query")
        signalConnectData = bind(gobject, "g_signal_connect_data")
        signalHandlerDisconnect = bind(gobject, "g_signal_handler_disconnect")
        objectRef = bind(gobject, "g_object_ref")
        objectUnref = bind(gobject, "g_object_unref")
        free = bind(glib, "g_free")
        errorFree = bind(glib, "g_error_free")
        quarkToString = bind(glib, "g_quark_to_string")
        paramSpecGetName = bind(gobject, "g_param_spec_get_name")
        bytesNew = bind(glib, "g_bytes_new")
        bytesUnref = bind(glib, "g_bytes_unref")
        errorNewLiteral = bind(glib, "g_error_new_literal")
        quarkFromString = bind(glib, "g_quark_from_string")

        memoryInputStreamNewFromBytes = bind(gio, "g_memory_input_stream_new_from_bytes")
        inputStreamRead = bind(gio, "g_input_stream_read")

        soupMessageHeadersNew = bind(soup, "soup_message_headers_new")
        soupMessageHeadersAppend = bind(soup, "soup_message_headers_append")
        soupMessageHeadersForeach = bind(soup, "soup_message_headers_foreach")

        guard missing.isEmpty else {
            WPEEngine.log("WPE WebKit is incomplete (no \(missing.joined(separator: ", ")))")
            return nil
        }
        guard loaderInit("libWPEBackend-fdo-1.0.so.1") != 0, initializeShm() != 0 else {
            WPEEngine.log("WPEBackend-fdo didn't initialize")
            return nil
        }
    }

    private static let missingFunction: @convention(c) () -> Void = {}

    /// A GError's domain, code and message.
    func error(_ error: Pointer) -> WPEError {
        let domain = quarkToString(error.load(as: UInt32.self)).map { String(cString: $0) } ?? ""
        let code = Int(error.load(fromByteOffset: 4, as: Int32.self))
        let message = error.load(fromByteOffset: 8, as: CString?.self).map { String(cString: $0) } ?? ""
        return WPEError(domain: domain, code: code, message: message)
    }

    /// Takes a GError that a call may have left, where there is one.
    func takeError(_ error: Pointer?) -> WPEError? {
        guard let error else { return nil }
        defer { errorFree(error) }
        return self.error(error)
    }
}
