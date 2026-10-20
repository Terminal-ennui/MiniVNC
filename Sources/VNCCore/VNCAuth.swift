import CommonCrypto
import Foundation

public enum VNCAuth {
    /// RFB VNC-auth response: DES-ECB encrypt the 16-byte challenge with the password as key —
    /// first 8 bytes of its UTF-8, zero-padded, each byte bit-reversed (the RFB quirk). Returns 16 bytes.
    /// A challenge of the wrong length is truncated or zero-padded to 16 bytes.
    public static func response(challenge: Data, password: String) -> Data {
        let key = padded(password.utf8, to: 8).map(reversedBits)
        let input = padded(challenge, to: 16)
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
            key, kCCKeySizeDES, nil, input, input.count, &output, output.count, &moved)
        // Can't fail for an 8-byte key and 16-byte input; zeros would just make the server reject the login.
        guard status == kCCSuccess, moved == 16 else { return Data(count: 16) }
        return Data(output)
    }

    /// First `count` bytes, zero-padded to exactly `count`.
    private static func padded(_ bytes: some Sequence<UInt8>, to count: Int) -> [UInt8] {
        let head = Array(bytes.prefix(count))
        return head + [UInt8](repeating: 0, count: count - head.count)
    }

    private static func reversedBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 {
            r = r << 1 | v & 1
            v >>= 1
        }
        return r
    }
}
