#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// WPE WebKit as a whole: whether it is there, the loop its pages need, and
/// the network they share.
///
/// WebKit's main thread is the first thread that calls it. Everything here
/// and every `WPEPage` is for that one thread.
public enum WPEEngine {

    /// Whether WPE WebKit is installed and loads. Without it no page can be
    /// made.
    public static var isAvailable: Bool {
        WPELibrary.shared != nil
    }

    // MARK: The loop

    /// Runs what GLib's main context has ready: the pages' signals, replies
    /// and frames. A host calls this from its own loop while there are
    /// pages, without blocking it.
    public static func dispatch() {
        guard let library = WPELibrary.shared else { return }
        var budget = 1000
        while budget > 0, library.mainContextIteration(nil, 0) != 0 {
            budget -= 1
        }
    }

    /// Runs GLib's main context until `condition` holds or the time runs
    /// out, and says whether it held. For tests, and for callers that must
    /// wait on a page.
    @discardableResult
    public static func dispatch(for seconds: Double, until condition: () -> Bool) -> Bool {
        guard let library = WPELibrary.shared else { return condition() }
        let deadline = now + seconds
        while !condition() {
            guard now < deadline else { return false }
            if library.mainContextIteration(nil, 0) == 0 {
                usleep(2000)
            }
        }
        return true
    }

    private static var now: Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    /// The pages there are.
    public internal(set) static var pageCount: Int {
        get { state.pageCount }
        set {
            state.pageCount = newValue
            onPageCountChanged?(newValue)
        }
    }

    /// Called when a page is made or goes, with how many there are: a host
    /// starts and stops calling `dispatch` here.
    public static var onPageCountChanged: ((Int) -> Void)? {
        get { state.onPageCountChanged }
        set { state.onPageCountChanged = newValue }
    }

    // MARK: The network

    /// Whether pages may reach the network. While they may not, a remote
    /// load fails as not permitted, and whatever else a page fetches goes
    /// through a proxy that refuses it.
    public static var isNetworkAllowed: Bool {
        get { state.isNetworkAllowed }
        set {
            state.isNetworkAllowed = newValue
            applyNetworkPolicy()
        }
    }

    /// Sets WebKit's proxy to match `isNetworkAllowed`, once per change.
    static func applyNetworkPolicy() {
        guard let library = WPELibrary.shared else { return }
        let allowed = state.isNetworkAllowed
        // Until the network is first forbidden, WebKit's settings are its
        // own.
        guard state.appliedNetwork != allowed, !(allowed && state.appliedNetwork == nil) else { return }
        guard let session = library.networkSessionGetDefault() else { return }
        state.appliedNetwork = allowed
        guard !allowed else {
            return library.networkSessionSetProxySettings(session, WPELibrary.proxyModeDefault, nil)
        }
        guard let settings = library.networkProxySettingsNew(refusingProxy, nil) else { return }
        library.networkSessionSetProxySettings(session, WPELibrary.proxyModeCustom, settings)
        library.networkProxySettingsFree(settings)
    }

    /// A proxy on a host that never resolves (`.invalid`, RFC 2606), so
    /// nothing can answer for it.
    static let refusingProxy = "http://no-network.invalid:8080"

    // MARK: Logging

    /// Where the engine reports what went wrong: standard error, unless a
    /// host has its own log.
    public static var logger: (String) -> Void {
        get { state.logger }
        set { state.logger = newValue }
    }

    static func log(_ message: String) {
        logger(message)
    }

    private struct State {
        var pageCount = 0
        var isNetworkAllowed = true
        var appliedNetwork: Bool?
        var onPageCountChanged: ((Int) -> Void)?
        var logger: (String) -> Void = { message in
            let line = "WebKit: \(message)\n"
            line.withCString { _ = write(2, $0, strlen($0)) }
        }
    }

    nonisolated(unsafe) private static var state = State()
}
