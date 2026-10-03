import Foundation
import XCTest

@testable import NeuralSheet

/// The pause between chunks (sub-issue D): a hot device holds the run's thread until it cools or
/// the run is cancelled, and a cool one never waits.
final class ThermalGateTests: XCTestCase {
    /// A thermal state the test sets. `@unchecked Sendable`: guarded by `lock`.
    private nonisolated final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state: ProcessInfo.ThermalState

        init(_ state: ProcessInfo.ThermalState) {
            self.state = state
        }

        var value: ProcessInfo.ThermalState {
            get { lock.lock(); defer { lock.unlock() }; return state }
            set { lock.lock(); state = newValue; lock.unlock() }
        }
    }

    func testACoolDeviceNeverWaits() {
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            let gate = ThermalGate(state: { state })
            let started = Date()

            gate.waitWhileHot()

            XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
            XCTAssertFalse(gate.isPaused)
        }
    }

    func testAHotDeviceHoldsTheRunUntilItCools() {
        let box = StateBox(.serious)
        let gate = ThermalGate(state: { box.value })
        let released = expectation(description: "the run goes on once the device has cooled")

        Thread {
            gate.waitWhileHot()
            released.fulfill()
        }.start()

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(gate.isPaused)

        box.value = .critical
        gate.recheck()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(gate.isPaused, "critical is still hot")

        box.value = .fair
        gate.recheck()

        wait(for: [released], timeout: 2)
        XCTAssertFalse(gate.isPaused)
    }

    func testACancelReleasesAHeldRun() {
        let gate = ThermalGate(state: { .critical })
        let released = expectation(description: "a cancelled run is let go")

        Thread {
            gate.waitWhileHot()
            released.fulfill()
        }.start()

        Thread.sleep(forTimeInterval: 0.2)
        gate.cancel()

        wait(for: [released], timeout: 2)
    }
}
