import Foundation
import Synchronization
@testable import VNCCore

/// In-memory server end for protocol tests: `feed` bytes the server sends, inspect what the client `sent`.
final class ScriptedTransport: Transport {
    private struct State {
        var inbox = Data()
        var finished = false
        var sent: [Data] = []
        var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?

        mutating func take(_ count: Int) -> Data {
            let chunk = Data(inbox.prefix(count))
            inbox.removeFirst(count)
            return chunk
        }

        mutating func serviceWaiter() {
            guard let (count, continuation) = waiter else { return }
            if inbox.count >= count {
                waiter = nil
                continuation.resume(returning: take(count))
            } else if finished {
                waiter = nil
                continuation.resume(throwing: TransportError.closed)
            }
        }
    }

    private let state = Mutex(State())

    init(_ initial: Data = Data()) {
        feed(initial)
    }

    func feed(_ data: Data) {
        state.withLock {
            $0.inbox.append(data)
            $0.serviceWaiter()
        }
    }

    func finish() {
        state.withLock {
            $0.finished = true
            $0.serviceWaiter()
        }
    }

    var sent: [Data] { state.withLock { $0.sent } }
    var sentBytes: Data { sent.reduce(Data(), +) }
    var unreadCount: Int { state.withLock { $0.inbox.count } }

    func open() async throws {}

    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.waiter = (count, continuation)
                $0.serviceWaiter()
            }
        }
    }

    func send(_ data: Data) {
        state.withLock { $0.sent.append(data) }
    }

    func close() {
        finish()
    }
}
