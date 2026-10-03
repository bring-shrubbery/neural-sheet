import ActivityKit
import Foundation
import UIKit

/// What keeps a run going and visible off screen (iOS app design §2, Background): a background
/// task held for the run's length, and a Live Activity with the take's name and the percentage.
/// One per run; ``finish(status:)`` releases both, on every path.
final class RunSupport {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activity: Activity<TranscriptionActivityAttributes>?
    private var shown: TranscriptionActivityAttributes.ContentState?

    /// - Parameter onExpiry: The system is ending the background time; the run must stop.
    init(fileName: String, status: String, onExpiry: @escaping @MainActor () -> Void) {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transcription") {
            MainActor.assumeIsolated { onExpiry() }
        }

        startActivity(fileName: fileName, status: status)
    }

    /// The activity's percentage and status, sent only when either has changed.
    func update(progress: Float, status: String) {
        let state = TranscriptionActivityAttributes.ContentState(percent: Self.percent(progress), status: status)

        guard state != shown, let activity else { return }

        shown = state

        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// The run is over: the activity shows how it ended and goes, and the background time is
    /// handed back.
    func finish(status: String, progress: Float) {
        if let activity {
            let state = TranscriptionActivityAttributes.ContentState(percent: Self.percent(progress), status: status)

            Task {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 30))
            }

            self.activity = nil
        }

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    deinit {
        if backgroundTask != .invalid {
            let task = backgroundTask

            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
    }

    static func percent(_ progress: Float) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded(.down))
    }

    private func startActivity(fileName: String, status: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = TranscriptionActivityAttributes.ContentState(percent: 0, status: status)

        do {
            activity = try Activity.request(attributes: TranscriptionActivityAttributes(fileName: fileName),
                                            content: ActivityContent(state: state, staleDate: nil))
            shown = state
        } catch {
            print("NeuralSheet: no Live Activity: \(error.localizedDescription)")
        }
    }
}
