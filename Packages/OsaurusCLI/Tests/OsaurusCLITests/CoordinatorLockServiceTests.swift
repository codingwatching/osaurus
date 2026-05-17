import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorLockServiceTests: XCTestCase {
    func testAcquireCreatesExclusiveLock() throws {
        let service = CoordinatorLockService(paths: try temporaryPaths())

        let first = try service.acquire(resource: "Packages/Foo.swift", owner: "worker-a")
        let second = try service.acquire(resource: "Packages/Foo.swift", owner: "worker-b")

        XCTAssertEqual(
            first,
            .acquired(
                CoordinatorLock(
                    resource: "Packages/Foo.swift",
                    owner: "worker-a",
                    acquiredAt: lockDate(first),
                    expiresAt: nil
                )
            )
        )
        XCTAssertEqual(try posixMode(service.paths.locksDirectory), 0o700)
        XCTAssertEqual(try posixMode(service.paths.lockFile(for: "Packages/Foo.swift")), 0o600)
        if case .held(let lock) = second {
            XCTAssertEqual(lock.owner, "worker-a")
        } else {
            XCTFail("Expected second acquire to be held")
        }
    }

    func testReleaseRequiresMatchingOwnerUnlessForced() throws {
        let service = CoordinatorLockService(paths: try temporaryPaths())
        _ = try service.acquire(resource: "file", owner: "worker-a")

        let mismatch = try service.release(resource: "file", owner: "worker-b")
        XCTAssertEqual(mismatch, .ownerMismatch(current: try XCTUnwrap(service.list().first)))

        let forced = try service.release(resource: "file", owner: "worker-b", force: true)
        XCTAssertEqual(forced, .released)
        XCTAssertTrue(try service.list().isEmpty)
    }

    func testReapExpiredLocks() throws {
        let service = CoordinatorLockService(paths: try temporaryPaths())
        let now = Date(timeIntervalSince1970: 100)
        _ = try service.acquire(resource: "old", owner: "worker-a", ttl: 10, now: now)
        _ = try service.acquire(resource: "fresh", owner: "worker-a", ttl: 100, now: now)

        let reaped = try service.reapExpired(now: Date(timeIntervalSince1970: 111))

        XCTAssertEqual(reaped.map(\.resource), ["old"])
        XCTAssertEqual(try service.list().map(\.resource), ["fresh"])
    }

    private func lockDate(_ result: CoordinatorLockAcquireResult) -> Date {
        if case .acquired(let lock) = result { return lock.acquiredAt }
        return Date(timeIntervalSince1970: 0)
    }
}
