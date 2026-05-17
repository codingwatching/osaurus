import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorStatusServiceTests: XCTestCase {
    func testSnapshotReportsUninitializedRoot() throws {
        let snapshot = try CoordinatorStatusService(paths: try temporaryPaths()).snapshot()

        XCTAssertFalse(snapshot.initialized)
        XCTAssertTrue(snapshot.directories.contains { $0.name == "state" && !$0.exists })
        XCTAssertEqual(snapshot.featureFlags["coordinator"], true)
    }

    func testSnapshotReportsInitializedRootAndLocks() throws {
        let paths = try temporaryPaths()
        _ = try CoordinatorBootstrap(paths: paths).initialize(lanes: ["alpha"])
        let lockService = CoordinatorLockService(paths: paths)
        let now = Date(timeIntervalSince1970: 200)
        _ = try lockService.acquire(resource: "active", owner: "worker", ttl: 20, now: now)
        _ = try lockService.acquire(resource: "expired", owner: "worker", ttl: 1, now: now)

        let snapshot = try CoordinatorStatusService(paths: paths).snapshot(now: Date(timeIntervalSince1970: 202))

        XCTAssertTrue(snapshot.initialized)
        XCTAssertEqual(snapshot.activeLocks.map(\.resource), ["active"])
        XCTAssertEqual(snapshot.expiredLocks.map(\.resource), ["expired"])
    }
}
