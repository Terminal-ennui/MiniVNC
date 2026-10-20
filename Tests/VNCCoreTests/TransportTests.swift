import Foundation
import Network
import Testing
@testable import VNCCore

/// Serialized: these tests open real loopback ports, and one checks that a just-closed port refuses connections.
@Suite(.serialized)
struct NWTransportTests {
    @Test func readsExactCountsAcrossChunksAndSends() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let transport = NWTransport(host: "127.0.0.1", port: port)
        try await transport.open()
        let peer = await server.accept()

        try await peer.send(Data([1, 2, 3]))
        try await peer.send(Data([4, 5]))
        #expect(try await transport.read(exactly: 2) == Data([1, 2]))
        #expect(try await transport.read(exactly: 3) == Data([3, 4, 5]))

        transport.send(Data([9, 8]))
        transport.send(Data([7]))
        #expect(try await peer.receive(3) == Data([9, 8, 7]))

        peer.close()
        await #expect(throws: TransportError.closed) { try await transport.read(exactly: 1) }
        transport.close()
        server.stop()
    }

    @Test func readsLargePayload() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let transport = NWTransport(host: "127.0.0.1", port: port)
        try await transport.open()
        let peer = await server.accept()

        let payload = Data((0..<500_000).map { UInt8($0 & 0xFF) })
        try await peer.send(payload)
        #expect(try await transport.read(exactly: payload.count) == payload)
        transport.close()
        peer.close()
        server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionRunsOverRealSocket() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let session = RFBSession(transport: NWTransport(host: "127.0.0.1", port: port))
        var events = session.events.makeAsyncIterator()
        var frames = session.frames.makeAsyncIterator()
        Task { await session.run(password: { "pw" }) }
        let peer = await server.accept()

        try await peer.send(Data("RFB 003.008\n".utf8) + Data([1, 2]) + Data(count: 16))
        #expect(try await peer.receive(12) == Data("RFB 003.008\n".utf8))
        #expect(try await peer.receive(1) == Data([2]))
        #expect(try await peer.receive(16) == VNCAuth.response(challenge: Data(count: 16), password: "pw"))

        var serverInit = ByteWriter()
        serverInit.u32(0) // SecurityResult OK
        serverInit.u16(2)
        serverInit.u16(1)
        PixelFormat.bgrx32.encode(into: &serverInit)
        serverInit.u32(4)
        serverInit.bytes(Data("test".utf8))
        try await peer.send(serverInit.data)
        #expect(try await peer.receive(1) == Data([1]))
        guard case .connected(let info) = await events.next() else { Issue.record("expected connect"); return }
        #expect(info.name == "test")

        var update = ByteWriter()
        update.u8(0)
        update.padding(1)
        update.u16(1)
        for v: UInt16 in [0, 0, 2, 1] { update.u16(v) }
        update.s32(EncodingType.raw)
        update.bytes(Data([0xFF, 0, 0, 0, 0, 0xFF, 0, 0]))
        try await peer.send(update.data)
        let frame = try #require(await frames.next())
        #expect(frame.width == 2 && frame.height == 1)
        guard case .desktopResizeSupport(false) = await events.next() else { Issue.record("expected no resize support"); return }

        peer.close()
        guard case .disconnected = await events.next() else { Issue.record("expected disconnect"); return }
        server.stop()
    }

    @Test func closeBeforeOpenFailsFast() async {
        let transport = NWTransport(host: "127.0.0.1", port: 9)
        transport.close()
        await #expect(throws: TransportError.closed) { try await transport.open() }
    }

    @Test func closeUnblocksPendingRead() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let transport = NWTransport(host: "127.0.0.1", port: port)
        try await transport.open()
        let peer = await server.accept()
        let pending = Task { try await transport.read(exactly: 1) }
        try await Task.sleep(for: .milliseconds(50))
        transport.close()
        await #expect(throws: (any Error).self) { try await pending.value }
        peer.close()
        server.stop()
    }

    @Test func manySmallReadsFromOneChunk() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let transport = NWTransport(host: "127.0.0.1", port: port)
        try await transport.open()
        let peer = await server.accept()
        let payload = Data((0..<60_000).map { UInt8($0 % 251) })
        try await peer.send(payload)
        var received = Data()
        while received.count < payload.count { received += try await transport.read(exactly: 12) }
        #expect(received == payload)
        transport.close()
        peer.close()
        server.stop()
    }

    @Test func openFailsWhenNothingListens() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        await server.stopAndWait()
        let transport = NWTransport(host: "127.0.0.1", port: port)
        await #expect(throws: (any Error).self) { try await transport.open() }
    }
}

struct ScriptedTransportTests {
    @Test func deliversFedBytesAndRecordsSends() async throws {
        let t = ScriptedTransport(Data([1, 2]))
        #expect(try await t.read(exactly: 1) == Data([1]))
        async let pending = t.read(exactly: 3)
        t.feed(Data([3, 4]))
        #expect(try await pending == Data([2, 3, 4]))
        t.send(Data([0xAA]))
        #expect(t.sent == [Data([0xAA])])
        t.finish()
        await #expect(throws: TransportError.closed) { try await t.read(exactly: 1) }
    }
}

/// Loopback-only TCP server for exercising NWTransport.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let connections = AsyncStream<NWConnection>.makeStream()
    private var iterator: AsyncStream<NWConnection>.Iterator

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        iterator = connections.stream.makeAsyncIterator()
    }

    func start() async throws -> UInt16 {
        let continuation = connections.continuation
        listener.newConnectionHandler = { continuation.yield($0) }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    cont.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func accept() async -> Peer {
        let connection = await iterator.next()!
        connection.start(queue: queue)
        return Peer(connection: connection)
    }

    func stop() { listener.cancel() }

    /// Cancels and waits until the port is actually closed.
    func stopAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { [listener] state in
                guard case .cancelled = state else { return }
                listener.stateUpdateHandler = nil
                cont.resume()
            }
            listener.cancel()
        }
    }

    struct Peer {
        let connection: NWConnection

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }

        func receive(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
                }
            }
        }

        func close() { connection.cancel() }
    }
}
