# WebKit

Swift library for WebKit.

## WPEWebKit

Web pages in [WPE WebKit](https://wpewebkit.org), WebKit's port for
embedding, drawn into [Cacao](https://github.com/PureSwift/Cacao)'s external
surfaces. It is the engine under a web view: it has no view of its own.

```swift
import WPEWebKit

guard let page = WPEPage(width: 800, height: 600, scale: 2) else {
    fatalError("WPE WebKit isn't installed")
}
page.onLoadChanged = { event in
    if event == .finished { print(page.title ?? "") }
}
page.onNavigation = { navigation, decision in
    navigation.uri.hasPrefix("https://") ? decision.allow() : decision.cancel()
}
page.isVisible = true
page.load(uri: "https://swift.org")

// From the host's loop, while there are pages:
WPEEngine.dispatch()
```

A page gives its host:

- **Frames**, published to `page.surface` as the web process draws them, for
  Cacao's `ExternalSurfaceView` or any compositor that takes an
  `ExternalSurface`.
- **Loading**: URIs and markup, history, progress, failures, and a say in
  each navigation, now or later.
- **Scripts**: evaluation with results as JSON, async functions, user scripts
  and script message handlers.
- **Input**: pointer, smooth scrolling, keys and typed text.

WPE WebKit is opened at run time, so nothing links against it and a program
still runs where it isn't installed: `WPEEngine.isAvailable` says whether it
is, and `WPEPage.init` returns nil when it isn't. It needs these libraries:

| Library | Debian package |
| --- | --- |
| `libWPEWebKit-2.0.so.1` | `libwpewebkit-2.0-1` |
| `libWPEBackend-fdo-1.0.so.1` | `libwpebackend-fdo-1.0-1` |
| `libwpe-1.0.so.1` | `libwpe-1.0-1` |

Frames come in shared memory, without GL. WebKit's main thread is the first
thread that calls it, and the engine and its pages are for that thread alone.

## Testing

```bash
swift test
```

The page tests run real pages, without a display or the network, and are
skipped where WPE WebKit isn't installed.
