import XCTest
@testable import NotchCore

final class CountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartClampsDurationToAtLeastOneSecond() {
        for seconds in [0, -10] {
            var countdown = Countdown()
            countdown.start(seconds: TimeInterval(seconds), now: now)
            XCTAssertEqual(countdown.remaining(at: now), 1)
        }
    }

    func testPauseAndResumeDoNothingWithoutAnActiveCountdown() {
        var countdown = Countdown()

        countdown.pause(now: now)
        countdown.resume(now: now)

        XCTAssertEqual(countdown, Countdown())
    }

    func testPausedCountdownExistsAndCanBeCancelled() {
        var countdown = Countdown()
        countdown.start(seconds: 60, now: now)
        countdown.pause(now: now.addingTimeInterval(10))

        XCTAssertTrue(countdown.exists)
        XCTAssertFalse(countdown.running)

        countdown.cancel()

        XCTAssertFalse(countdown.exists)
        XCTAssertFalse(countdown.running)
        XCTAssertEqual(countdown.remaining(at: now), 0)
    }

    func testConsumeCompletionReturnsFalseWhilePaused() {
        var countdown = Countdown()
        countdown.start(seconds: 60, now: now)
        countdown.pause(now: now.addingTimeInterval(10))

        XCTAssertFalse(countdown.consumeCompletion(now: now.addingTimeInterval(600)))
        XCTAssertTrue(countdown.exists)
    }

    func testStartingAgainWhilePausedClearsThePausedDuration() {
        var countdown = Countdown()
        countdown.start(seconds: 60, now: now)
        countdown.pause(now: now.addingTimeInterval(10))
        countdown.start(seconds: 30, now: now.addingTimeInterval(20))

        XCTAssertTrue(countdown.running)
        XCTAssertNil(countdown.pausedRemaining)
        XCTAssertEqual(countdown.remaining(at: now.addingTimeInterval(20)), 30)
    }

    func testRemainingNeverFallsBelowZero() {
        var countdown = Countdown()
        countdown.start(seconds: 2, now: now)

        XCTAssertEqual(countdown.remaining(at: now.addingTimeInterval(3)), 0)
    }

    func testPausedCountdownRemainsPausedAfterCodableRoundTrip() throws {
        var countdown = Countdown()
        countdown.start(seconds: 60, now: now)
        countdown.pause(now: now.addingTimeInterval(10))

        let data = try JSONEncoder().encode(countdown)
        let restored = try JSONDecoder().decode(Countdown.self, from: data)

        XCTAssertFalse(restored.running)
        XCTAssertTrue(restored.exists)
        XCTAssertEqual(restored.remaining(at: now.addingTimeInterval(600)), 50)
    }
}
