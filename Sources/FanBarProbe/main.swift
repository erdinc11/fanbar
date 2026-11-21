import Foundation
import Darwin
import FanBarSMC

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

let backend: AppleSMCBackend
do {
    backend = try AppleSMCBackend()
} catch {
    print("SMC open FAILED: \(error)")
    exit(1)
}

print("Model      : \(sysctlString("hw.model"))")
print("Chip       : \(sysctlString("machdep.cpu.brand_string"))")
let hardware: Hardware
do {
    hardware = try Hardware.discover(backend)
} catch {
    print("Discover FAILED: \(error)")
    exit(1)
}

print("Fans       : \(hardware.fans.count)")
for fan in hardware.fans {
    let actual = hardware.fanRPM(backend, index: fan.index).map { String(format: "%.0f", $0) } ?? "n/a"
    let target = (try? backend.readFloat(fan.targetKey)).map { String(format: "%.0f", $0) } ?? "n/a"
    let mode = (try? backend.readUInt8(fan.modeKey)).map(String.init) ?? "n/a"
    print(String(format: "Fan %d     : min=%.0f max=%.0f actual=%@ target=%@ mode %@=%@",
                 fan.index, fan.minRPM, fan.maxRPM, actual, target, fan.modeKey, mode))
}
print("Ftst       : \(backend.keyExists("Ftst") ? "present" : "absent")")
if let temp = hardware.cpuTemperature(backend) {
    print(String(format: "CPU die max: %.2f C", temp))
} else {
    print("CPU die max: n/a")
}
print("DONE (read-only)")
