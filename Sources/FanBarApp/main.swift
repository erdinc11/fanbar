import Foundation
import AppKit
import Darwin
import FanBarSMC

signal(SIGPIPE, SIG_IGN)

do {
    let backend = try AppleSMCBackend()
    let hardware = try Hardware.discover(backend)
    let client = HelperClient()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = MenuBarController(
        backend: backend,
        hardware: hardware,
        client: client,
        clientFactory: { HelperClient() },
        logger: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
    controller.start()

    let delegate = AppDelegate(controller: controller)
    app.delegate = delegate
    app.run()
} catch {
    FileHandle.standardError.write(Data("FanBar failed: \(error)\n".utf8))
    exit(1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: MenuBarController

    init(controller: MenuBarController) {
        self.controller = controller
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
