import Foundation

public enum Latin1 {
    /// Legacy ClientCutText: ISO-8859-1; characters above U+00FF become "?", NULs are dropped; CRLF/CR normalized to LF.
    public static func encode(_ text: String) -> Data {
        var out = Data()
        var previous: Unicode.Scalar = "\0"
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            defer { previous = scalar }
            if scalar == "\0" || (scalar == "\n" && previous == "\r") { continue }
            out.append(scalar == "\r" ? 0x0A : scalar.value <= 0xFF ? UInt8(scalar.value) : 0x3F)
        }
        return out
    }

    public static func decode(_ data: Data) -> String {
        var out = String.UnicodeScalarView()
        var previous: UInt8 = 0
        for byte in data {
            defer { previous = byte }
            if byte == 0x0A && previous == 0x0D { continue }
            out.append(Unicode.Scalar(byte == 0x0D ? 0x0A : byte))
        }
        return String(out)
    }
}
