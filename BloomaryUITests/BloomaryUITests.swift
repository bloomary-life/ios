import XCTest

/// End-to-end flows against the stage API (`-backend_environment test`).
/// Run: `scripts/ui-test.sh` (needs `BLOOMARY_DEMO_CODE` for the demo-login flows).
final class BloomaryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let stamp = String(Int(Date().timeIntervalSince1970))

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-backend_environment", "test"]
        app.launch()
    }

    private var demoCode: String {
        ProcessInfo.processInfo.environment["BLOOMARY_DEMO_CODE"] ?? ""
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Answers the system notification prompt that appears after sign-in.
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            shot("system-notification-prompt")
            allow.tap()
        }
    }

    private func button(labelStartingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    private func signInDemo() throws {
        try XCTSkipIf(demoCode.isEmpty, "BLOOMARY_DEMO_CODE not set")
        tab("Settings")
        if app.staticTexts["DEMO"].exists { return }
        app.buttons["Demo"].tap()
        let alert = app.alerts["Demo code"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields["Code"].tap()
        alert.textFields["Code"].typeText(demoCode)
        alert.buttons["Enter"].tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 15))
    }

    func test1_signedOutWriteSaveAndReopenDraft() throws {
        tab("Editor")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("UI test draft \(stamp)")
        shot("1-editor-typed")

        app.buttons["Save draft"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", stamp)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        shot("1-drafts-list")

        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains(stamp))
        shot("1-draft-reopened")
    }

    func test2_demoLoginShowsPaywallWithSubscriptionInfo() throws {
        try signInDemo()
        shot("2-demo-signed-in")

        let pro = button(labelStartingWith: "Bloomary Pro")
        XCTAssertTrue(pro.waitForExistence(timeout: 10))
        pro.tap()
        XCTAssertTrue(app.staticTexts["Bloomary Pro"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Restore Purchases"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["Terms of Use"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Privacy Policy"].exists)
        shot("2-paywall")
    }

    func test3_demoAccountShowsLogOutAndDeleteConfirmation() throws {
        try signInDemo()
        let delete = app.buttons["Delete account"]
        let profile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Registered")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        XCTAssertTrue(app.buttons["Log out"].waitForExistence(timeout: 10))
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        shot("3-account")

        delete.tap()
        shot("3-delete-confirmation")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
    }
}
