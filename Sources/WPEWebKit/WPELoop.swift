import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

// GLib's main context inside a host's own loop, without polling it.
//
// The host's thread runs the context, and then asks GLib what it is waiting
// for: file descriptors and a timeout. A second thread waits on those and
// tells the host when one is ready, and the host runs the context again.

extension WPEEngine {

    /// Called, on another thread, when the pages have work for
    /// `pump`: a host wakes its loop here.
    public static var onReady: (@Sendable () -> Void)? {
        get { LoopWatcher.shared.onReady }
        set { LoopWatcher.shared.onReady = newValue }
    }

    /// Runs what the pages have ready, as `dispatch` does, then watches for
    /// more, which `onReady` announces. A host calls this each time its loop
    /// wakes, and once after it makes a page.
    public static func pump() {
        guard let library = WPELibrary.shared else { return }
        dispatch()
        guard pageCount > 0 else {
            return LoopWatcher.shared.stop()
        }
        if !LoopWatcher.shared.ownsContext {
            // The context is this thread's from here on.
            LoopWatcher.shared.ownsContext = library.mainContextAcquire(nil) != 0
        }
        var priority: Int32 = 0
        _ = library.mainContextPrepare(nil, &priority)
        var timeout: Int32 = -1
        var descriptors = [pollfd](repeating: pollfd(), count: 16)
        while true {
            // A GPollFD is a pollfd.
            let capacity = Int32(descriptors.count)
            let count = Int(descriptors.withUnsafeMutableBytes {
                library.mainContextQuery(nil, priority, &timeout, $0.baseAddress, capacity)
            })
            if count <= descriptors.count {
                descriptors.removeLast(descriptors.count - count)
                break
            }
            descriptors = [pollfd](repeating: pollfd(), count: count)
        }
        LoopWatcher.shared.watch(descriptors, timeout: timeout)
    }
}

/// The thread that waits on what GLib is waiting for.
final class LoopWatcher: @unchecked Sendable {

    static let shared = LoopWatcher()

    /// Whether the host's thread has acquired GLib's context. The host's
    /// thread alone reads and writes this.
    var ownsContext = false

    private let condition = NSCondition()
    private var handler: (@Sendable () -> Void)?
    private var descriptors: [pollfd] = []
    private var timeout: Int32 = -1
    /// Counts what the host has asked for, so the thread can tell a new
    /// request from the one it has.
    private var request = 0
    private var isWatching = false
    private var isRunning = false
    /// Written to, to end the wait in progress.
    private var interrupt: (read: Int32, write: Int32) = (-1, -1)

    var onReady: (@Sendable () -> Void)? {
        get { condition.withLock { handler } }
        set { condition.withLock { handler = newValue } }
    }

    /// Waits on these, in place of what was being waited on.
    func watch(_ descriptors: [pollfd], timeout: Int32) {
        condition.lock()
        if !isRunning {
            isRunning = true
            var ends: [Int32] = [-1, -1]
            if pipe(&ends) == 0 {
                for end in ends {
                    _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
                    _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                }
                interrupt = (ends[0], ends[1])
            }
            let thread = Thread { [unowned self] in self.run() }
            thread.name = "WPEWebKit loop"
            thread.start()
        }
        self.descriptors = descriptors
        self.timeout = timeout
        request &+= 1
        isWatching = true
        condition.signal()
        condition.unlock()
        wake()
    }

    /// Waits on nothing, until asked again.
    func stop() {
        condition.lock()
        let wasWatching = isWatching
        isWatching = false
        request &+= 1
        condition.unlock()
        if wasWatching {
            wake()
        }
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = write(interrupt.write, &byte, 1)
    }

    private func run() {
        while true {
            condition.lock()
            while !isWatching {
                condition.wait()
            }
            let request = self.request
            var descriptors = self.descriptors
            let timeout = self.timeout
            condition.unlock()

            descriptors.append(pollfd(fd: interrupt.read, events: Int16(POLLIN), revents: 0))
            let ready = poll(&descriptors, nfds_t(descriptors.count), timeout)
            if ready > 0, descriptors[descriptors.count - 1].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                while read(interrupt.read, &bytes, bytes.count) > 0 {}
            }

            condition.lock()
            guard request == self.request else {
                // Asked for something else meanwhile.
                condition.unlock()
                continue
            }
            let interruptedOnly = ready == 1 && descriptors[descriptors.count - 1].revents != 0
            if interruptedOnly || (ready < 0 && errno == EINTR) {
                condition.unlock()
                continue
            }
            // Ready, or timed out: the host's turn, until it asks again.
            isWatching = false
            let handler = self.handler
            condition.unlock()
            handler?()
        }
    }
}
