import Foundation

public struct FanHardware: Equatable {
    public let index: Int
    public let minRPM: Float
    public let maxRPM: Float
    public let modeKey: String

    public init(index: Int, minRPM: Float, maxRPM: Float, modeKey: String) {
        self.index = index
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modeKey = modeKey
    }

    public var targetKey: String { "F\(index)Tg" }
    public var actualKey: String { "F\(index)Ac" }

    public func clamp(_ rpm: Float) -> Float {
        min(max(rpm, minRPM), maxRPM)
    }
}

public struct Hardware {
    /// M1-era CPU die sensors; TC0P does not exist on Apple silicon. The hottest
    /// of these is the closest thing to "CPU proximity" on this Mac.
    public static let cpuKeys = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
    ]

    public let fans: [FanHardware]

    public init(fans: [FanHardware]) {
        self.fans = fans
    }

    public static func discover(_ backend: SMCBackend) throws -> Hardware {
        var fanCount = 0
        if let count = try? backend.readUInt8("FNum") {
            fanCount = Int(count)
        } else if let count = try? backend.readUInt32("FNum") {
            fanCount = Int(count)
        } else {
            throw SMCError.keyNotFound("FNum")
        }

        var fans: [FanHardware] = []
        for index in 0..<fanCount {
            guard let min = try? backend.readFloat("F\(index)Mn"),
                  let max = try? backend.readFloat("F\(index)Mx"),
                  min.isFinite, max.isFinite, min > 0, max > min else { continue }
            guard let modeKey = ["F\(index)md", "F\(index)Md"].first(where: { backend.keyExists($0) }) else { continue }
            fans.append(FanHardware(index: index, minRPM: min, maxRPM: max, modeKey: modeKey))
        }
        return Hardware(fans: fans)
    }

    public func cpuTemperature(_ backend: SMCBackend) -> Float? {
        var hottest: Float?
        for key in Self.cpuKeys {
            guard let value = try? backend.readFloat(key), value.isFinite, value > 0, value <= 130 else { continue }
            hottest = hottest.map { max($0, value) } ?? value
        }
        return hottest
    }

    public func fanRPM(_ backend: SMCBackend, index: Int) -> Float? {
        guard let fan = fans.first(where: { $0.index == index }) else { return nil }
        guard let value = try? backend.readFloat(fan.actualKey), value.isFinite, value >= 0, value <= fan.maxRPM + 500 else { return nil }
        return value
    }

    /// Mode 1 is manual on every Apple silicon generation here. Mode 3 is the
    /// system state reported by thermalmonitord and is NOT manual.
    public static func manualMode(_ backend: SMCBackend, fan: FanHardware) -> Bool? {
        guard let mode = try? backend.readUInt8(fan.modeKey) else { return nil }
        return mode == 1
    }
}
