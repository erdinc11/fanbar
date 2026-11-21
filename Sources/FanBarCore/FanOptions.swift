import Foundation

public enum FanOption: String, CaseIterable {
    case auto
    case r2500
    case r3000
    case r4000
    case r5000
    case full
    case manual

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .r2500: return "2.5k"
        case .r3000: return "3k"
        case .r4000: return "4k"
        case .r5000: return "5k"
        case .full: return "6.8k (Full)"
        case .manual: return "Manual RPM…"
        }
    }

    /// Full follows the live SMC maximum; it is never a hardcoded 6800.
    /// Auto releases the fan and Manual asks the user for a value.
    public func rpm(min: Float, max: Float) -> Float? {
        switch self {
        case .auto, .manual: return nil
        case .r2500: return 2500
        case .r3000: return 3000
        case .r4000: return 4000
        case .r5000: return 5000
        case .full: return max
        }
    }
}

public enum ManualRPM {
    /// Parses "4000", " 3500 " or "4,2k" and rejects anything outside the
    /// discovered fan range. Returns nil for an invalid or out-of-range value.
    public static func parse(_ text: String, min: Float, max: Float) -> Float? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("k") {
            value.removeLast()
            value = value.replacingOccurrences(of: ",", with: ".")
            guard let number = Double(value) else { return nil }
            let rpm = Float(number * 1000)
            guard rpm.isFinite, rpm >= min, rpm <= max else { return nil }
            return rpm
        }

        let digits = value.replacingOccurrences(of: ",", with: "")
        guard let number = Float(digits), number.isFinite, number >= min, number <= max else { return nil }
        return number
    }
}
