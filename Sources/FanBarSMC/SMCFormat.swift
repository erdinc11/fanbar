import Foundation

/// AppleSMC keys are four big-endian ASCII bytes and numeric values use several
/// wire formats. Only the formats this Mac uses (fourCC + little-endian `flt `)
/// are implemented; a fan target/min/max is a float on Apple silicon.
public enum SMCFormat {
    public static func fourCC(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }

    public static func string(from code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// `flt ` is little-endian IEEE754 on the SMC wire (verified on Mac15,3).
    public static func decodeFloat(_ bytes: [UInt8]) -> Float {
        guard bytes.count >= 4 else { return 0 }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: bits)
    }

    public static func encodeFloat(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff),
        ]
    }
}

public struct SMCKeyInfo: Equatable {
    public let dataSize: UInt32
    public let dataType: UInt32
    public let attributes: UInt8

    public init(dataSize: UInt32, dataType: UInt32, attributes: UInt8) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(key: String, kern: kern_return_t, result: UInt8)
    case keyNotFound(String)
    case notPrivileged
    case unexpectedType(String)
    case unexpectedSize(String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kern): return String(format: "IOServiceOpen failed (0x%08x)", kern)
        case .callFailed(let key, let kern, let result):
            return String(format: "SMC call failed for %@ (kern 0x%08x, result 0x%02x)", key, kern, result)
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .notPrivileged: return "SMC write requires root"
        case .unexpectedType(let key): return "unexpected SMC data type for \(key)"
        case .unexpectedSize(let key): return "unexpected SMC data size for \(key)"
        }
    }
}

/// Reads are unprivileged; writes require a root process. The protocol lets
/// tests supply an in-memory backend without touching real hardware.
public protocol SMCBackend: AnyObject {
    func keyInfo(_ key: String) throws -> SMCKeyInfo
    func readFloat(_ key: String) throws -> Float
    func readUInt8(_ key: String) throws -> UInt8
    func readUInt32(_ key: String) throws -> UInt32
    func writeFloat(_ key: String, _ value: Float) throws
    func writeUInt8(_ key: String, _ value: UInt8) throws
    func keyExists(_ key: String) -> Bool
}
