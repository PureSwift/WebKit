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
public struct WebView: View {

    let page: WebPage?

    let url: String?

    /// The page of a view made from a URL, kept across updates.
    @State private var owned = OwnedPage()

    @Environment(\.displayScale) private var displayScale

    public init(_ page: WebPage) {
        self.page = page
        self.url = nil
    }

    public init(url: String?) {
        self.page = nil
        self.url = url
    }

    public var body: some View {
        let page = shown
        if let content = page.content {
            GeometryReader { proxy in
                ExternalSurfaceView(content.surface, scale: displayScale)
                    .onInput(acceptsText: true) { input in
                        page.input.handle(input, for: content)
                        WebLoop.pump()
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onAppear {
                        page.show(size: proxy.size, scale: displayScale)
                    }
                    .onChange(of: proxy.size) { size in
                        page.show(size: size, scale: displayScale)
                    }
                    .onChange(of: displayScale) { scale in
                        page.show(size: proxy.size, scale: scale)
                    }
                    .onDisappear {
                        page.hide()
                    }
            }
        } else {
            Text("WPE WebKit isn't installed")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shown: WebPage {
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
