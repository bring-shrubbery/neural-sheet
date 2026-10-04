import XCTest

/// Photographs every screen in a language or at a text size, for a person to look over for text
/// left in English or clipped (sub-issue J). Skipped unless asked for, from the command line:
///
///     TEST_RUNNER_NS_LANG=de TEST_RUNNER_NS_SHOTS=/path/to/folder xcodebuild … test \
///         -only-testing:NeuralSheetUITests/LocalizedScreenshotTests
///
/// `TEST_RUNNER_NS_CONTENT_SIZE=UICTContentSizeCategoryXXXL` sets the text size instead of, or as
/// well as, the language. The PNGs are written to the folder and attached to the result bundle.
final class LocalizedScreenshotTests: XCTestCase {
    func testPhotographEveryScreen() throws {
        let environment = ProcessInfo.processInfo.environment

        guard let folder = environment["NS_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_NS_SHOTS to a folder to photograph the screens")
        }

        let tag = [ProjectFixture.language, ProjectFixture.contentSize.map { $0.replacingOccurrences(of: "UICTContentSizeCategory", with: "") }]
            .compactMap { $0 }
            .joined(separator: "-")
        let app = ProjectFixture.launch()

        func shoot(_ name: String) {
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(tag)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(tag)-\(name).png")
            try? shot.pngRepresentation.write(to: url)
        }

        for screen in ProjectFixture.Screen.allCases {
            screen.show(in: app)
            shoot(screen.name)
        }

        ProjectFixture.Screen.transcribe.show(in: app)

        for id in ["speed", "output", "strips"] where app.buttons[id].exists && app.buttons[id].isHittable {
            app.buttons[id].tap()
            _ = app.otherElements.firstMatch.waitForExistence(timeout: 1)
            shoot("transcribe-\(id)")
            ProjectFixture.dismissPopover(in: app)
        }

        if app.buttons["instruments"].exists {
            app.buttons["instruments"].tap()
            shoot("instruments-sheet")
            app.swipeDown(velocity: .fast)
        }

        ProjectFixture.Screen.roll.show(in: app)

        if app.buttons["commands"].exists, app.buttons["commands"].isEnabled {
            app.buttons["commands"].tap()
            shoot("roll-commands")
            ProjectFixture.dismissPopover(in: app)
        }

        if app.buttons["export"].exists, app.buttons["export"].isEnabled {
            app.buttons["export"].tap()
            shoot("roll-export")
            ProjectFixture.dismissPopover(in: app)
        }

        // The note card, for the first note VoiceOver lists.
        let timeline = app.descendants(matching: .any)["timeline"]

        if timeline.exists, let note = timeline.descendants(matching: .button).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            note.press(forDuration: 0.8)
            _ = app.otherElements["note-card"].waitForExistence(timeout: 2)
            shoot("note-card")
            app.swipeDown(velocity: .fast)
        }
    }
}
