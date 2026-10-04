import XCTest

/// The accessibility audit (sub-issue J): the app is opened on a new project with the bundled test
/// take -- transcribed too, where the simulator has the small model -- and every screen is walked:
/// each button, slider, switch, stepper and text field VoiceOver can reach must have a name, and
/// Xcode's own audit (the Accessibility Inspector's checks) must find nothing on it.
///
/// `LocalizedScreenshotTests` drives the same screens to photograph them in another language.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testEveryControlOnEveryScreenHasALabel() throws {
        let app = ProjectFixture.launch()

        for screen in ProjectFixture.Screen.allCases {
            screen.show(in: app)
            assertEveryControlIsNamed(in: app, on: screen.name)
        }

        // The transport's popovers and the instruments sheet, from the Transcribe screen.
        ProjectFixture.Screen.transcribe.show(in: app)

        for id in ["speed", "output"] where app.buttons[id].exists && app.buttons[id].isEnabled {
            app.buttons[id].tap()
            assertEveryControlIsNamed(in: app, on: "Transcribe, \(id) popover")
            ProjectFixture.dismissPopover(in: app)
        }
    }

    func testXcodesAccessibilityAuditPassesOnEveryScreen() throws {
        let app = ProjectFixture.launch()

        for screen in ProjectFixture.Screen.allCases {
            screen.show(in: app)

            try app.performAccessibilityAudit(for: ProjectFixture.auditTypes) { issue in
                if ProjectFixture.isKnownSystemIssue(issue) { return true }

                let element = issue.element
                XCTFail("\(screen.name): \(issue.compactDescription) -- \(element.map { "\($0.elementType.rawValue) id=\"\($0.identifier)\" label=\"\($0.label)\" frame=\($0.frame)" } ?? "no element")")
                return true
            }
        }
    }

    // MARK: - The walk

    /// Every control in the screen's accessibility tree, read from one snapshot so the walk is
    /// quick, must have a label: the name VoiceOver says before the role.
    private func assertEveryControlIsNamed(in app: XCUIApplication, on screen: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard let root = try? app.snapshot() else {
            XCTFail("no accessibility snapshot of \(screen)", file: file, line: line)
            return
        }

        var unnamed: [String] = []
        var count = 0

        func walk(_ element: XCUIElementSnapshot) {
            if ProjectFixture.controlTypes.contains(element.elementType) {
                count += 1

                // A SwiftUI menu is a system button wrapping the text it shows, which is what
                // VoiceOver reads: the wrapper is named by its children.
                let named = !element.label.trimmingCharacters(in: .whitespaces).isEmpty
                    || element.children.contains { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }

                if !named {
                    let inside = element.children.map(\.label).filter { !$0.isEmpty }.joined(separator: " / ")
                    unnamed.append("\(element.elementType.rawValue) id=\"\(element.identifier)\" value=\"\(element.value ?? "")\" "
                                   + "inside=\"\(inside)\" frame=\(element.frame)")
                }
            }

            element.children.forEach(walk)
        }

        walk(root)

        XCTAssertGreaterThan(count, 0, "no controls found on \(screen)", file: file, line: line)
        XCTAssertTrue(unnamed.isEmpty, "unnamed controls on \(screen):\n" + unnamed.joined(separator: "\n"), file: file, line: line)
    }
}
