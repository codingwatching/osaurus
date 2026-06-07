//
//  DocumentFormatRegistry.swift
//  osaurus
//
//  Process-wide routing table from a URL (or a `StructuredDocument`) to the
//  adapter / emitter / streamer responsible for it. Adapters are registered
//  once — at app launch for in-tree formats, at plugin load for plugin-
//  provided formats — and looked up every time a file is ingested or an
//  artifact is emitted, so the hot path here is the lookup, not registration.
//
//  Thread safety: the registry guards its internal state with an `NSLock`
//  rather than `@MainActor` isolation. Attachment ingress happens on the
//  main actor today, but the agent tool surface (PR 7 in the stage-4
//  roadmap) runs off the main actor, and we don't want every tool call to
//  pay an `await`-hop just to look up an adapter.
//

import Foundation

public enum DocumentFormatRegistrationRole: String, Codable, CaseIterable, Hashable, Sendable {
    case adapter
    case emitter
    case streamer
}

public struct DocumentFormatRegistrationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let formatId: String
    public let roles: Set<DocumentFormatRegistrationRole>

    public init(formatId: String, roles: Set<DocumentFormatRegistrationRole>) {
        self.formatId = formatId
        self.roles = roles
    }
}

public final class DocumentFormatRegistry: @unchecked Sendable {
    public static let shared = DocumentFormatRegistry()

    private let lock = NSLock()

    // Insertion order preserved; lookup walks in reverse so the most
    // recently-registered claimant wins ties. That lets a plugin override
    // a built-in for a specific URL without having to unregister first.
    private var adapters: [any DocumentFormatAdapter] = []
    private var emitters: [any DocumentFormatEmitter] = []
    private var streamersByFormatId: [String: any DocumentFormatStreamer] = [:]

    /// `public` so tests can spin up an isolated registry without touching
    /// `shared`. Production code should always use `shared`.
    public init() {}

    // MARK: - Registration

    public func register(adapter: any DocumentFormatAdapter) {
        lock.lock()
        defer { lock.unlock() }
        adapters.append(adapter)
    }

    public func register(emitter: any DocumentFormatEmitter) {
        lock.lock()
        defer { lock.unlock() }
        emitters.append(emitter)
    }

    public func register(streamer: any DocumentFormatStreamer) {
        lock.lock()
        defer { lock.unlock() }
        streamersByFormatId[streamer.formatId] = streamer
    }

    /// Removes every registration (adapter, emitter, streamer) whose
    /// `formatId` matches. Returns `true` if anything was actually removed.
    /// Used by plugin unload and by tests that want a clean slate.
    @discardableResult
    public func unregisterAll(formatId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = adapters.count + emitters.count + streamersByFormatId.count
        adapters.removeAll { $0.formatId == formatId }
        emitters.removeAll { $0.formatId == formatId }
        streamersByFormatId.removeValue(forKey: formatId)
        let after = adapters.count + emitters.count + streamersByFormatId.count
        return before != after
    }

    // MARK: - Lookup

    /// Returns the most-recently-registered adapter whose `canHandle`
    /// accepts the URL. `nil` when nothing claims it — callers can
    /// decide whether to fall through to a legacy path or throw
    /// `DocumentAdapterError.unsupportedFormat`.
    public func adapter(for url: URL, uti: String? = nil) -> (any DocumentFormatAdapter)? {
        lock.lock()
        defer { lock.unlock() }
        return adapters.reversed().first(where: { $0.canHandle(url: url, uti: uti) })
    }

    public func emitter(for document: StructuredDocument) -> (any DocumentFormatEmitter)? {
        lock.lock()
        defer { lock.unlock() }
        return emitters.reversed().first(where: { $0.canEmit(document) })
    }

    public func streamer(forFormatId id: String) -> (any DocumentFormatStreamer)? {
        lock.lock()
        defer { lock.unlock() }
        return streamersByFormatId[id]
    }

    // MARK: - Introspection

    /// Union of format ids currently registered across adapters, emitters,
    /// and streamers. Useful for plugin-host diagnostics and for tests.
    public func registeredFormatIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var ids: Set<String> = []
        for adapter in adapters { ids.insert(adapter.formatId) }
        for emitter in emitters { ids.insert(emitter.formatId) }
        for id in streamersByFormatId.keys { ids.insert(id) }
        return ids
    }

    public func registrationSnapshot() -> [DocumentFormatRegistrationSnapshot] {
        lock.lock()
        defer { lock.unlock() }

        var rolesByFormat: [String: Set<DocumentFormatRegistrationRole>] = [:]
        for adapter in adapters {
            rolesByFormat[adapter.formatId, default: []].insert(.adapter)
        }
        for emitter in emitters {
            rolesByFormat[emitter.formatId, default: []].insert(.emitter)
        }
        for formatId in streamersByFormatId.keys {
            rolesByFormat[formatId, default: []].insert(.streamer)
        }

        return rolesByFormat.keys.sorted().map { formatId in
            DocumentFormatRegistrationSnapshot(
                formatId: formatId,
                roles: rolesByFormat[formatId] ?? []
            )
        }
    }

    public func registrationRoles(forFormatId formatId: String) -> Set<DocumentFormatRegistrationRole> {
        lock.lock()
        defer { lock.unlock() }
        var roles: Set<DocumentFormatRegistrationRole> = []
        if adapters.contains(where: { $0.formatId == formatId }) { roles.insert(.adapter) }
        if emitters.contains(where: { $0.formatId == formatId }) { roles.insert(.emitter) }
        if streamersByFormatId[formatId] != nil { roles.insert(.streamer) }
        return roles
    }
}
