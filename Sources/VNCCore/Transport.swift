import Foundation
import Network
import Synchronization

public enum TransportError: Error, Equatable {
    case closed
    case localNetworkDenied
}

/// Byte stream to a VNC server. Reads come from a single consumer; `send` may be called from any thread and preserves call order.
public protocol Transport: AnyObject, Sendable {
    func open() async throws
    func read(exactly count: Int) async throws -> Data
    func send(_ data: Data)
    func close()
}

public final class NWTransport: Transport, @unchecked Sendable {
    private let connection: NWConnection
    private let endpoint: String
    private let onLocalNetworkWait: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "MiniVNC.NWTransport")
    private let isClosed = Atomic<Bool>(false)
    // Only touched by the single reader inside read(exactly:). Bytes before `head` are already consumed.
    private var buffer = Data()
    private var head = 0

    /// `onLocalNetworkWait` is called once if macOS holds the connection for Local Network permission.
    public init(host: String, port: UInt16, onLocalNetworkWait: (@Sendable () -> Void)? = nil) {
        endpoint = "\(host):\(port)"
        self.onLocalNetworkWait = onLocalNetworkWait
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    /// Resolves once the TCP connection is ready; throws if it fails or has no route (`.waiting`).
    /// Local Network denial gets a grace period, since macOS may still be asking the user.
    public func open() async throws {
        guard !isClosed.load(ordering: .acquiring) else { throw TransportError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let attempt = OpenAttempt(cont)
            Log.transport.notice("\(self.endpoint, privacy: .public): connecting")
            connection.stateUpdateHandler = { [connection, queue, endpoint, onLocalNetworkWait] state in
                switch state {
                case .ready:
                    Log.transport.notice("\(endpoint, privacy: .public): TCP ready")
                    attempt.finish(nil)
                case .waiting where connection.currentPath?.unsatisfiedReason == .localNetworkDenied:
                    Log.transport.error("\(endpoint, privacy: .public): waiting — Local Network access denied or not yet granted")
                    if attempt.startDeadline(on: queue, after: .seconds(30), expire: {
                        Log.transport.error("\(endpoint, privacy: .public): gave up waiting for Local Network access")
                        connection.cancel()
                        attempt.finish(TransportError.localNetworkDenied)
                    }) { onLocalNetworkWait?() }
                case .waiting(let error), .failed(let error):
                    Log.transport.error("\(endpoint, privacy: .public): \(String(describing: state), privacy: .public) \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                    attempt.finish(error)
                case .cancelled:
                    attempt.finish(TransportError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            // close() may have landed between the guard above and start.
            if isClosed.load(ordering: .acquiring) { connection.cancel() }
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        while buffer.count - head < count {
            if head > 0 {
                buffer = Data(buffer[(buffer.startIndex + head)...])
                head = 0
            }
            buffer.append(try await receive(maximum: max(65_536, count - buffer.count)))
        }
        let start = buffer.startIndex + head
        head += count
        return Data(buffer[start..<start + count])
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func close() {
        isClosed.store(true, ordering: .releasing)
        connection.cancel()
    }

    private func receive(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: TransportError.closed)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }
}

/// Resumes an `open()` continuation exactly once. Only touched on the connection's queue.
private final class OpenAttempt: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var hasDeadline = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// Returns true the first time, when the deadline is actually scheduled.
    @discardableResult
    func startDeadline(on queue: DispatchQueue, after delay: DispatchTimeInterval, expire: @escaping @Sendable () -> Void) -> Bool {
        guard !hasDeadline else { return false }
        hasDeadline = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.continuation != nil { expire() }
        }
        return true
    }
}
