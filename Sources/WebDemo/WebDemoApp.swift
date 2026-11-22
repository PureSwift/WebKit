import CacaoSDL
import CacaoWebKit
import Foundation

/// A small browser: a page, its title and progress, and the buttons that
/// move through its history. `WEBDEMO_URL` names a page to open in place of
/// the one built in.
@main
struct WebDemoApp: App {

    var body: some Scene {
        WindowGroup("Web") {
            BrowserView()
        }
        .defaultSize(width: 900, height: 640)
    }
}

struct BrowserView: View {

    @State private var page = WebPage()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back") { page.goBack() }
                    .disabled(!page.canGoBack)
                Button("Forward") { page.goForward() }
                    .disabled(!page.canGoForward)
                Button(page.isLoading ? "Stop" : "Reload") {
                    page.isLoading ? page.stopLoading() : page.reload()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title.isEmpty ? "Untitled" : page.title)
                        .font(.headline)
                    Text(page.error?.message ?? page.url ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if page.isLoading {
                    ProgressView(value: page.estimatedProgress)
                        .frame(width: 120)
                }
            }
            .padding(10)
            Divider()
            WebView(page)
        }
        .onAppear {
            if let url = ProcessInfo.processInfo.environment["WEBDEMO_URL"] {
                page.load(url)
            } else {
                page.load(html: Self.welcome)
            }
        }
    }

    static let welcome = """
        <!doctype html>
        <title>Cacao WebKit</title>
        <style>
        body { font: 18px sans-serif; margin: 40px; color: #222; background: #f4f1ea; }
        h1 { color: #7b3f00; }
        input { font: inherit; padding: 6px; width: 260px; }
        .tall { height: 1600px; border-left: 4px solid #7b3f00; padding-left: 12px; margin-top: 24px; }
        </style>
        <h1>WPE WebKit in a Cacao view</h1>
        <p>This page is drawn by WebKit's web process into shared memory, and shown by Cacao's compositor.</p>
        <p><input id="field" placeholder="Click and type here"></p>
        <p><button onclick="document.title = 'Clicked ' + (++window.count)">Count clicks in the title</button></p>
        <script>window.count = 0;</script>
        <div class="tall">Scroll down: this column is 1600 points tall.</div>
        """
}
