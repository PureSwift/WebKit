/// An error from WPE WebKit, GLib or the network: a GError's fields.
public struct WPEError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The error's domain by name, such as `WebKitNetworkError`.
    public var domain: String

    public var code: Int

    public var message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public var description: String { "\(domain) \(code): \(message)" }

    /// What a page's calls fail with when WPE WebKit gave no error of its own.
    static let unknown = WPEError(domain: "", code: 0, message: "the call failed")
}
