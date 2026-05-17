import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorPathsTests: XCTestCase {
    func testDefaultRootIsTmpOsaurusCoord() throws {
        let paths = try CoordinatorPaths.resolve(environment: [:])
        XCTAssertEqual(paths.root.path, "/tmp/osaurus-coord")
    }

    func testEnvironmentRootOverridesDefault() throws {
        let paths = try CoordinatorPaths.resolve(environment: ["OSAURUS_COORD_ROOT": "/tmp/custom-coord"])
        XCTAssertEqual(paths.root.path, "/tmp/custom-coord")
    }

    func testCliRootOverridesEnvironmentRoot() throws {
        let paths = try CoordinatorPaths.resolve(
            cliRoot: "/tmp/cli-coord",
            environment: ["OSAURUS_COORD_ROOT": "/tmp/env-coord"]
        )
        XCTAssertEqual(paths.root.path, "/tmp/cli-coord")
    }

    func testLockFileComponentEscapesPathSeparators() throws {
        let paths = try CoordinatorPaths(rootPath: "/tmp/coordinator-test")
        XCTAssertEqual(paths.lockFile(for: "Packages/Foo.swift").lastPathComponent, "Packages%2FFoo.swift.lock.json")
    }
}
