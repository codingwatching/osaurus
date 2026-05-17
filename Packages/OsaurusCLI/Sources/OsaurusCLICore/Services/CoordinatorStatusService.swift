import Foundation

public struct CoordinatorDirectoryStatus: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let exists: Bool
}

public struct CoordinatorStatusSnapshot: Codable, Equatable, Sendable {
    public let root: String
    public let initialized: Bool
    public let directories: [CoordinatorDirectoryStatus]
    public let featureFlags: [String: Bool]
    public let activeLocks: [CoordinatorLock]
    public let expiredLocks: [CoordinatorLock]
    public let paused: Bool
    public let stopped: Bool
}

public struct CoordinatorStatusService {
    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func snapshot(now: Date = Date()) throws -> CoordinatorStatusSnapshot {
        let directories = requiredDirectories().map { name, url in
            CoordinatorDirectoryStatus(name: name, path: url.path, exists: fileManager.fileExists(atPath: url.path))
        }
        let flags = try CoordinatorFeatureFlagsStore(paths: paths, fileManager: fileManager).load().flags
        let locks = try CoordinatorLockService(paths: paths, fileManager: fileManager).list()
        let expired = locks.filter { $0.isExpired(now: now) }
        let active = locks.filter { !$0.isExpired(now: now) }
        return CoordinatorStatusSnapshot(
            root: paths.root.path,
            initialized: directories.allSatisfy(\.exists)
                && fileManager.fileExists(atPath: paths.featureFlagsFile.path)
                && fileManager.fileExists(atPath: paths.statusFile.path),
            directories: directories,
            featureFlags: flags,
            activeLocks: active,
            expiredLocks: expired,
            paused: fileManager.fileExists(atPath: paths.pauseFile.path),
            stopped: fileManager.fileExists(atPath: paths.stopFile.path)
        )
    }

    private func requiredDirectories() -> [(String, URL)] {
        [
            ("root", paths.root),
            ("state", paths.stateDirectory),
            ("locks", paths.locksDirectory),
            ("worktrees", paths.worktreesDirectory),
            ("artifacts", paths.artifactsDirectory),
            ("evidence", paths.evidenceDirectory),
            ("lanes", paths.lanesDirectory),
        ]
    }
}
