import Foundation
import AppKit
import ServiceManagement
import FanBarSMC
import FanBarCore

public protocol LoginItemServicing {
    var isEnabled: Bool { get }
    func setEnabled(_ value: Bool) throws
}

public final class SMAppServiceLoginItem: LoginItemServicing {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ value: Bool) throws {
        if value {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public final class MenuBarController: NSObject, NSMenuDelegate {
    private let backend: SMCBackend
    private let hardware: Hardware
    private let loginService: LoginItemServicing
    let helperManager: HelperManaging
    private let clientFactory: () -> any HelperClientProtocol
    private let alertPresenter: (String) -> Void
    private let manualPrompt: (String, String) -> String?
    private let logger: (String) -> Void
    private var client: any HelperClientProtocol

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var timer: Timer?
    private var optionItems: [NSMenuItem: FanOption] = [:]
    private weak var statusMenuItem: NSMenuItem?
    private weak var rpmMenuItem: NSMenuItem?
    private weak var helperMenuItem: NSMenuItem?
    private weak var loginMenuItem: NSMenuItem?
    private(set) var rpmTextField: NSTextField?

    public private(set) var selectedOption: FanOption = .auto
    public private(set) var manualRPM: Float?
    public private(set) var title: String = "--°"
    public private(set) var currentRPMLabel: String = "Fan: —"
    public private(set) var currentStatusLabel: String = "Helper: unknown"

    public init(
        backend: SMCBackend,
        hardware: Hardware,
        client: any HelperClientProtocol,
        loginService: LoginItemServicing = SMAppServiceLoginItem(),
        helperManager: HelperManaging = HelperManager(),
        clientFactory: @escaping () -> any HelperClientProtocol,
        alertPresenter: @escaping (String) -> Void = { message in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "FanBar"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            }
        },
        manualPrompt: @escaping (String, String) -> String? = MenuBarController.promptForManualRPM,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.hardware = hardware
        self.client = client
        self.loginService = loginService
        self.helperManager = helperManager
        self.clientFactory = clientFactory
        self.alertPresenter = alertPresenter
        self.manualPrompt = manualPrompt
        self.logger = logger
        super.init()
    }

    public func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = title
        statusItem = item
        menu = buildMenu()
        menu?.delegate = self
        item.menu = menu

        // .common keeps the 1 Hz timer firing while an NSMenu is tracking
        // events; the default mode pauses during an open dropdown.
        let refreshTimer = Timer(timeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTemperature()
            self?.refreshStatus()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
        clearStaleControlOnLaunch()
        refreshTemperature()
        refreshStatus()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        _ = try? client.send(FanRequest(cmd: "auto"))
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    // MARK: - Testable behavior

    public static func statusTitle(_ response: FanResponse?, installed: Bool = false) -> String {
        guard let response else {
            return installed ? "Helper: not running" : "Helper: not installed"
        }
        if response.error != nil { return "Helper: limited" }
        return response.ok ? "Helper: ready" : "Helper: not running"
    }

    public static func rpmTitle(_ response: FanResponse?) -> String {
        guard let response, response.ok, let actual = response.actual else { return "Fan: —" }
        return "Fan: \(Int(actual.rounded())) RPM"
    }

    public func refreshTemperature() {
        guard let temp = hardware.cpuTemperature(backend) else { return }
        let rounded = Int((temp + 0.5).rounded(.down))
        let newTitle = "\(rounded)°"
        title = newTitle
        statusItem?.button?.title = newTitle
    }

    @discardableResult
    public func apply(option: FanOption) -> FanResponse? {
        switch option {
        case .auto:
            let response = try? client.send(FanRequest(cmd: "auto"))
            if response?.ok == true {
                selectedOption = .auto
                manualRPM = nil
            } else {
                selectedOption = .auto
                manualRPM = nil
                showError(response?.error ?? "Could not reach the helper.")
            }
            updateCheckmarks()
            return response

        case .manual:
            guard let rpm = manualRPM else { return nil }
            return applyManual(rpm)

        default:
            guard let fan = hardware.fans.first,
                  let rpm = option.rpm(min: fan.minRPM, max: fan.maxRPM) else { return nil }
            return sendSet(rpm: rpm, selecting: option)
        }
    }

    @discardableResult
    public func applyManual(_ rpm: Float) -> FanResponse? {
        sendSet(rpm: rpm, selecting: .manual)
    }

    private func sendSet(rpm: Float, selecting option: FanOption) -> FanResponse? {
        guard let fan = hardware.fans.first, rpm >= fan.minRPM, rpm <= fan.maxRPM else { return nil }
        let response = try? client.send(FanRequest(cmd: "set", rpm: rpm))
        if response?.ok == true {
            selectedOption = option
            manualRPM = option == .manual ? rpm : nil
        } else {
            selectedOption = .auto
            manualRPM = nil
            showError(response?.error ?? "Could not reach the helper.")
        }
        updateCheckmarks()
        return response
    }

    public func requestManualRPM() {
        guard let fan = hardware.fans.first else { return }
        let current = manualRPM ?? hardware.fanRPM(backend, index: fan.index) ?? fan.minRPM
        let defaultText = "\(Int(current.rounded()))"
        guard let text = manualPrompt(
            "Manual fan speed",
            "Enter a value between \(Int(fan.minRPM)) and \(Int(fan.maxRPM)) RPM."
        ) else { return }
        let entered = text.isEmpty ? defaultText : text
        guard let rpm = ManualRPM.parse(entered, min: fan.minRPM, max: fan.maxRPM) else {
            showError("Enter a value between \(Int(fan.minRPM)) and \(Int(fan.maxRPM)) RPM.")
            return
        }
        applyManual(rpm)
    }

    @objc public func didWake(_ notification: Notification) {
        handleWake()
    }

    public func handleWake() {
        // The helper releases fans on sleep. Reconnect and re-apply the user's
        // selection; for Auto just verify the helper is reachable again.
        logger("wake/reconnect: re-applying \(selectedOption.rawValue)")
        client = clientFactory()
        if selectedOption == .auto {
            _ = try? client.send(FanRequest(cmd: "status"))
        } else {
            apply(option: selectedOption)
        }
        updateCheckmarks()
    }

    /// A fresh launch starts in Auto. If a previous app instance left the
    /// helper holding a manual target, release it now instead of waiting for
    /// the 12 s lease.
    func clearStaleControlOnLaunch() {
        guard selectedOption == .auto else { return }
        _ = try? client.send(FanRequest(cmd: "auto"))
    }

    public func refreshStatus() {
        var response: FanResponse?
        do {
            response = try client.send(FanRequest(cmd: "status", keepAlive: selectedOption == .auto ? nil : true))
        } catch {
            logger("status failed: \(error); reconnecting")
        }
        currentRPMLabel = Self.rpmTitle(response)
        currentStatusLabel = Self.statusTitle(response, installed: helperManager.isInstalled)
        rpmMenuItem?.title = currentRPMLabel
        rpmTextField?.stringValue = currentRPMLabel
        statusMenuItem?.title = currentStatusLabel
        helperMenuItem?.title = helperManager.actionTitle

        guard selectedOption != .auto, response?.rpm == nil else { return }
        logger("helper lost control; re-applying selection")
        handleWake()
    }

    // MARK: - Helper lifecycle

    func toggleHelperAction() {
        if helperManager.isInstalled {
            _ = try? client.send(FanRequest(cmd: "auto"))
            do {
                try helperManager.uninstall()
                selectedOption = .auto
                manualRPM = nil
                updateCheckmarks()
                refreshStatus()
            } catch {
                showError("Could not remove the helper: \(error)")
            }
        } else {
            do {
                try helperManager.install()
                _ = try? client.send(FanRequest(cmd: "auto"))
                refreshStatus()
            } catch {
                showError("Could not install the helper: \(error)")
            }
        }
    }

    // MARK: - Menu

    public func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let rpm = NSMenuItem(title: "Fan: —", action: nil, keyEquivalent: "")
        rpm.isEnabled = false
        // A plain menu-item title is not repainted while the menu is open.
        // An NSTextField in the item view redraws whenever stringValue changes.
        let rpmView = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 22))
        let label = NSTextField(labelWithString: "Fan: —")
        // Native menu titles start after the checkmark column. Measured against
        // a live menu: 27 pt matches "Auto"/"2.5k" exactly.
        label.frame = NSRect(x: 27, y: 3, width: 163, height: 16)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.autoresizingMask = [.width, .height]
        rpmView.addSubview(label)
        rpm.view = rpmView
        rpmTextField = label
        menu.addItem(rpm)
        rpmMenuItem = rpm
        menu.addItem(NSMenuItem.separator())

        for option in FanOption.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(selectOption(_:)), keyEquivalent: "")
            item.target = self
            optionItems[item] = option
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = loginService.isEnabled ? .on : .off
        menu.addItem(login)
        loginMenuItem = login

        let helper = NSMenuItem(title: helperManager.actionTitle, action: #selector(toggleHelper(_:)), keyEquivalent: "")
        helper.target = self
        menu.addItem(helper)
        helperMenuItem = helper
        menu.addItem(NSMenuItem.separator())

        let status = NSMenuItem(title: "Helper: unknown", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        updateCheckmarks()
        return menu
    }

    @objc private func selectOption(_ sender: NSMenuItem) {
        guard let option = optionItems[sender] else { return }
        if option == .manual {
            requestManualRPM()
        } else {
            apply(option: option)
        }
    }

    @objc private func toggleHelper(_ sender: NSMenuItem) {
        toggleHelperAction()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            try loginService.setEnabled(!loginService.isEnabled)
            sender.state = loginService.isEnabled ? .on : .off
        } catch {
            showError("Could not change Start at Login. Add FanBar in System Settings → General → Login Items.")
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateCheckmarks() {
        for (item, option) in optionItems {
            item.state = option == selectedOption ? .on : .off
        }
    }

    private func showError(_ message: String) {
        alertPresenter(message)
    }

    public static func promptForManualRPM(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 3500"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
