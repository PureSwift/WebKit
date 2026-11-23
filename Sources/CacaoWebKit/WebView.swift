import Cacao
import Foundation
import WPEWebKit

/// Shows web content. It takes the space it's offered, and clicking it
/// gives it keyboard focus.
///
/// For a page the app follows or controls, make a `WebPage` and show it:
///
/// ```swift
/// WebView(page)
/// ```
///
/// To only show a URL, give that; the view keeps a page of its own, and
/// loads again when the URL it's given changes:
///
/// ```swift
/// WebView(url: "https://swift.org")
/// ```
///
/// A host that makes the engine's pages itself, as AppRuntime's Linux host
/// makes them for its apps, shows one with `WebView(content:)`.
public struct WebView: View {

    let page: WebPage?

    let url: String?

    let content: WPEWebContent?

    /// The page of a view made from a URL, kept across updates.
    @State private var owned = OwnedPage()

    /// The input of a view made from an engine's page, kept across updates.
    @State private var input = WebInput()

    @Environment(\.displayScale) private var displayScale

    public init(_ page: WebPage) {
        self.page = page
        self.url = nil
        self.content = nil
    }

    public init(url: String?) {
        self.page = nil
        self.url = url
        self.content = nil
    }

    /// Shows an engine's page made elsewhere: its frames, with the view's
    /// input going to it. What the page loads, and what it tells its
    /// delegate, are for whoever made it; the view only attaches it while
    /// it's on screen.
    ///
    /// The engine's loop runs from Cacao's, unless a host already set
    /// `WPEEngine.onReady` to run it from its own.
    public init(content: WPEWebContent) {
        self.page = nil
        self.url = nil
        self.content = content
    }

    public var body: some View {
        if let content {
            surface(content, input: input,
                    show: { size, scale in
                        WebLoop.start()
                        WebPage.show(content, size: size, scale: scale)
                    },
                    hide: { [input] in
                        input.reset()
                        content.detach()
                        WebLoop.pump()
                    })
        } else if let page = shown, let content = page.content {
            surface(content, input: page.input, show: page.show(size:scale:), hide: page.hide)
        } else {
            Text("WPE WebKit isn't installed")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A page's frames at the size offered, attached while on screen.
    private func surface(_ content: WPEWebContent, input: WebInput,
                         show: @escaping @MainActor (CGSize, CGFloat) -> Void,
                         hide: @escaping @MainActor () -> Void) -> some View {
        GeometryReader { proxy in
            ExternalSurfaceView(content.surface, scale: displayScale)
                .onInput(acceptsText: true) { event in
                    input.handle(event, for: content)
                    WebLoop.pump()
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear {
                    show(proxy.size, displayScale)
                }
                .onChange(of: proxy.size) { _, size in
                    show(size, displayScale)
                }
                .onChange(of: displayScale) { _, scale in
                    show(proxy.size, scale)
                }
                .onDisappear {
                    hide()
                }
        }
    }

    private var shown: WebPage? {
        if let page {
            return page
        }
        owned.show(url)
        return owned.page
    }
}

/// A `WebView(url:)`'s own page, and the URL it last asked it for.
@MainActor
final class OwnedPage {

    let page = WebPage()

    private var requested: String?

    func show(_ url: String?) {
        guard url != requested else { return }
        requested = url
        if let url {
            page.load(url)
        }
    }
}
