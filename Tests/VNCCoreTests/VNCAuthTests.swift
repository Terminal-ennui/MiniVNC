import Foundation
import Testing
@testable import VNCCore

struct VNCAuthTests {
    private static let challenge = Data((0..<16).map { UInt8($0) })

    private static func hex(_ s: String) -> Data {
        var bytes = [UInt8]()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            bytes.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return Data(bytes)
    }

    // Key = "password", each byte bit-reversed. Vectors from (with LibreSSL's openssl, omit -provider):
    // printf '000102030405060708090a0b0c0d0e0f' | xxd -r -p \
    //   | openssl enc -des-ecb -nopad -K 0e86ceceeef64e26 -provider legacy -provider default | xxd -p
    @Test func matchesOpenSSLVector() {
        let r = VNCAuth.response(challenge: Self.challenge, password: "password")
        #expect(r == Self.hex("b866924125c8eebb9debc1db61c538e2"))
    }

    @Test func passwordLongerThanEightCharsUsesFirstEight() {
        #expect(VNCAuth.response(challenge: Self.challenge, password: "password123")
            == VNCAuth.response(challenge: Self.challenge, password: "password"))
    }

    // -K 0000000000000000
    @Test func emptyPasswordUsesZeroKey() {
        let r = VNCAuth.response(challenge: Self.challenge, password: "")
        #expect(r == Self.hex("491e890de9ace932838a49792f2213f3"))
    }

    // "pässwörd" → first 8 UTF-8 bytes 70 c3 a4 73 73 77 c3 b6 → -K 0ec325ceceeec36d
    @Test func multiByteUTF8PasswordUsesFirstEightBytes() {
        #expect(VNCAuth.response(challenge: Self.challenge, password: "pässwörd")
            == Self.hex("7d13fc5643ca0c048e71796fe629ecf3"))
        // Truncation is by byte, not character: both end in the lead byte 0xC3 of a split character.
        #expect(VNCAuth.response(challenge: Self.challenge, password: "abcdefgä")
            == VNCAuth.response(challenge: Self.challenge, password: "abcdefgö"))
    }

    @Test func malformedChallengeStillYieldsSixteenBytes() {
        #expect(VNCAuth.response(challenge: Data([1, 2, 3]), password: "x").count == 16)
        #expect(VNCAuth.response(challenge: Data(repeating: 7, count: 20), password: "x")
            == VNCAuth.response(challenge: Data(repeating: 7, count: 16), password: "x"))
    }
}
