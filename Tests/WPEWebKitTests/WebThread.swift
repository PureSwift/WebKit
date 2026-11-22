import Foundation
import WPEWebKit

/// WebKit's main thread is the first that calls it, so every test does its
/// WebKit work on this one thread.
final class WebThread: @unchecked Sendable {

    static let shared = WebThread()

    private let condition = NSCondition()

    private var jobs: [() -> Void] = []

    private init() {
        let thread = Thread { [unowned self] in
            while true {
                condition.lock()
                while jobs.isEmpty {
                    condition.wait()
                }
                let job = jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// Runs `body` on the thread and waits for it.
    func run<Result>(_ body: @escaping () throws -> Result) throws -> Result {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Swift.Result<Result, Error>!
        condition.lock()
        jobs.append {
            outcome = Swift.Result { try body() }
            done.signal()
        }
        condition.signal()
        condition.unlock()
        done.wait()
        return try outcome.get()
    }

    /// Whether WPE WebKit is installed, asked on the thread.
    static let isAvailable: Bool = (try? shared.run { WPEEngine.isAvailable }) ?? false
}

struct TimedOut: Error, CustomStringConvertible {
    var waitingFor: String
    var description: String { "timed out waiting for \(waitingFor)" }
}

/// Runs the engine's loop until `condition` holds.
func wait(for what: String, seconds: Double = 20, until condition: () -> Bool) throws {
    guard WPEEngine.dispatch(for: seconds, until: condition) else {
        throw TimedOut(waitingFor: what)
    }
}

extension WPEPage {

    /// Loads markup and waits for the load to end.
    func loadAndWait(html: String) throws {
        var finished = false
        let previous = onLoadChanged
        onLoadChanged = { event in
            previous?(event)
            if event == .finished { finished = true }
        }
        load(html: html)
        try wait(for: "the load") { finished }
        onLoadChanged = previous
    }

    /// Runs a script and waits for its value as JSON.
    func evaluate(_ script: String) throws -> String? {
        var outcome: Result<String?, WPEError>?
        evaluateJavaScript(script) { outcome = $0 }
        try wait(for: "the script") { outcome != nil }
        return try outcome!.get()
    }
}
