import UIKit

/// What VoiceOver says of its own accord (a11y design §2, sub-issue J): a run that ends while
/// the user is on another screen, or with the device locked, is heard rather than missed.
enum Announcement {
    static func post(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }

        UIAccessibility.post(notification: .announcement, argument: text)
    }

    static func runFinished(notes: Int) -> String {
        String(localized: "Transcription finished, \(notes) notes",
               comment: "VoiceOver announcement (iOS): a run has landed, with how many notes it found")
    }
}
