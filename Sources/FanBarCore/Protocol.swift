import Foundation

public enum Constants {
    public static let socketPath = "/var/run/fanbar.helper.sock"
    public static let leaseSeconds: TimeInterval = 12
    public static let refreshInterval: TimeInterval = 1
    public static let helperVersion = "1"
}

public struct FanRequest: Codable, Equatable {
    public var cmd: String
    public var rpm: Float?
    /// A status poll may double as the lease heartbeat, but only when the
    /// caller is the owner of a manual selection. An Auto-mode poller must
    /// never keep someone else's manual target alive.
    public var keepAlive: Bool?

    public init(cmd: String, rpm: Float? = nil, keepAlive: Bool? = nil) {
        self.cmd = cmd
        self.rpm = rpm
        self.keepAlive = keepAlive
    }

    public static func encode(_ value: FanRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(_ data: Data) throws -> FanRequest {
        try JSONDecoder().decode(FanRequest.self, from: data)
    }
}

public struct FanResponse: Codable, Equatable {
    public var ok: Bool
    public var rpm: Float?
    public var mode: UInt8?
    public var actual: Float?
    public var max: Float?
    public var min: Float?
    public var error: String?
    public var version: String?

    public init(ok: Bool, rpm: Float? = nil, mode: UInt8? = nil, actual: Float? = nil,
                max: Float? = nil, min: Float? = nil, error: String? = nil, version: String? = nil) {
        self.ok = ok
        self.rpm = rpm
        self.mode = mode
        self.actual = actual
        self.max = max
        self.min = min
        self.error = error
        self.version = version
    }

    public static func encode(_ value: FanResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(_ data: Data) throws -> FanResponse {
        try JSONDecoder().decode(FanResponse.self, from: data)
    }
}

public enum Lease {
    public static func isExpired(lastPing: Date, now: Date, duration: TimeInterval) -> Bool {
        now.timeIntervalSince(lastPing) >= duration
    }
}
