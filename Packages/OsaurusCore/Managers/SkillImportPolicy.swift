//
//  SkillImportPolicy.swift
//  osaurus
//
//  Guardrails for importing third-party skill archives before they enter the
//  persisted skill store.
//

import Foundation

/// Import limits for a third-party skill bundle. The defaults are intentionally
/// generous for normal skill packs while still bounding the user-clicked ZIP
/// path before extraction and again before persistence.
public struct SkillImportPolicy: Sendable, Equatable {
    public static let `default` = SkillImportPolicy()

    public let maxArchiveBytes: Int64
    public let maxEntryBytes: Int64
    public let maxEntryCount: Int
    public let maxPathDepth: Int

    public init(
        maxArchiveBytes: Int64 = 50 * 1024 * 1024,
        maxEntryBytes: Int64 = 10 * 1024 * 1024,
        maxEntryCount: Int = 512,
        maxPathDepth: Int = 16
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntryBytes = maxEntryBytes
        self.maxEntryCount = maxEntryCount
        self.maxPathDepth = maxPathDepth
    }

    public func validateArchiveBeforeExtraction(_ zipURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes <= maxArchiveBytes else {
            throw SkillFileError.archiveTooLarge(limitBytes: maxArchiveBytes)
        }

        let entries = try Self.listArchiveEntries(in: zipURL)
        try validateArchiveEntries(entries)
    }

    func validateArchiveEntries(_ entries: [SkillArchiveEntry]) throws {
        guard entries.count <= maxEntryCount else {
            throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
        }

        for entry in entries {
            try validateArchivePath(entry.name)
            if !entry.isDirectory, entry.uncompressedSize > maxEntryBytes {
                throw SkillFileError.archiveEntryTooLarge(path: entry.name, limitBytes: maxEntryBytes)
            }
        }
    }

    func validateArchiveEntryNames(_ names: [String]) throws {
        try validateArchiveEntries(names.map { SkillArchiveEntry(name: $0, uncompressedSize: 0) })
    }

    public func scanExtractedTree(at rootURL: URL) throws -> SkillImportPlan {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var fileCount = 0
        var skillMarkdowns: [String] = []

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw SkillFileError.invalidSkillArchive
        }

        for case let entry as URL in enumerator {
            let relativePath = try relativePath(for: entry, in: root)
            try validateArchivePath(relativePath)

            let values = try entry.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedEntry, in: resolvedRoot) else {
                throw SkillFileError.archiveEntryEscapes(path: relativePath)
            }

            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            fileCount += 1
            guard fileCount <= maxEntryCount else {
                throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
            }

            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize <= maxEntryBytes else {
                throw SkillFileError.archiveEntryTooLarge(path: relativePath, limitBytes: maxEntryBytes)
            }

            if entry.lastPathComponent == "SKILL.md" {
                skillMarkdowns.append(relativePath)
            }
        }

        guard let selected = Self.selectedSkillMarkdown(from: skillMarkdowns) else {
            throw SkillFileError.invalidSkillArchive
        }

        let ignored = skillMarkdowns.filter { $0 != selected }.sorted()
        let skillMarkdownURL = root.appendingPathComponent(selected)
        return SkillImportPlan(
            skillMarkdownURL: skillMarkdownURL,
            skillRootURL: skillMarkdownURL.deletingLastPathComponent(),
            selectedSkillMarkdownPath: selected,
            ignoredSkillMarkdownPaths: ignored
        )
    }

    private func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard components.count <= maxPathDepth else {
            throw SkillFileError.archiveEntryTooDeep(path: path, limit: maxPathDepth)
        }
    }

    private func relativePath(for fileURL: URL, in baseDirectory: URL) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func selectedSkillMarkdown(from paths: [String]) -> String? {
        paths.min { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs < rhs
        }
    }

    private static func isContained(_ fileURL: URL, in baseDirectory: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        return fileComponents.count >= baseComponents.count
            && Array(fileComponents.prefix(baseComponents.count)) == baseComponents
    }

    private static func listArchiveEntries(in zipURL: URL) throws -> [SkillArchiveEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", zipURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SkillFileError.archiveListingFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output.split(separator: "\n").compactMap { line -> SkillArchiveEntry? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let size = Int64(parts[0]) else {
                return nil
            }
            let name = parts.dropFirst(3).joined(separator: " ")
            return SkillArchiveEntry(name: name, uncompressedSize: size)
        }
    }
}

struct SkillArchiveEntry: Sendable, Equatable {
    let name: String
    let uncompressedSize: Int64

    var isDirectory: Bool {
        name.hasSuffix("/")
    }
}

public struct SkillImportPlan: Sendable, Equatable {
    public let skillMarkdownURL: URL
    public let skillRootURL: URL
    public let selectedSkillMarkdownPath: String
    public let ignoredSkillMarkdownPaths: [String]
}

public struct SkillImportResult: Sendable, Equatable {
    public let skill: Skill
    public let notes: [String]
}
