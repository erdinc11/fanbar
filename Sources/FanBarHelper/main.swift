import Foundation
import Darwin
import FanBarSMC

// A client that disconnects mid-response must not kill the helper.
signal(SIGPIPE, SIG_IGN)

do {
    let backend = try AppleSMCBackend()
    let hardware = try Hardware.discover(backend)
    guard let fan = hardware.fans.first else {
        FileHandle.standardError.write(Data("No controllable fans found\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("FanBar helper: fan \(fan.index) [\(Int(fan.minRPM))-\(Int(fan.maxRPM))], mode key \(fan.modeKey)\n".utf8))
    let daemon = HelperDaemon(backend: backend, hardware: hardware, allowedUID: GeneratedConfig.allowedUID)
    try daemon.run()
} catch {
    FileHandle.standardError.write(Data("FanBar helper failed: \(error)\n".utf8))
    exit(1)
}
