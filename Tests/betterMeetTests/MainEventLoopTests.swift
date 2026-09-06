import Foundation
import ArgumentParser
import XCTest
@testable import betterMeet

final class MainEventLoopTests: XCTestCase {
    @MainActor
    private final class Probe {
        var callbackAttached = false
    }

    func testMainActorTasksRunInsideBlockingEventLoop() throws {
        try MainEventLoop.run {
            let probe = Probe()
            XCTAssertTrue(Thread.isMainThread)
            // Matches AppController's deferred callback attachment.
            Task { @MainActor in probe.callbackAttached = true }
            let deadline = Date().addingTimeInterval(2)
            while !probe.callbackAttached && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: deadline)
            }
            XCTAssertTrue(probe.callbackAttached, "startup task was starved by the blocking event loop")
        }
    }

    func testStartupErrorsPropagate() {
        do {
            try MainEventLoop.run { throw TranscriptionFailure("startup failure") }
            XCTFail("expected startup failure")
        } catch {
            XCTAssertEqual(String(describing: error), "startup failure")
        }
    }

    func testDaemonCommandStaysSynchronous() throws {
        let command = try BetterMeet.parseAsRoot(["run"])
        XCTAssertTrue(command is Run)
        XCTAssertFalse(command is any AsyncParsableCommand)
    }
}
