import XCTest

/// Opens the app on a new project with the bundled test take, for the audit and the screenshots,
/// and finds its screens by what does not change with the language: the tab bar's order and the
/// controls' identifiers.
enum ProjectFixture {
    /// The tabs on iPhone, in their order.
    enum Screen: Int, CaseIterable {
        case transcribe, roll, score, settings

        var name: String { String(describing: self) }

        func show(in app: XCUIApplication) {
            let tabs = app.tabBars.firstMatch.buttons

            if tabs.count > rawValue {
                tabs.element(boundBy: rawValue).tap()
            }

            // The screen's first frame, before anything is asked of it.
            _ = app.otherElements.firstMatch.waitForExistence(timeout: 2)
        }
    }

    /// The controls whose names the walk checks.
    static let controlTypes: Set<XCUIElement.ElementType> = [.button, .slider, .switch, .toggle, .stepper, .textField,
                                                             .segmentedControl, .menuButton, .popUpButton]

    /// Xcode's audit checks the app is held to. Contrast is the timeline's and the score's
    /// authored palette, which the design keeps at default settings (Increase Contrast lifts it).
    /// Dynamic Type is left out: the audit flags the system's own toolbar buttons, list buttons,
    /// links and switches as "partially unsupported"; the app's text sizes are checked by
    /// photographing every screen at XXXL and AX5 (`LocalizedScreenshotTests`).
    static let auditTypes: XCUIAccessibilityAuditType = [.elementDetection, .hitRegion, .sufficientElementDescription,
                                                         .textClipped, .trait]

    /// Optional extra launch arguments, from the runner's environment: `TEST_RUNNER_NS_LANG=de`
    /// on the xcodebuild command line arrives here as `NS_LANG`.
    static var language: String? { ProcessInfo.processInfo.environment["NS_LANG"] }
    static var contentSize: String? { ProcessInfo.processInfo.environment["NS_CONTENT_SIZE"] }

    /// Launched, a project created from the launch screen, the test take imported (and
    /// transcribed where the small model is installed), on the Transcribe screen.
    static func launch(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-autoTranscribe", "small"]

        if let language {
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        }

        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }

        app.launch()

        // The launch scene's button is the system's, which takes no identifier: found by its
        // title in each language the app speaks.
        let titles = ["Create Project", "Projekt erstellen", "Crear proyecto"]
        let matches = app.buttons.matching(NSPredicate(format: "label IN %@", titles))
        // Two match: the visible full-width button, and a hidden copy the scene keeps.
        var create: XCUIElement {
            matches.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width } ?? matches.firstMatch
        }

        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15), "the launch screen offered no new project", file: file, line: line)

        // The launch scene settles a moment after it appears; a tap before then is lost.
        for _ in 0 ..< 4 where !app.buttons["import"].exists {
            create.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.buttons["import"].waitForExistence(timeout: 5)
        }

        // The take, then the transcription if the model is there: the run's Cancel comes and goes,
        // leaving Transcribe and, with notes, the result line.
        XCTAssertTrue(app.buttons["import"].waitForExistence(timeout: 20), "the Transcribe screen did not open", file: file, line: line)

        let transcribe = app.buttons["transcribe"]
        _ = transcribe.waitForExistence(timeout: 180)
        _ = app.descendants(matching: .any)["result"].waitForExistence(timeout: 5)

        return app
    }

    static func dismissPopover(in app: XCUIApplication) {
        // A tap outside a popover closes it; the dismiss region is the system's.
        let region = app.otherElements["PopoverDismissRegion"].firstMatch

        if region.exists {
            region.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
    }

    /// Issues the audit raises on what the system draws, not the app: one it cannot pin to an
    /// element is in the system's own chrome (the navigation bar's title menu, the tab bar).
    static func isKnownSystemIssue(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.element == nil
    }
}
