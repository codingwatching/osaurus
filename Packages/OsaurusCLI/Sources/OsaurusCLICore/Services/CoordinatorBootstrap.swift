import Foundation

public struct CoordinatorBootstrapResult: Equatable, Sendable {
    public let root: URL
    public let createdDirectories: [String]
    public let existingDirectories: [String]
    public let seededFiles: [String]

    public var initialized: Bool { true }
}

public struct CoordinatorBootstrap {
    public static let defaultLanes = ["codexauto", "kepler", "newton", "noether", "turing"]

    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func initialize(lanes: [String] = Self.defaultLanes) throws -> CoordinatorBootstrapResult {
        var createdDirectories: [String] = []
        var existingDirectories: [String] = []

        let requiredDirectories =
            [
                paths.root,
                paths.stateDirectory,
                paths.locksDirectory,
                paths.worktreesDirectory,
                paths.artifactsDirectory,
                paths.evidenceDirectory,
                paths.lanesDirectory,
            ] + lanes.map { paths.laneDirectory(named: $0) }

        for directory in requiredDirectories {
            if fileManager.fileExists(atPath: directory.path) {
                existingDirectories.append(directory.path)
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: CoordinatorFilePermissions.directoryAttributes
                )
                createdDirectories.append(directory.path)
            }
            try CoordinatorFilePermissions.applyDirectoryPermissions(to: directory, fileManager: fileManager)
        }

        var seededFiles: [String] = []
        if try seedJSONIfMissing(CoordinatorFeatureFlags.defaults, at: paths.featureFlagsFile) {
            seededFiles.append(paths.featureFlagsFile.path)
        }
        if try seedJSONIfMissing(CoordinatorLaneSeed(lanes: lanes), at: paths.lanesFile) {
            seededFiles.append(paths.lanesFile.path)
        }
        if try seedJSONIfMissing(CoordinatorBootstrapStatus(initializedAt: Date()), at: paths.statusFile) {
            seededFiles.append(paths.statusFile.path)
        }

        return CoordinatorBootstrapResult(
            root: paths.root,
            createdDirectories: createdDirectories.sorted(),
            existingDirectories: existingDirectories.sorted(),
            seededFiles: seededFiles.sorted()
        )
    }

    private func seedJSONIfMissing<T: Encodable>(_ value: T, at url: URL) throws -> Bool {
        guard !fileManager.fileExists(atPath: url.path) else {
            try CoordinatorFilePermissions.applyFilePermissions(to: url, fileManager: fileManager)
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try CoordinatorFilePermissions.applyFilePermissions(to: url, fileManager: fileManager)
        return true
    }
}

private struct CoordinatorLaneSeed: Codable, Equatable {
    let lanes: [String]
}

private struct CoordinatorBootstrapStatus: Codable, Equatable {
    let initializedAt: Date
}
