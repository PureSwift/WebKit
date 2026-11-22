import Foundation
import Testing
import WPEWebKit

@MainActor
@Suite(.enabled(if: WPEEngine.isAvailable, "WPE WebKit isn't installed"))
struct WPELoopTests {

    /// A host that sleeps until the engine wakes it still gets a page
    /// loaded and its scripts answered.
    @Test func wakesAHostThatSleeps() throws {
        let woken = DispatchSemaphore(value: 0)
        let previous = WPEEngine.onReady
        WPEEngine.onReady = { woken.signal() }
        defer { WPEEngine.onReady = previous }

        let page = try Page()
        var answer: Result<String?, WPEError>?
        var wakes = 0
        func sleepUntil(_ what: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            WPEEngine.pump()
            while !condition() {
                guard Date() < deadline else { throw TimedOut(waitingFor: what) }
                // No polling: only a wake from the engine moves this on.
                if woken.wait(timeout: .now() + 5) == .success {
                    wakes += 1
                }
                WPEEngine.pump()
            }
        }
        page.content.loadHTML("<title>Loop</title><p>Text</p>", baseURL: nil)
        try sleepUntil("the load") { page.delegate.finishes == 1 }
        page.content.callAsyncJavaScript("return await new Promise(resolve => setTimeout(() => resolve(document.title), 50))") {
            answer = $0
        }
        try sleepUntil("the script") { answer != nil }
        #expect(try answer?.get() == #""Loop""#)
        #expect(wakes > 0)
    }
}
