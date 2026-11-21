import XCTest
@testable import FanBarApp

final class HelperManagerTests: XCTestCase {
    private func makeManager(
        installed: Bool,
        runnerResult: Bool = true,
        runner: @escaping (String) -> Void = { _ in }
    ) -> (HelperManager, () -> String?) {
        var ranScript: String?
        let manager = HelperManager(
            helperPath: "/fake/fanbar-helper",
            plistPath: "/fake/local.fanbar.helper.plist",
            fileExists: { path in path.contains("FanBar.app") || installed },
            adminRunner: { path in
                ranScript = path
                runner(path)
                return runnerResult
            },
            resources: { URL(fileURLWithPath: "/fake/FanBar.app/Contents/Resources") }
        )
        return (manager, { ranScript })
    }

    func testActionTitle() {
        XCTAssertEqual(makeManager(installed: false).0.actionTitle, "Install Helper…")
        XCTAssertEqual(makeManager(installed: true).0.actionTitle, "Remove Helper…")
    }

    func testInstallRunsBundledInstallScript() throws {
        let (manager, script) = makeManager(installed: false)

        try manager.install()

        XCTAssertEqual(script(), "/fake/FanBar.app/Contents/Resources/install-helper-root.sh")
    }

    func testUninstallRunsBundledUninstallScript() throws {
        let (manager, script) = makeManager(installed: true)

        try manager.uninstall()

        XCTAssertEqual(script(), "/fake/FanBar.app/Contents/Resources/uninstall-helper-root.sh")
    }

    func testAdminFailureThrows() {
        let (manager, _) = makeManager(installed: false, runnerResult: false)

        XCTAssertThrowsError(try manager.install())
    }
}
