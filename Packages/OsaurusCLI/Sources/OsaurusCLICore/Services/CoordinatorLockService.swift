import Darwin
import Foundation

public struct CoordinatorLock: Codable, Equatable, Sendable {
    public let resource: String
    public let owner: String
    public let acquiredAt: Date
    public let expiresAt: Date?

    public var isExpired: Bool {
        isExpired(now: Date())
    }

    public init(resource: String, owner: String, acquiredAt: Date = Date(), expiresAt: Date? = nil) {
        self.resource = resource
        self.owner = owner
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public enum CoordinatorLockAcquireResult: Equatable, Sendable {
    case acquired(CoordinatorLock)
    case held(CoordinatorLock)
}

public enum CoordinatorLockReleaseResult: Equatable, Sendable {
    case released
    case notFound
    case ownerMismatch(current: CoordinatorLock)
}

public struct CoordinatorLockService {
    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func acquire(resource: String, owner: String, ttl: TimeInterval? = nil, now: Date = Date()) throws
        -> CoordinatorLockAcquireResult
    {
        try fileManager.createDirectory(
            at: paths.locksDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.locksDirectory, fileManager: fileManager)
        let lock = CoordinatorLock(
            resource: resource,
            owner: owner,
            acquiredAt: now,
            expiresAt: ttl.map { now.addingTimeInterval($0) }
        )
        let lockURL = paths.lockFile(for: resource)

        if let existing = try loadLock(at: lockURL), existing.isExpired(now: now) {
            try fileManager.removeItem(at: lockURL)
        }

        let data = try encoded(lock)
        let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if let current = try loadLock(at: lockURL) {
                return .held(current)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let written = write(fd, base, buffer.count)
            if written != buffer.count {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return .acquired(lock)
    }

    public func release(resource: String, owner: String, force: Bool = false) throws -> CoordinatorLockReleaseResult {
        let lockURL = paths.lockFile(for: resource)
        guard let current = try loadLock(at: lockURL) else { return .notFound }
        guard force || current.owner == owner else { return .ownerMismatch(current: current) }
        try fileManager.removeItem(at: lockURL)
        return .released
    }

    public func list() throws -> [CoordinatorLock] {
        guard fileManager.fileExists(atPath: paths.locksDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: paths.locksDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try loadLock(at: $0) }
            .sorted { lhs, rhs in
                if lhs.resource == rhs.resource { return lhs.owner < rhs.owner }
                return lhs.resource < rhs.resource
            }
    }

    @discardableResult
    public func reapExpired(now: Date = Date()) throws -> [CoordinatorLock] {
        let locks = try list()
        let expired = locks.filter { $0.isExpired(now: now) }
        for lock in expired {
            try? fileManager.removeItem(at: paths.lockFile(for: lock.resource))
        }
        return expired
    }

    private func loadLock(at url: URL) throws -> CoordinatorLock? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CoordinatorLock.self, from: data)
    }

    private func encoded(_ lock: CoordinatorLock) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(lock)
    }
}
