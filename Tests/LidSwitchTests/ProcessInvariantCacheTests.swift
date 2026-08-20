import Dispatch
import Foundation
import XCTest
@testable import LidSwitchCore

private final class ConcurrentInvariantLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loadCount = 0
    private var results: [String?] = []

    func load() -> String {
        lock.lock()
        loadCount += 1
        lock.unlock()

        // Widen the first-load overlap so the test proves the cache serializes
        // concurrent initialization instead of merely observing lucky timing.
        Thread.sleep(forTimeInterval: 0.005)
        return "stable"
    }

    func record(_ result: String?) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    func snapshot() -> (loadCount: Int, results: [String?]) {
        lock.lock()
        defer { lock.unlock() }
        return (loadCount, results)
    }
}

final class ProcessInvariantCacheTests: XCTestCase {
    func testFailedLoadIsRetriedAndFirstSuccessIsCached() {
        let cache = ProcessInvariantCache<String>()
        var loadCount = 0

        XCTAssertNil(cache.value(load: {
            loadCount += 1
            return nil
        }))
        XCTAssertEqual(cache.value(load: {
            loadCount += 1
            return "first-success"
        }), "first-success")
        XCTAssertEqual(cache.value(load: {
            loadCount += 1
            return "must-not-replace"
        }), "first-success")
        XCTAssertEqual(loadCount, 2)
    }

    func testConcurrentReadersShareOneSuccessfulKernelLoad() {
        let cache = ProcessInvariantCache<String>()
        let recorder = ConcurrentInvariantLoadRecorder()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let value = cache.value(load: { recorder.load() })
            recorder.record(value)
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.loadCount, 1)
        XCTAssertEqual(snapshot.results.count, 32)
        XCTAssertTrue(snapshot.results.allSatisfy { $0 == "stable" })
    }

    func testMonotonicClockRemainsFiniteAndNondecreasingAcrossHotReads() {
        var previous = MonotonicClock.seconds()
        XCTAssertTrue(previous.isFinite)

        for _ in 0..<10_000 {
            let next = MonotonicClock.seconds()
            XCTAssertTrue(next.isFinite)
            XCTAssertGreaterThanOrEqual(next, previous)
            previous = next
        }
    }
}
