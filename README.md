# WebKit

Swift library for WebKit: web pages in [WPE WebKit](https://wpewebkit.org),
WebKit's port for embedding, shown by
[Cacao](https://github.com/PureSwift/Cacao).

| Product | What it is |
| --- | --- |
| `CacaoWebKit` | `WebView` and `WebPage` for Cacao's SwiftUI |
| `WPEWebKit` | The engine under them: a page that draws into an external surface, for any host |
| `WebDemo` | A small browser window |

The names and shapes follow
[AppRuntime](https://github.com/PureSwift/AppRuntime)'s web views, so code
written for one reads the same against the other: `WebPage`, `WebView`,
`WebNavigation` and `WebError` in `CacaoWebKit` are its `DynamicWebKit` types,
and `WPEWebContent` with its delegate is its `WebContent` contract.

## CacaoWebKit

```swift
import CacaoSDL
import CacaoWebKit

struct Browser: View {

    @State private var page = WebPage()

    var body: some View {
        VStack {
            Text(page.title)
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
            }
            WebView(page)
        }
        .onAppear { page.load("https://swift.org") }
    }
}
```

`WebPage` is observable: `url`, `title`, `isLoading`, `estimatedProgress`,
`canGoBack`, `canGoForward` and `error`. It loads URLs, markup and bundle
resources, moves through its history, asks `navigationDecider` before each
navigation, and evaluates scripts with their values as JSON text.
`WebView(url:)` shows a URL without a page of the app's own.

A page is made with a configuration: scripts it runs in every document,
and URL schemes its app answers. Its message handlers can be added at any
time, and take effect from its next load:

```swift
var configuration = WebPage.Configuration()
configuration.userScripts = [WebUserScript(source: articleScript, injectionTime: .atDocumentStart)]
configuration.urlSchemeHandlers["app-icon"] = { request, respond in
    respond(.success(WebURLSchemeResponse(contentType: "image/png", body: icons[request.path] ?? [])))
}
let page = WebPage(configuration: configuration)

page.addMessageHandler(named: "imageWasClicked") { body in
    showImage(json: body)
}
page.addMessageHandler(named: "settings") { body async throws(WebError) -> String? in
    #"{"fontSize":17}"#
}
```

A one-way handler hears each message as JSON text. One with a
`replyHandler` returns JSON text that the page's `postMessage` promise
resolves to, nil for `undefined`, or throws to reject it.

The view takes pointer, wheel, touch, key and text input once it is clicked.
The engine's loop runs inside Cacao's: nothing polls, and the host's loop
wakes when a page has work.

## WPEWebKit

```swift
import WPEWebKit

final class Delegate: WPEWebContentDelegate {
    func didChangeTitle(_ content: WPEWebContent, title: String) { print(title) }
    // ...
}

guard let content = WPEWebContent(delegate: Delegate()) else {
    fatalError("WPE WebKit isn't installed")
}
content.attach(width: 800, height: 600, scale: 2)
content.load("https://swift.org")

// From the host's loop, each time it wakes:
WPEEngine.pump()
```

A page gives its host:

- **Frames**, published to `content.surface` while it is attached, for Cacao's
  `ExternalSurfaceView` or any compositor that takes an `ExternalSurface`.
- **The contract**: loading, history, navigation questions and script results
  through `WPEWebContentDelegate`, numbered as AppRuntime numbers them.
- **More than the contract**: async script calls, user scripts, script message
  handlers and their replies, URL schemes the host answers, the user agent,
  and navigation answers that come later.
- **Input**: pointer, smooth scrolling, keys and typed text.

A host answers URLs in schemes of its own, for images, pages or `fetch`:

```swift
content.registerURLScheme("app-icon")
content.onURLSchemeRequest = { task in
    guard let png = icons[task.path] else {
        return task.fail(.badURL, message: "no icon at \(task.path)")
    }
    task.finish(contentType: "image/png", body: png)
}
content.loadHTML("<img src='app-icon:/feed.png'>", baseURL: "https://example.com/")
```

A task is answered once, at once or later; one let go unanswered fails.
Schemes are secure and CORS-enabled, so an `https` page shows their images
and `fetch` reaches them, and they load while the network isn't allowed.
WebKit registers a scheme for every page in the process, so a request from
a page that didn't register it fails.

A page awaits a reply from a handler that replies:

```swift
content.addScriptMessageHandler("settings", replies: true)
content.onScriptMessageWithReply = { name, body, reply in
    reply.returnValue(json: #"{"fontSize":17}"#)
}
// In the page:
// const settings = await window.webkit.messageHandlers.settings.postMessage(null);
```

The reply's JSON is the value the page's promise resolves to; nil resolves
it to `undefined`, and `returnError` rejects it. A reply is given once, at
once or later; one let go, or still owed when its page goes, rejects.

`WPEEngine.onReady` is called from another thread when the pages have work,
so a host sleeps until then. `WPEEngine.isNetworkAllowed` turns the network
off for every page.

WPE WebKit is opened at run time, so nothing links against it and a program
still runs where it isn't installed: `WPEEngine.isAvailable` says whether it
is. It needs these libraries:

| Library | Debian package |
| --- | --- |
| `libWPEWebKit-2.0.so.1` | `libwpewebkit-2.0-1` |
| `libWPEBackend-fdo-1.0.so.1` | `libwpebackend-fdo-1.0-1` |
| `libwpe-1.0.so.1` | `libwpe-1.0-1` |

GLib, GIO and libsoup 3, which it also opens, come with WPE WebKit.

Frames come in shared memory, without GL. WebKit's main thread is the first
thread that calls it, and the engine and its pages are for that thread alone.

## Testing

```bash
swift test
```

The page tests run real pages, without a display or the network, and are
skipped where WPE WebKit isn't installed.
