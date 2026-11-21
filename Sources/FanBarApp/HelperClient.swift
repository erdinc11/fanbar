import Foundation
import Darwin
import FanBarCore

public protocol HelperClientProtocol: AnyObject {
    func send(_ request: FanRequest) throws -> FanResponse
}

/// One short-lived Unix-socket connection per request. A new client after a
/// helper restart is all the recovery the menu bar needs.
public final class HelperClient: HelperClientProtocol {
    private let socketPath: String

    public init(socketPath: String = Constants.socketPath) {
        self.socketPath = socketPath
    }

    public func send(_ request: FanRequest) throws -> FanResponse {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { throw ClientError.socket(errno) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ClientError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, length)
            }
        }
        guard connected == 0 else { throw ClientError.socket(errno) }

        var payload = try FanRequest.encode(request)
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
        guard sent == payload.count else { throw ClientError.socket(errno) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        var used = 0
        while used < capacity {
            let count = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress!.advanced(by: used), capacity - used) }
            if count <= 0 { break }
            used += count
            if buffer[..<used].contains(0x0A) { break }
        }
        guard used > 0 else { throw ClientError.noResponse }
        return try FanResponse.decode(Data(buffer[..<used]))
    }

    public enum ClientError: Error, CustomStringConvertible {
        case socket(Int32)
        case pathTooLong
        case noResponse

        public var description: String {
            switch self {
            case .socket(let code): return "socket error \(code)"
            case .pathTooLong: return "socket path too long"
            case .noResponse: return "no response from helper"
            }
        }
    }
}
