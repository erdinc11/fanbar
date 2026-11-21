import Foundation
import IOKit

/// AppleSMC user-client. One 80-byte struct call (selector 2) carries every
/// key operation: 9 = key info, 5 = read value, 6 = write value.
/// Layout copied from the verified OpenFan implementation (Mac17,9 / macOS 27)
/// and confirmed against Mac15,3; field order and widths are ABI.
public final class AppleSMCBackend: SMCBackend {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: SMCKeyInfo] = [:]
    private var absentKeys: Set<String> = []

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        var conn: io_connect_t = 0
        let kern = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kern == KERN_SUCCESS, conn != 0 else { throw SMCError.openFailed(kern) }
        connection = conn
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCPowerLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
    private struct SMCKeyInfoParam { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private typealias SMCBytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private struct SMCKeyData {
        var key: UInt32 = 0
        var version = SMCVersion()
        var powerLimit = SMCPowerLimit()
        var keyInfo = SMCKeyInfoParam()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes32 = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private let selectorReadKeyInfo: UInt8 = 9
    private let selectorReadBytes: UInt8 = 5
    private let selectorWriteBytes: UInt8 = 6
    private let typeFloat = SMCFormat.fourCC("flt ")
    private let typeUInt8 = SMCFormat.fourCC("ui8 ")
    private let typeUInt32 = SMCFormat.fourCC("ui32")
    private let notPrivileged = kern_return_t(bitPattern: 0xe00002c1) // kIOReturnNotPrivileged

    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        if absentKeys.contains(key) { throw SMCError.keyNotFound(key) }

        var input = SMCKeyData()
        input.key = SMCFormat.fourCC(key)
        input.data8 = selectorReadKeyInfo
        let output: SMCKeyData
        do {
            output = try call(&input)
        } catch {
            absentKeys.insert(key)
            throw SMCError.keyNotFound(key)
        }
        let info = SMCKeyInfo(
            dataSize: output.keyInfo.dataSize,
            dataType: output.keyInfo.dataType,
            attributes: output.keyInfo.dataAttributes
        )
        guard info.dataSize > 0 else {
            absentKeys.insert(key)
            throw SMCError.keyNotFound(key)
        }
        keyInfoCache[key] = info
        return info
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    public func readFloat(_ key: String) throws -> Float {
        let info = try keyInfo(key)
        guard info.dataType == typeFloat else { throw SMCError.unexpectedType(key) }
        guard info.dataSize == 4 else { throw SMCError.unexpectedSize(key) }
        let bytes = try readBytes(key, info: info)
        return SMCFormat.decodeFloat(bytes)
    }

    public func readUInt8(_ key: String) throws -> UInt8 {
        let info = try keyInfo(key)
        guard info.dataType == typeUInt8 else { throw SMCError.unexpectedType(key) }
        guard info.dataSize == 1 else { throw SMCError.unexpectedSize(key) }
        return try readBytes(key, info: info)[0]
    }

    public func readUInt32(_ key: String) throws -> UInt32 {
        let info = try keyInfo(key)
        guard info.dataType == typeUInt32 else { throw SMCError.unexpectedType(key) }
        guard info.dataSize == 4 else { throw SMCError.unexpectedSize(key) }
        let bytes = try readBytes(key, info: info)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    public func writeFloat(_ key: String, _ value: Float) throws {
        let info = try keyInfo(key)
        guard info.dataType == typeFloat else { throw SMCError.unexpectedType(key) }
        guard info.dataSize == 4 else { throw SMCError.unexpectedSize(key) }
        try writeBytes(key, info: info, bytes: SMCFormat.encodeFloat(value))
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        let info = try keyInfo(key)
        guard info.dataType == typeUInt8 else { throw SMCError.unexpectedType(key) }
        guard info.dataSize == 1 else { throw SMCError.unexpectedSize(key) }
        try writeBytes(key, info: info, bytes: [value])
    }

    private func readBytes(_ key: String, info: SMCKeyInfo) throws -> [UInt8] {
        var input = SMCKeyData()
        input.key = SMCFormat.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType
        input.data8 = selectorReadBytes
        let output = try call(&input)
        let count = min(Int(info.dataSize), 32)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(count)) }
    }

    private func writeBytes(_ key: String, info: SMCKeyInfo, bytes: [UInt8]) throws {
        var input = SMCKeyData()
        input.key = SMCFormat.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType
        input.data8 = selectorWriteBytes
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (index, byte) in bytes.prefix(32).enumerated() { raw[index] = byte }
        }
        do {
            _ = try call(&input)
        } catch let error as SMCError {
            if case .callFailed(_, let kern, _) = error, kern == notPrivileged {
                throw SMCError.notPrivileged
            }
            throw error
        }
    }

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kern = IOConnectCallStructMethod(
            connection, 2,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize
        )
        let key = SMCFormat.string(from: input.key)
        guard kern == KERN_SUCCESS else { throw SMCError.callFailed(key: key, kern: kern, result: output.result) }
        guard output.result == 0 else { throw SMCError.callFailed(key: key, kern: kern, result: output.result) }
        return output
    }
}
