/// A step of a load: `WebKitLoadEvent`.
public enum WPELoadEvent: Int32, Hashable, Sendable {
    /// A navigation began, and the page's URI is where it is headed.
    case started = 0
    /// The server sent the navigation elsewhere.
    case redirected = 1
    /// The first of the new page arrived, and the page's URI is where it is.
    case committed = 2
    /// The load ended, whether or not it failed.
    case finished = 3
}

/// What of a page changed, by the property WPE WebKit notifies.
public enum WPEPageProperty: String, Hashable, Sendable {
    case title
    case uri
    case isLoading = "is-loading"
    case estimatedLoadProgress = "estimated-load-progress"
}

/// A navigation a page asks about before it follows it.
public struct WPENavigation: Hashable, Sendable {

    /// What set the navigation off: `WebKitNavigationType`.
    public enum Kind: Int32, Hashable, Sendable {
        case linkClicked = 0
        case formSubmitted = 1
        case backForward = 2
        case reload = 3
        case formResubmitted = 4
        case other = 5
    }

    /// Where the navigation goes.
    public var uri: String

    public var kind: Kind

    /// Whether the page asked for a new window, which the engine has none
    /// to give: allowed, it goes nowhere, so a host loads `uri` itself.
    public var opensNewWindow: Bool

    /// The keys held when a click set the navigation off.
    public var modifiers: WPEModifiers

    /// The button of that click, or nil when there was none.
    public var button: WPEButton?

    public init(uri: String, kind: Kind, opensNewWindow: Bool = false, modifiers: WPEModifiers = [], button: WPEButton? = nil) {
        self.uri = uri
        self.kind = kind
        self.opensNewWindow = opensNewWindow
        self.modifiers = modifiers
        self.button = button
    }
}

/// The answer a page waits for about a navigation. The page follows the
/// navigation if this goes unanswered.
public final class WPEPolicyDecision {

    private let library: WPELibrary

    private var decision: WPELibrary.Pointer?

    /// Keeps WebKit's decision until it is answered.
    init(library: WPELibrary, decision: WPELibrary.Pointer) {
        self.library = library
        self.decision = library.objectRef(decision)
    }

    deinit {
        answer(true)
    }

    /// Lets the navigation go ahead.
    public func allow() {
        answer(true)
    }

    /// Stops the navigation, which is not a failed load.
    public func cancel() {
        answer(false)
    }

    private func answer(_ allowed: Bool) {
        guard let decision else { return }
        self.decision = nil
        if allowed {
            library.policyDecisionUse(decision)
        } else {
            library.policyDecisionIgnore(decision)
        }
        library.objectUnref(decision)
    }
}
