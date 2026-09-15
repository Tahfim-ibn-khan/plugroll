import XCTest
@testable import Plugroll

final class AsyncLimiterTests: XCTestCase {
    private actor Counter {
        private(set) var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    func testNeverRunsMoreThanTheLimit() async {
        let limiter = AsyncLimiter(limit: 3)
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    await limiter.release()
                }
            }
        }

        let peak = await counter.peak
        let current = await counter.current
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 0)
        XCTAssertEqual(current, 0)
    }

    func testSlotsAreFreedAfterRelease() async {
        let limiter = AsyncLimiter(limit: 1)
        for _ in 0..<5 {
            await limiter.acquire()
            await limiter.release()
        }
        // Would hang if a release had leaked the only slot.
        await limiter.acquire()
        await limiter.release()
    }
}
