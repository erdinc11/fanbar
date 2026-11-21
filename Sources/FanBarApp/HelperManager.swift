import Foundation

public protocol HelperManaging {
    var isInstalled: Bool { get }
    var actionTitle: String { get }
    func install() throws
    func uninstall() throws
}

public enum HelperManagerError: Error, CustomStringConvertible {
    case missingScript(String)
    case adminFailed

    public var description: String {
        switch self {
        case .missingScript(let name): return "Missing bundled script: \(name)"
        case .adminFailed: return "Administrator authorization failed"
        }
    }
}

/// Installs and removes the root helper from the app. The heavy lifting lives
/// in two shell scripts bundled in Resources; macOS asks for an administrator
/// password through its own dialog, and nothing is stored.
public final class HelperManager: HelperManaging {
    public static let helperPath = "/Library/PrivilegedHelperTools/fanbar-helper"
    public static let plistPath = "/Library/LaunchDaemons/local.fanbar.helper.plist"

    private let helperPath: String
    private let plistPath: String
    private let fileExists: (String) -> Bool
    private let adminRunner: (String) -> Bool
    private let resources: () -> URL?

    public init(
        helperPath: String = HelperManager.helperPath,
        plistPath: String = HelperManager.plistPath,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        adminRunner: @escaping (String) -> Bool = HelperManager.runAsAdmin,
        resources: @escaping () -> URL? = { Bundle.main.resourceURL }
    ) {
        self.helperPath = helperPath
        self.plistPath = plistPath
        self.fileExists = fileExists
        self.adminRunner = adminRunner
        self.resources = resources
    }

    public var isInstalled: Bool {
        fileExists(helperPath) && fileExists(plistPath)
    }

    public var actionTitle: String {
        isInstalled ? "Remove Helper…" : "Install Helper…"
    }

    public func install() throws {
        try run("install-helper-root.sh")
    }

    public func uninstall() throws {
        try run("uninstall-helper-root.sh")
    }

    private func run(_ scriptName: String) throws {
        guard let directory = resources() else {
            throw HelperManagerError.missingScript(scriptName)
        }
        let path = directory.appendingPathComponent(scriptName).path
        guard fileExists(path) else {
            throw HelperManagerError.missingScript(scriptName)
        }
        guard adminRunner(path) else {
            throw HelperManagerError.adminFailed
        }
    }

    /// `do shell script … with administrator privileges` shows the native
    /// macOS authorization dialog. The script path is single-quoted.
    public static func runAsAdmin(scriptPath: String) -> Bool {
        let escaped = scriptPath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"bash '\(escaped)'\" with administrator privileges",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
