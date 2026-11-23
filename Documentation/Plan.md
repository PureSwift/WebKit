# WebKit — Plan

**Status:** a draft for review. Phases 2 to 4, URL schemes and replies
to script messages in `WPEWebKit` and `CacaoWebKit`'s API, are merged (#3,
#4, #5). Phase 1 is implemented: `WebView(content:)` here, on
`feature/web-view-content`, and LinuxAppRuntime over this package on its
`feature/pureswift-webkit`. Phase 5 is what's left.

This package has WPE WebKit pages drawn into Cacao's external surfaces
(`WPEWebKit`) and SwiftUI's `WebView` and `WebPage` on Cacao
(`CacaoWebKit`). A reader app needs a little more. Its articles are HTML
from templates, with scripts injected before the page's own. The page
tells the app when an image is tapped, and loads icons and images that the
app supplies. This plan covers what's left for that, and how
LinuxAppRuntime and AppRuntime take it up.

NetNewsWire's article view is the case it's measured against:

| It uses | For | Here |
|---|---|---|
| Two user scripts at document start, main frame only | Its article script, and a constant with a localized label | `addUserScript(_:atDocumentStart:mainFrameOnly:)` |
| Messages `imageWasClicked`, `imageWasShown`, `showFeedInspector`, `mediaSourceURLs`, none with replies | Opening an image full screen, the feed inspector, and media | `addScriptMessageHandler(_:)`, `onScriptMessage` |
| Schemes `nnwImageIcon:` and `nnwArticleImage:` | The feed's icon from the app's cache, and article images routed through the app | `registerURLScheme(_:)`, `onURLSchemeRequest` (phase 2) |
| A wheel, a trackpad, touch | Reading | `WebView`'s input |
| Links refused and opened in the browser | Keeping articles in the app | `navigationDecider`, `onNavigation` |

## What's here

- **Frames**: each `wl_shm` buffer published to `content.surface` as
  `.bgra` with its stride: no conversion, one copy.
- **Input**: `WebView` maps Cacao's `ExternalInput` (pointer with its
  button, hover, smooth 2D scrolling, touch as pointer and scroll, keys,
  typed text through `wpe_unicode_to_key_code`, focus) to the page.
- **The loop**: `WPEEngine.pump()` from the host's loop, woken by
  `WPEEngine.onReady`, so nothing polls.
- **The contract**: `WPEWebContent` and its delegate are AppRuntime's
  `WebContent` and `WebContentDelegate`, version 1.
- **Beyond it**: user scripts; one-way script message handlers, the body
  as JSON (`nil` for `undefined`); `callAsyncJavaScript`; navigation
  answers that come later (`onNavigation`); the user agent;
  `isNetworkAllowed`.
- **`CacaoWebKit.WebPage`** is `DynamicWebKit`'s `WebPage`. Until phase 4,
  what's beyond the contract was reached through `page.content`.

## What's left

| Where | What changes |
|---|---|
| `WPEWebKit` | Script messages with replies; URI schemes and their requests; GIO, and libsoup when headers are set, opened at run time |
| `CacaoWebKit` | `WebPage.Configuration` (user scripts, URL scheme handlers) and `WebPage`'s message handlers, so an app needn't reach for `content` |
| LinuxAppRuntime | `LinuxWebKit` and `HostWebView` replaced by this package; `WebContent` version 2 |
| AppRuntime | `WebContent` version 2 and `DynamicWebKit`'s API, the same shape as `CacaoWebKit`'s |
| DarwinAppRuntime | Version 2 over `WKUserContentController`, `WKScriptMessageHandlerWithReply` and `WKURLSchemeHandler` |

## What shapes it

- **One shape everywhere.** As now, `CacaoWebKit`'s types are
  `DynamicWebKit`'s, and `WPEWebContent` is the contract. Each addition
  here is added to all three at once, so a reader written against
  `CacaoWebKit` reads the same as one written for AppRuntime.
- **WebKit's JavaScript API.** Pages post with
  `window.webkit.messageHandlers.<name>.postMessage(body)`, as on Apple
  platforms. A message with a reply returns a promise, as
  `WKScriptMessageHandlerWithReply`'s does.
- **JSON across**, as messages and script results already are. A guest
  has no Foundation; it decodes what it needs.
- **A scheme is registered once per process.** WPE registers URI schemes
  on a `WebKitWebContext`, every page shares the default context, and a
  scheme can't be unregistered. The engine registers each name the first
  time a page asks for it, and sends each request to the page that made
  it (`webkit_uri_scheme_request_get_web_view`). A request from a page
  that didn't register the scheme fails.
- **Bodies are bytes.** A scheme task's bodies cross the contract as
  `[UInt8]`, as `HTTPRequest`'s do, and headers as `[String]`, name then
  value. `WPEWebKit` itself can use `Data`.
- **Main thread only**, as the engine is now: WebKit's main thread is the
  first that calls it.

## For an app

```swift
import CacaoWebKit

var configuration = WebPage.Configuration()
configuration.userScripts = [
    WebUserScript(source: articleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
]
configuration.urlSchemeHandlers["nnwimageicon"] = { request, respond in
    guard let icon = iconCache.png(forArticleID: request.path) else {
        respond(.failure(WebError(code: .badURL, message: "No icon")))
        return
    }
    respond(.success(WebURLSchemeResponse(status: 200, contentType: "image/png", body: icon)))
}

let page = WebPage(configuration: configuration)
page.navigationDecider = { navigation in navigation.kind != .linkActivated }

page.addMessageHandler(named: "imageWasClicked") { body in
    store.showImage(json: body)
}

page.addMessageHandler(named: "isReady", replyHandler: { body async throws(WebError) -> String? in
    "true"
})

page.load(html: renderedArticle, baseURL: article.feedHomePageURL)
```

- **User scripts** run in every document the page loads. They're set
  before the first load, and `removeAllUserScripts()` clears them for the
  next one.
- **Message handlers** are added and removed by name, at any time. One
  with no reply resolves the page's promise to `undefined` at once. One
  that replies returns JSON text, `nil` for `undefined`, or throws, which
  rejects the promise with the error's message.
- **URL scheme handlers** are fixed in the configuration, as in Apple's
  `WebPage.Configuration`, since WPE can't unregister a scheme. They're
  closures, not a protocol: Embedded Swift can't store `any` of a protocol
  that isn't class-bound, and `DynamicWebKit` must read the same. A
  handler calls `respond` once, at once or later; after the page cancels
  the request it does nothing.
- **Names.** Schemes are lowercased, so `nnwImageIcon` is `nnwimageicon`.
  `http`, `https`, `file`, `about`, `data`, `blob`, `javascript`, `ws` and
  `wss` can't be registered.
- **Where messages come from.** A handler hears every frame of the page,
  including a remote site it goes to. A reader that loads its own HTML and
  refuses other navigations hears only its own pages (Questions, 2).

## In WPEWebKit

### Replies

| Function | For |
|---|---|
| `webkit_user_content_manager_register_script_message_handler_with_reply` | A handler that replies, in the default world (`NULL`) |
| `webkit_script_message_reply_ref`, `…_unref`, `…_return_value`, `…_return_error_message` | The reply |
| `jsc_value_get_context`, `jsc_value_new_from_json`, `jsc_value_new_undefined` | Its value |

```swift
public func addScriptMessageHandler(_ name: String, replies: Bool = false)
public var onScriptMessageWithReply: ((String, String?, WPEScriptMessageReply) -> Void)?

public final class WPEScriptMessageReply {
    public var isAnswered: Bool
    public func returnValue(json: String?)
    public func returnError(_ message: String)
}
```

As built: the reply refs the message's `JSCContext` as well as WebKit's
reply, so a reply given later still has a context to make its value in.
Text that isn't JSON rejects the promise with "the reply isn't JSON" and
clears the exception the parse left in the context. A reply handler with no
`onScriptMessageWithReply` rejects with "nothing answers <name>", and a page
that goes rejects the replies it still owes with "the page went away". A
name has one handler, one-way or replying.

The handler connects `script-message-with-reply-received::<name>`, whose
callback also has a `WebKitScriptMessageReply` and returns `TRUE` to say it
will reply. `WPEScriptMessageReply` refs it and unrefs it once answered; a
reply dropped unanswered returns the error "No reply". The value is made
with `jsc_value_new_from_json` in the message's context, or
`jsc_value_new_undefined` for `nil`.

### URI schemes

| Function | Library | For |
|---|---|---|
| `webkit_web_view_get_context`, `webkit_web_context_register_uri_scheme` | WPE WebKit | Registering |
| `webkit_web_context_get_security_manager`, `webkit_security_manager_register_uri_scheme_as_secure`, `…_as_cors_enabled` | WPE WebKit | So an `https` page loads the scheme's images without mixed-content blocking, and `fetch` works |
| `webkit_uri_scheme_request_get_uri`, `…_get_web_view`, `…_get_http_method`, `…_get_http_headers`, `…_get_http_body` | WPE WebKit | The request |
| `webkit_uri_scheme_response_new`, `…_set_status`, `…_set_content_type`, `…_set_http_headers`, `webkit_uri_scheme_request_finish_with_response`, `webkit_uri_scheme_request_finish_error` | WPE WebKit | The answer |
| `g_memory_input_stream_new_from_bytes`, `g_input_stream_read` | GIO (`libgio-2.0.so.0`) | The bodies, as streams |
| `g_bytes_new`, `g_bytes_unref`, `g_error_new_literal`, `g_quark_from_static_string` | GLib | The bodies' bytes; failures, in the `org.pureswift.web` domain with `ErrorCode`s |
| `soup_message_headers_new`, `…_append`, `…_foreach` | libsoup 3 (`libsoup-3.0.so.0`), opened only when a request or response has headers | Headers |

```swift
/// Before the page loads what uses it. False for a name that isn't a
/// whole scheme, and for schemes WebKit loads itself.
@discardableResult public func registerURLScheme(_ scheme: String) -> Bool
public var onURLSchemeRequest: ((WPEURLSchemeTask) -> Void)?
public private(set) var urlSchemes: Set<String>

public final class WPEURLSchemeTask {
    public let url: String
    public let path: String
    public let method: String
    public let headers: [(name: String, value: String)]
    public let body: [UInt8]?
    public var isFinished: Bool
    public func finish(status: Int = 200, contentType: String?, headers: [(name: String, value: String)] = [], body: [UInt8])
    public func fail(_ code: WPEWebContent.ErrorCode, message: String)
}
```

As built: bodies are `[UInt8]`, as the contract's will be, so nothing
converts them on the way. WebKit takes `contentType` as the resource's type
but doesn't add it as a header, so `finish` adds `Content-Type` unless the
headers have one: otherwise `fetch` sees none. A host's failure is a GError
in the `org.pureswift.web` domain, whose code is the `ErrorCode`, so a
navigation's delegate hears the host's own code.

- One C callback serves every scheme. It refs the request, finds the page
  from its web view, through a table from each `WebKitWebView` to its
  page kept beside `content(identifier:)`'s, and hands it a task. A page that didn't register the
  scheme gets `notPermitted`.
- A request's body is read whole with `g_input_stream_read`. WebKit gives
  it as a memory stream, so that doesn't block: a `fetch` POST's body
  arrives whole in the tests.
- WPE says nothing when a page abandons a request. A task finished after
  its page is gone, or twice, is unreffed and dropped. A page that's
  released, or loads something else, fails its open tasks as cancelled.
- `isNetworkAllowed = false` sends requests to a proxy that never resolves.
  Custom schemes don't go through it: WebKit hands them to the callback,
  so pages without the network still load the app's images.

## The contract, version 2

`WebContent` gains, and `WPEWebContent` implements:

```swift
func addUserScript(_ source: String, atDocumentStart: Bool, mainFrameOnly: Bool)
func removeAllUserScripts()

func addMessageHandler(_ name: String, replies: Bool)
func removeMessageHandler(_ name: String)
func replyToMessage(_ reply: Int32, result: String?, error: String?)

func registerURLScheme(_ scheme: String) -> Bool
func finishURLSchemeTask(_ task: Int32, status: Int32, contentType: String?, headers: [String], body: [UInt8])
func failURLSchemeTask(_ task: Int32, error: Int32, message: String)
```

`WebContentDelegate` gains:

```swift
/// `reply` is 0 for a handler that doesn't reply.
func didReceiveMessage(_ content: WebContent, name: String, body: String, reply: Int32)

func startURLSchemeTask(_ content: WebContent, task: Int32, url: String, method: String, headers: [String], body: [UInt8]?)
/// The page no longer wants it. Finishing it afterward does nothing.
func stopURLSchemeTask(_ content: WebContent, task: Int32)
```

- Reply and task numbers count up from 1 for each page, and are never
  reused while it lives, as script requests' are.
- A page that's released or loads something else stops its tasks and
  fails each reply it owes with "The page went away".
- A reply or task finished twice: the second does nothing. A message to a
  removed handler is dropped.
- Version 1's methods don't change.

## Per host

| Host | Scripts | Messages | Schemes |
|---|---|---|---|
| Linux (this package) | `WebKitUserContentManager` | `script-message-received`, `…-with-reply-received` | `webkit_web_context_register_uri_scheme` |
| iOS 14+ / macOS 11+ | `WKUserScript` | `WKScriptMessageHandlerWithReply` | `WKURLSchemeHandler`, set on the configuration before the `WKWebView` is made |
| iOS 11–13 / macOS 10.13–10.15 | `WKUserScript` | `WKScriptMessageHandler`; a reply's promise resolves to `undefined` | `WKURLSchemeHandler` |
| iOS 6 | `stringByEvaluatingJavaScriptFromString` after each load | A private-scheme navigation the host decodes | `NSURLProtocol` |
| Android | `WebViewCompat.addDocumentStartJavaScript` | `WebViewCompat.addWebMessageListener`, with an injected `webkit.messageHandlers` shim | `shouldInterceptRequest` |
| Browser, `<iframe>` | Only for pages from the app's origin | `postMessage` to the parent, through the same shim | A service worker, or not supported |

## Phases

1. **LinuxAppRuntime on this package.** It depends on `WPEWebKit` and
   `CacaoWebKit`. `LinuxWebKit` registers `WPEWebContent` as the
   `WebContent` contract, and `HostWebView` becomes a `WebView` over the
   page the render IR names. Most of `WPE.swift`, `LinuxWebContent.swift`
   and `HostWebView.swift` goes, and with it `rgba(fromBGRA:)` and the
   drag gesture. Done when `ExampleWeb` runs as before under
   `Scripts/run-app.sh`, and scrolls with the wheel. `CacaoWebKit` needs
   `WebView(content:)`, or `WebPage(content:)`, for a page it didn't make.
   Implemented: `WebView(content:)` shows a `WPEWebContent` a host made,
   attached while on screen, with the view's input; the page's delegate
   stays the host's, so `WebPage(content:)`, which would need it, isn't
   needed. A host that set `WPEEngine.onReady` runs the engine's loop, and
   Cacao's leaves it. LinuxAppRuntime's `LinuxWebContent` makes a
   `WPEWebContent` and relays its delegate to the guest's, and
   `HostWebView` is a `WebView(content:)`; `WPE.swift`, the RGBA copy and
   the drag gesture are gone. This package declares macOS 14, as Cacao
   does, so its targets build on a Mac for LinuxAppRuntime's packager.
2. **URL schemes in `WPEWebKit`.** Done on `feature/url-schemes`: a page
   with an `https` base URL shows an image from a scheme, with the network
   allowed or not; `fetch` gets the status, type, headers and body, and the
   host gets the method, headers and body; a page loads from a scheme; a
   request from a page that didn't register it fails. This was all a
   NetNewsWire on Cacao lacked.
3. **Replies in `WPEWebKit`.** Done on `feature/script-message-replies`: a
   page's `postMessage` promise resolves with an object, a fragment or
   `undefined`, and rejects with the host's error, with text that isn't
   JSON, with no handler, and for a reply let go or owed when the page
   goes; one-way and replying handlers live side by side.
4. **`CacaoWebKit`'s API.** Done on `feature/web-page-configuration`:
   `WebPage(configuration:)` with `userScripts` and `urlSchemeHandlers`
   (`WebUserScript`, `WebURLSchemeHandler`, `WebURLSchemeRequest`,
   `WebURLSchemeResponse`), and `addMessageHandler(named:_:)`,
   `addMessageHandler(named:replyHandler:)` and
   `removeMessageHandler(named:)`. A replying handler has its own label,
   `replyHandler:`, or as a trailing closure its signature,
   `async throws(WebError) -> String?`: a closure such as
   `{ _ in "true" }` is a one-way handler, and the compiler warns that its
   string is unused. Handlers added before the engine's page is made, and the
   configuration, are applied when it is; the page then owns the engine
   page's message and scheme hooks. Schemes WebKit loads itself are left
   to it and logged. With no handlers left, WPE WebKit takes
   `window.webkit` away, as the tests found.
5. **The contract's version 2** in AppRuntime and `DynamicWebKit`, then
   LinuxAppRuntime (from this package) and DarwinAppRuntime.

## Not in this design

- **Input methods.** Typed text goes as keys through
  `wpe_unicode_to_key_code`. Composed text needs WPE's
  `WebKitInputMethodContext`.
- **GPU frames.** WebKit draws on the CPU in WPEBackend-fdo's
  shared-memory mode. `ExternalSurface`'s dma-buf path could take WPE's
  EGL exports, or the newer WPEPlatform API's buffers, with no copy.
- **Streaming a scheme's response** in parts: one body, whole. Icons and
  article images are small.
- **Context menus, find in page, zoom, printing, cookies, downloads.**
- **Isolated worlds** for scripts and handlers: the page's own world only.

## Alternatives weighed

- **Inlining images as `data:` URLs** in the HTML: needs nothing new, and
  works today, but NetNewsWire's article HTML would carry every icon and
  image in base64, re-rendered on each change. A stopgap until phase 2.
- **Messages through `evaluateJavaScript` polling:** a crossing per poll,
  and lost messages between polls.
- **Messages as navigations to a private scheme**, as on iOS 6: works on
  every engine, but a click becomes a navigation to refuse, and there are
  no replies. Kept for iOS 6.
- **Schemes over AppRuntime's HTTP contract**, the guest answering an
  `HTTPRequest`: it ties web views to `DynamicNetworking`, whose session
  needs `network`, which a page of the app's own content doesn't.
- **Keeping LinuxAppRuntime's own WPE layer:** two copies of the same
  bindings, and `HostWebView` stays without the wheel.

## Testing

As now, page tests run real pages without a display or the network, and
are skipped where WPE isn't installed.

- **Schemes:** an image from a scheme in an `https` page; status, type
  and headers; a request body; an unregistered page refused; reserved
  names refused; lowercased names; a task finished twice; a released page
  failing its tasks.
- **Replies:** resolved with a value, with `undefined`, rejected with an
  error; a reply left unanswered.
- **`CacaoWebKit`:** the configuration applied before the first load;
  handlers added and removed while a page is shown.
- **LinuxAppRuntime:** `ExampleWeb` gains a local article page with a user
  script that posts a message when its image is tapped, and an image from
  an `example-image:` scheme the guest answers from its bundle.

## Questions for review

1. Message bodies as JSON text, rather than a structured value a guest
   walks through the contract.
2. Messages from every frame and every page a `WebContent` shows, with
   `navigationDecider` as the guard, rather than only from pages the app
   loaded itself.
3. Scheme handlers fixed in the configuration, or also
   `registerURLScheme` on a page that's already made.
4. Registering every scheme as secure and CORS-enabled, or letting the app
   choose.
5. ~~Does a scheme registered after WPE's first web process starts load,
   and do its security settings take effect?~~ Yes, on WPE 2.48.3: a page
   that has loaded registers a scheme, and its images load in an `https`
   page (`registersAfterThePageHasLoaded`). Scheme handlers can still be
   fixed in the configuration for the other hosts' sake (question 3).
6. A guest that uses version 2 on a host with only version 1: refused at
   launch by the runner's contract check, or told when it makes the page,
   so it can fall back to `evaluateJavaScript`.
7. Whether `WPEWebKit` keeps its own copy of AppRuntime's web types, or
   depends on AppRuntime's `RuntimeABI` for them.
