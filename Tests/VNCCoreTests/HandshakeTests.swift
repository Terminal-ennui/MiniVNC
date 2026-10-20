import Foundation
import Testing
@testable import VNCCore

struct HandshakeTests {
    @Test func noneAuthOn38() async throws {
        let t = ScriptedTransport(
            version("003.008") + Data([1, 1]) + u32(0) + serverInit(width: 1024, height: 768, name: "box:1")
        )
        let result = try await Handshake.run(on: t, password: { Issue.record("no password expected"); return nil })
        #expect(result == ServerInit(width: 1024, height: 768, pixelFormat: .bgrx32, name: "box:1"))
        #expect(t.sent == [version("003.008"), Data([1]), Data([1])] as [Data])
        #expect(t.unreadCount == 0)
    }

    @Test func vncAuthSuccessOn38() async throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let t = ScriptedTransport(
            version("003.008") + Data([2, 16, 2]) + challenge + u32(0) + serverInit(width: 800, height: 600, name: "x")
        )
        let result = try await Handshake.run(on: t, password: { "secret" })
        #expect(result.width == 800)
        #expect(t.sent == [
            version("003.008"), Data([2]),
            VNCAuth.response(challenge: challenge, password: "secret"), Data([1]),
        ] as [Data])
    }

    @Test func vncAuthFailureReportsReason() async throws {
        let t = ScriptedTransport(
            version("003.008") + Data([1, 2]) + Data(count: 16) + u32(1) + string("Authentication failure")
        )
        await #expect(throws: HandshakeError.authenticationFailed("Authentication failure")) {
            try await Handshake.run(on: t, password: { "wrong" })
        }
    }

    @Test func passwordCancelled() async throws {
        let t = ScriptedTransport(version("003.008") + Data([1, 2]) + Data(count: 16))
        await #expect(throws: HandshakeError.cancelled) {
            try await Handshake.run(on: t, password: { nil })
        }
    }

    @Test func prefersNoneWhenBothOffered() async throws {
        let t = ScriptedTransport(version("003.008") + Data([2, 2, 1]) + u32(0) + serverInit(width: 10, height: 10, name: ""))
        _ = try await Handshake.run(on: t, password: { Issue.record("no password expected"); return nil })
        #expect(t.sent[1] == Data([1]))
    }

    @Test func vncAuthOn33() async throws {
        let challenge = Data(repeating: 7, count: 16)
        let t = ScriptedTransport(version("003.003") + u32(2) + challenge + u32(0) + serverInit(width: 640, height: 480, name: "old"))
        let result = try await Handshake.run(on: t, password: { "pw" })
        #expect(result.name == "old")
        #expect(t.sent == [version("003.003"), VNCAuth.response(challenge: challenge, password: "pw"), Data([1])] as [Data])
    }

    @Test func failureWithoutReasonOn33() async throws {
        let t = ScriptedTransport(version("003.003") + u32(2) + Data(count: 16) + u32(1))
        await #expect(throws: HandshakeError.authenticationFailed("Authentication failed")) {
            try await Handshake.run(on: t, password: { "pw" })
        }
    }

    @Test func noneOn37SkipsSecurityResult() async throws {
        let t = ScriptedTransport(version("003.007") + Data([1, 1]) + serverInit(width: 1, height: 1, name: "seven"))
        let result = try await Handshake.run(on: t, password: { nil })
        #expect(result.name == "seven")
        #expect(t.sent.first == version("003.007"))
    }

    @Test func newerMinorVersionsNegotiate38() async throws {
        let t = ScriptedTransport(version("003.889") + Data([1, 1]) + u32(0) + serverInit(width: 1, height: 1, name: ""))
        _ = try await Handshake.run(on: t, password: { nil })
        #expect(t.sent.first == version("003.008"))
    }

    @Test func serverRefusal() async throws {
        let t = ScriptedTransport(version("003.008") + Data([0]) + string("Too many security failures"))
        await #expect(throws: HandshakeError.serverRefused("Too many security failures")) {
            try await Handshake.run(on: t, password: { nil })
        }
    }

    @Test func unsupportedSecurityTypes() async throws {
        let t = ScriptedTransport(version("003.008") + Data([2, 19, 30]))
        await #expect(throws: HandshakeError.noSupportedSecurity([19, 30])) {
            try await Handshake.run(on: t, password: { nil })
        }
    }

    @Test func timesOutWhenServerSendsNothing() async throws {
        let t = ScriptedTransport()
        await #expect(throws: HandshakeError.timedOut) {
            try await Handshake.run(on: t, password: { nil }, timeout: .milliseconds(50))
        }
    }

    @Test func passwordPromptIsNotSubjectToTimeout() async throws {
        let t = ScriptedTransport(
            version("003.008") + Data([1, 2]) + Data(count: 16) + u32(0) + serverInit(width: 1, height: 1, name: "")
        )
        _ = try await Handshake.run(on: t, password: {
            try? await Task.sleep(for: .milliseconds(150))
            return "pw"
        }, timeout: .milliseconds(50))
    }

    @Test func missingFailureReasonAtEndOfStream() async throws {
        let t = ScriptedTransport(version("003.008") + Data([1, 2]) + Data(count: 16) + u32(1))
        t.finish()
        await #expect(throws: HandshakeError.authenticationFailed("Authentication failed")) {
            try await Handshake.run(on: t, password: { "pw" })
        }
    }

    @Test func vncAuthOn37() async throws {
        let challenge = Data(repeating: 3, count: 16)
        let t = ScriptedTransport(version("003.007") + Data([1, 2]) + challenge + u32(0) + serverInit(width: 1, height: 1, name: ""))
        _ = try await Handshake.run(on: t, password: { "pw" })
        #expect(t.sent == [version("003.007"), Data([2]), VNCAuth.response(challenge: challenge, password: "pw"), Data([1])] as [Data])
    }

    @Test func failureOn37HasNoReason() async throws {
        let t = ScriptedTransport(version("003.007") + Data([1, 2]) + Data(count: 16) + u32(1))
        await #expect(throws: HandshakeError.authenticationFailed("Authentication failed")) {
            try await Handshake.run(on: t, password: { "pw" })
        }
    }

    @Test func refusalOn37() async throws {
        let t = ScriptedTransport(version("003.007") + Data([0]) + string("nope"))
        await #expect(throws: HandshakeError.serverRefused("nope")) {
            try await Handshake.run(on: t, password: { nil })
        }
    }

    @Test(arguments: ["003.004", "003.005", "003.006"])
    func oddMinorVersionsFallBackTo33(_ v: String) async throws {
        let t = ScriptedTransport(version(v) + u32(1) + serverInit(width: 1, height: 1, name: ""))
        _ = try await Handshake.run(on: t, password: { nil })
        #expect(t.sent.first == version("003.003"))
    }

    @Test func rejectsOtherMajorVersions() async throws {
        let t = ScriptedTransport(version("004.001"))
        await #expect(throws: HandshakeError.unsupportedVersion("RFB 004.001")) {
            try await Handshake.run(on: t, password: { nil })
        }
    }

    @Test func rejectsNonRFBGreeting() async throws {
        let t = ScriptedTransport(Data("HTTP/1.1 400".utf8))
        await #expect(throws: HandshakeError.unsupportedVersion("HTTP/1.1 400")) {
            try await Handshake.run(on: t, password: { nil })
        }
    }
}

private func version(_ v: String) -> Data { Data("RFB \(v)\n".utf8) }

private func u32(_ v: UInt32) -> Data {
    var w = ByteWriter()
    w.u32(v)
    return w.data
}

private func string(_ s: String) -> Data { u32(UInt32(s.utf8.count)) + Data(s.utf8) }

private func serverInit(width: UInt16, height: UInt16, name: String) -> Data {
    var w = ByteWriter()
    w.u16(width)
    w.u16(height)
    PixelFormat.bgrx32.encode(into: &w)
    return w.data + string(name)
}
