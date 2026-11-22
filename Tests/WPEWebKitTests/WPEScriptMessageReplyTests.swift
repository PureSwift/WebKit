import Foundation
import Testing
import WPEWebKit

/// Messages a page awaits a reply to, in WPE WebKit itself.
@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WPEScriptMessageReplyTests {

    /// A script that posts `message` to the `host` handler and returns what
    /// the promise resolves to, or `{ error: message }` when it rejects.
    static func post(_ message: String) -> String {
        """
        try {
            const value = await window.webkit.messageHandlers.host.postMessage(\(message));
            return value === undefined ? 'undefined' : value;
        } catch (error) {
            return { error: String(error && error.message !== undefined ? error.message : error) };
        }
        """
    }

    /// A page with a `host` handler that replies.
    static func page(_ answer: @escaping (String?, WPEScriptMessageReply) -> Void) throws -> Page {
        let page = try Page()
        page.content.addScriptMessageHandler("host", replies: true)
        page.content.onScriptMessageWithReply = { name, body, reply in
            #expect(name == "host")
            answer(body, reply)
        }
        try page.load(html: "<p>Text</p>")
        return page
    }

    @Test func resolvesWithTheReply() throws {
        var bodies: [String?] = []
        let page = try Self.page { body, reply in
            bodies.append(body)
            reply.returnValue(json: #"{"doubled":4,"list":[true,null]}"#)
        }
        #expect(try page.callAsync(Self.post("{ n: 2 }")) == #"{"doubled":4,"list":[true,null]}"#)
        #expect(bodies == [#"{"n":2}"#])
    }

    @Test func resolvesWithFragmentsAndUndefined() throws {
        var replies = [#""text""#, "7", nil]
        let page = try Self.page { _, reply in
            reply.returnValue(json: replies.removeFirst())
        }
        #expect(try page.callAsync(Self.post("1")) == #""text""#)
        #expect(try page.callAsync(Self.post("2")) == "7")
        #expect(try page.callAsync(Self.post("3")) == #""undefined""#)
    }

    @Test func rejectsWithTheError() throws {
        let page = try Self.page { _, reply in
            reply.returnError("not today")
        }
        #expect(try page.callAsync(Self.post("1")) == #"{"error":"not today"}"#)
    }

    @Test func rejectsWhatIsntJSON() throws {
        let page = try Self.page { _, reply in
            reply.returnValue(json: "{ not json")
        }
        #expect(try page.callAsync(Self.post("1")) == #"{"error":"the reply isn't JSON"}"#)
        // The context is left without the parse's exception.
        #expect(try page.evaluate("1 + 1") == "2")
    }

    @Test func repliesLaterAndOnlyOnce() throws {
        var replies: [WPEScriptMessageReply] = []
        let page = try Self.page { _, reply in replies.append(reply) }
        var outcome: Result<String?, WPEError>?
        page.content.callAsyncJavaScript(Self.post("1")) { outcome = $0 }
        try wait(for: "the message") { !replies.isEmpty }
        let reply = try #require(replies.first)
        WPEEngine.dispatch(for: 0.2) { false }
        #expect(outcome == nil)
        #expect(!reply.isAnswered)
        reply.returnValue(json: "42")
        #expect(reply.isAnswered)
        // Answering again does nothing.
        reply.returnValue(json: "43")
        reply.returnError("too late")
        try wait(for: "the reply") { outcome != nil }
        #expect(try outcome?.get() == "42")
    }

    @Test func rejectsAReplyItsHostLetsGo() throws {
        let page = try Self.page { _, _ in }
        #expect(try page.callAsync(Self.post("1")) == #"{"error":"no reply"}"#)
    }

    @Test func rejectsWithoutAHandler() throws {
        let page = try Page()
        page.content.addScriptMessageHandler("host", replies: true)
        try page.load(html: "<p>Text</p>")
        #expect(try page.callAsync(Self.post("1")) == #"{"error":"nothing answers host"}"#)
    }

    @Test func keepsOneWayHandlersApart() throws {
        let page = try Page()
        var oneWay: [String] = []
        page.content.onScriptMessage = { name, body in oneWay.append("\(name) \(body ?? "undefined")") }
        page.content.onScriptMessageWithReply = { _, _, reply in reply.returnValue(json: #""replied""#) }
        page.content.addScriptMessageHandler("note")
        page.content.addScriptMessageHandler("host", replies: true)
        // A name has one handler: added again, either way, it stays as it was.
        page.content.addScriptMessageHandler("note", replies: true)
        try page.load(html: "<p>Text</p>")
        _ = try page.evaluate("window.webkit.messageHandlers.note.postMessage('hi'); true")
        try wait(for: "the one-way message") { !oneWay.isEmpty }
        #expect(oneWay == [#"note "hi""#])
        #expect(try page.callAsync(Self.post("1")) == #""replied""#)
        page.content.removeScriptMessageHandler("host")
        try page.load(html: "<p>Again</p>")
        #expect(try page.evaluate("window.webkit.messageHandlers.host === undefined") == "true")
    }

    @Test func endsItsRepliesWhenItGoes() throws {
        var replies: [WPEScriptMessageReply] = []
        do {
            let page = try Self.page { _, reply in replies.append(reply) }
            _ = try page.evaluate("window.webkit.messageHandlers.host.postMessage(1); true")
            try wait(for: "the message") { !replies.isEmpty }
            #expect(replies.first?.isAnswered == false)
        }
        let reply = try #require(replies.first)
        #expect(reply.isAnswered)
        // No one to answer now.
        reply.returnValue(json: "1")
    }
}
