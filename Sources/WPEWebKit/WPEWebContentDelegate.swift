/// Receives a `WPEWebContent`'s state and questions, on WebKit's main thread.
///
/// A new page has no URL, an empty title, and isn't loading; the delegate
/// hears every change from there. The methods are those of AppRuntime's
/// `WebContentDelegate`, so a host for it passes them straight through.
public protocol WPEWebContentDelegate: AnyObject {

    /// Whether the page may go to `url`. The page waits for the answer:
    /// it's asked before every navigation the page or the user starts, and
    /// isn't asked for `load` or `loadHTML` themselves. `kind` is a
    /// `WPEWebContent.NavigationKind` raw value.
    func shouldNavigate(_ content: WPEWebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool

    /// The main frame shows another URL: a navigation committed, a redirect
    /// was followed, or the page changed it with the History API.
    func didChangeURL(_ content: WPEWebContent, url: String?)

    func didChangeTitle(_ content: WPEWebContent, title: String)

    /// Loading started, went on, or ended. `progress` is 0…1, and 1 once
    /// loading ends.
    func didChangeLoading(_ content: WPEWebContent, isLoading: Bool, progress: Double)

    func didChangeHistory(_ content: WPEWebContent, canGoBack: Bool, canGoForward: Bool)

    /// The main frame finished loading.
    func didFinishNavigation(_ content: WPEWebContent)

    /// The main frame's navigation failed. `error` is a
    /// `WPEWebContent.ErrorCode` raw value, and `message` the engine's own
    /// description.
    func didFailNavigation(_ content: WPEWebContent, error: Int32, message: String)

    /// The outcome of `evaluateJavaScript` for `request`: the script's
    /// value as JSON text (`nil` for `undefined` and values JSON can't
    /// hold), or the exception's message in `error`.
    func didEvaluateJavaScript(_ content: WPEWebContent, request: Int32, result: String?, error: String?)
}

extension WPEWebContent {

    /// What started a navigation, numbered as AppRuntime's
    /// `WebNavigationKind`.
    public enum NavigationKind: Int32, Hashable, Sendable {
        /// The user followed a link.
        case linkActivated = 0
        case formSubmitted = 1
        /// Back or forward in the history.
        case backForward = 2
        case reload = 3
        /// A script, a redirect, or anything else.
        case other = 4

        /// A `WebKitNavigationType`.
        init(type: Int32) {
            switch type {
            case 0: self = .linkActivated
            case 1, 4: self = .formSubmitted    // submitted, resubmitted
            case 2: self = .backForward
            case 3: self = .reload
            default: self = .other
            }
        }
    }

    /// Why a navigation failed, numbered as AppRuntime's `WebError.Code`.
    public enum ErrorCode: Int32, Hashable, Sendable {
        case unknown = 0
        /// For the delegate's own use: the engine never sends it.
        case cancelled = 1
        /// No connection, or the server couldn't be found or reached.
        case network = 2
        case timedOut = 3
        /// The connection wasn't secure enough to use.
        case security = 4
        /// A malformed URL, or a scheme or file the engine can't load.
        case badURL = 5
        /// For the delegate's own use: a script threw.
        case javaScript = 6
        /// The URL is remote, and the network isn't allowed.
        case notPermitted = 7

        /// The code for a load's error; nil when it isn't a failure: the
        /// load was stopped, or replaced by another navigation.
        public init?(_ error: WPEError) {
            switch error.domain {
            case "WebKitNetworkError":
                switch error.code {
                case 302: return nil                // cancelled
                case 300: self = .network           // transport
                case 301, 303: self = .badURL       // unknown protocol, no such file
                default: self = .unknown
                }
            case "WebKitPolicyError":
                switch error.code {
                case 102: return nil                // interrupted by a policy change
                case 101: self = .badURL            // can't show the URI
                default: self = .unknown
                }
            case "g-resolver-error-quark", "soup-session-error-quark":
                self = .network
            case "g-io-error-quark":
                self = error.code == 24 ? .timedOut : .network
            case "g-tls-error-quark":
                self = .security
            case WPEURLSchemeTask.errorDomain:
                // A host's own failure, from a URL scheme it answers.
                self = ErrorCode(rawValue: Int32(clamping: error.code)) ?? .unknown
            default:
                self = .unknown
            }
        }
    }
}
