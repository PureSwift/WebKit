/// A request a page made for a URL in a scheme its host answers
/// (`WPEWebContent.registerURLScheme`), and the answer, once.
///
/// It keeps WebKit's request until it is finished or failed. One let go
/// unanswered fails, so the page doesn't wait for it. A task finished after
/// its page went away, or a second time, does nothing.
public final class WPEURLSchemeTask {

    /// The URL, as the page asked for it.
    public let url: String

    /// The URL's path: what follows the scheme, without its query.
    public let path: String

    /// The method, such as `GET`, or `POST` for a form or a `fetch` with a
    /// body.
    public let method: String

    /// The request's headers, in order.
    public let headers: [(name: String, value: String)]

    /// The request's body, nil when it has none.
    public let body: [UInt8]?

    private let library: WPELibrary

    private var request: WPELibrary.Pointer?

    /// Whether the task was finished or failed, or its page went away.
    public var isFinished: Bool {
        request == nil
    }

    init(library: WPELibrary, request: WPELibrary.Pointer) {
        self.library = library
        self.request = library.objectRef(request)
        url = library.uriSchemeRequestGetURI(request).map { String(cString: $0) } ?? ""
        path = library.uriSchemeRequestGetPath(request).map { String(cString: $0) } ?? ""
        method = library.uriSchemeRequestGetHTTPMethod(request).map { String(cString: $0) } ?? "GET"
        headers = library.uriSchemeRequestGetHTTPHeaders(request).map { WPEURLSchemeTask.headers($0, library) } ?? []
        body = library.uriSchemeRequestGetHTTPBody(request).flatMap { WPEURLSchemeTask.read($0, library) }
    }

    deinit {
        fail(.unknown, message: "no response for \(url)")
    }

    /// Answers the request: a status, the type of what's in `body`, and any
    /// other headers.
    public func finish(status: Int = 200, contentType: String?, headers: [(name: String, value: String)] = [], body: [UInt8]) {
        guard let request = take() else { return }
        defer { library.objectUnref(request) }
        guard let bytes = body.withUnsafeBytes({ library.bytesNew($0.baseAddress, $0.count) }),
              let stream = library.memoryInputStreamNewFromBytes(bytes) else {
            return fail(request, .unknown, "can't answer \(url)")
        }
        library.bytesUnref(bytes)
        defer { library.objectUnref(stream) }
        guard let response = library.uriSchemeResponseNew(stream, Int64(body.count)) else {
            return fail(request, .unknown, "can't answer \(url)")
        }
        defer { library.objectUnref(response) }
        library.uriSchemeResponseSetStatus(response, UInt32(clamping: status), nil)
        var headers = headers
        if let contentType {
            library.uriSchemeResponseSetContentType(response, contentType)
            // WebKit takes the type as the resource's, but only headers
            // reach a page's `fetch`.
            if !headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                headers.append(("Content-Type", contentType))
            }
        }
        if !headers.isEmpty, let soupHeaders = library.soupMessageHeadersNew(WPELibrary.responseHeaders) {
            for header in headers {
                library.soupMessageHeadersAppend(soupHeaders, header.name, header.value)
            }
            // The response takes the headers.
            library.uriSchemeResponseSetHTTPHeaders(response, soupHeaders)
        }
        library.uriSchemeRequestFinishWithResponse(request, response)
    }

    /// Fails the request: the page sees a failed load, and a navigation's
    /// delegate hears `code`.
    public func fail(_ code: WPEWebContent.ErrorCode, message: String) {
        guard let request = take() else { return }
        defer { library.objectUnref(request) }
        fail(request, code, message)
    }

    /// The page went away: nothing can be answered.
    func abandon() {
        fail(.cancelled, message: "the page went away")
    }

    private func take() -> WPELibrary.Pointer? {
        defer { request = nil }
        return request
    }

    private func fail(_ request: WPELibrary.Pointer, _ code: WPEWebContent.ErrorCode, _ message: String) {
        guard let error = library.errorNewLiteral(library.quarkFromString(WPEURLSchemeTask.errorDomain), code.rawValue, message) else {
            return
        }
        defer { library.errorFree(error) }
        library.uriSchemeRequestFinishError(request, error)
    }

    /// The GError domain of a task's failures, whose codes are
    /// `WPEWebContent.ErrorCode`s.
    static let errorDomain = "org.pureswift.web"

    // MARK: The request

    private final class HeaderList {
        var headers: [(name: String, value: String)] = []
    }

    private static func headers(_ soupHeaders: WPELibrary.Pointer, _ library: WPELibrary) -> [(name: String, value: String)] {
        let list = HeaderList()
        withExtendedLifetime(list) {
            library.soupMessageHeadersForeach(soupHeaders, unsafeBitCast(onHeader, to: UnsafeRawPointer.self),
                                              Unmanaged.passUnretained(list).toOpaque())
        }
        return list.headers
    }

    /// `SoupMessageHeadersForeachFunc`: a header's name and value.
    private static let onHeader: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, WPELibrary.Pointer?) -> Void = {
        name, value, data in
        guard let name, let value, let data else { return }
        Unmanaged<HeaderList>.fromOpaque(data).takeUnretainedValue().headers.append((String(cString: name), String(cString: value)))
    }

    /// Reads a body's stream, which it takes, whole. WebKit gives a request's
    /// body as a stream in memory, so this doesn't block.
    private static func read(_ stream: WPELibrary.Pointer, _ library: WPELibrary) -> [UInt8]? {
        defer { library.objectUnref(stream) }
        var body: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var error: WPELibrary.Pointer?
            let count = chunk.withUnsafeMutableBytes { library.inputStreamRead(stream, $0.baseAddress!, $0.count, nil, &error) }
            if let error = library.takeError(error) {
                WPEEngine.log("can't read a request's body: \(error)")
                return nil
            }
            guard count > 0 else { break }
            body.append(contentsOf: chunk[..<count])
        }
        return body
    }
}
