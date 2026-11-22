/// What a page awaits from a message it posted to a handler that replies
/// (`WPEWebContent.addScriptMessageHandler(_:replies:)`): the value its
/// `postMessage` promise resolves to, or the error it rejects with, once.
///
/// It keeps WebKit's reply until it is answered. One let go unanswered
/// rejects, so the page doesn't wait for it. A reply answered after its
/// page went away, or a second time, does nothing.
public final class WPEScriptMessageReply {

    private let library: WPELibrary

    private var reply: WPELibrary.Pointer?

    /// The JavaScriptCore context the message's value came from, which the
    /// reply's value is made in.
    private let context: WPELibrary.Pointer?

    /// Whether the reply was given, or its page went away.
    public var isAnswered: Bool {
        reply == nil
    }

    init(library: WPELibrary, reply: WPELibrary.Pointer, context: WPELibrary.Pointer?) {
        self.library = library
        self.reply = library.scriptMessageReplyRef(reply)
        self.context = context.flatMap(library.objectRef)
    }

    deinit {
        returnError("no reply")
        if let context {
            library.objectUnref(context)
        }
    }

    /// Resolves the page's promise with a value as JSON, fragments allowed,
    /// or with `undefined` for nil. Text that isn't JSON rejects it.
    public func returnValue(json: String?) {
        guard let reply = take() else { return }
        defer { library.scriptMessageReplyUnref(reply) }
        guard let context else {
            return library.scriptMessageReplyReturnErrorMessage(reply, "the page can't take a value")
        }
        let value = json.map { library.valueNewFromJSON(context, $0) } ?? library.valueNewUndefined(context)
        guard let value else {
            // What didn't parse leaves an exception in the context.
            library.contextClearException(context)
            return library.scriptMessageReplyReturnErrorMessage(reply, "the reply isn't JSON")
        }
        defer { library.objectUnref(value) }
        library.scriptMessageReplyReturnValue(reply, value)
    }

    /// Rejects the page's promise with an error whose message is `message`.
    public func returnError(_ message: String) {
        guard let reply = take() else { return }
        defer { library.scriptMessageReplyUnref(reply) }
        library.scriptMessageReplyReturnErrorMessage(reply, message)
    }

    /// The page went away: there's no one to answer.
    func abandon() {
        returnError("the page went away")
    }

    private func take() -> WPELibrary.Pointer? {
        defer { reply = nil }
        return reply
    }
}
