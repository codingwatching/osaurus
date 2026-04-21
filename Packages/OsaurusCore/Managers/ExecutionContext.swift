//
//  ExecutionContext.swift
//  osaurus
//
//  Window-free execution primitive that owns a ChatSession and runs it
//  headlessly. Windows are created lazily only when needed for UI.
//
//  Used by:
//  - TaskDispatcher (scheduler / HTTP / plugin / watcher dispatch)
//  - BackgroundTaskManager.dispatchChat
//  - Future webhook handlers (headless, no UI)
//

import Foundation

/// Lightweight execution context that runs a chat task without requiring a window.
@MainActor
public final class ExecutionContext: ObservableObject {

    /// Unique identifier for this execution
    public let id: UUID

    /// Agent used for this execution
    public let agentId: UUID

    /// Display title for the execution
    public let title: String?

    let chatSession: ChatSession
    let folderBookmark: Data?

    /// Whether execution is currently in progress
    public var isExecuting: Bool { chatSession.isStreaming }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        title: String? = nil,
        folderBookmark: Data? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.folderBookmark = folderBookmark

        let session = ChatSession()
        session.agentId = agentId
        session.applyInitialModelSelection()
        if let title { session.title = title }
        self.chatSession = session
    }

    // MARK: - Execution

    /// Load picker items. Call before `start(prompt:)`.
    public func prepare() async {
        await chatSession.refreshPickerItems()
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String) async {
        await activateFolderContextIfNeeded()
        chatSession.send(prompt)
    }

    /// Resolve the stored bookmark and set the work folder context before execution.
    private func activateFolderContextIfNeeded() async {
        guard let bookmark = folderBookmark else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                print("[ExecutionContext] Folder bookmark is stale, skipping")
                return
            }
            await FolderContextService.shared.setFolder(url)
        } catch {
            print("[ExecutionContext] Failed to resolve folder bookmark: \(error)")
        }
    }

    /// Poll until execution completes or the task is cancelled.
    public func awaitCompletion() async -> DispatchResult {
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms startup grace

        while isExecuting && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms poll
        }

        if Task.isCancelled { return .cancelled }

        // Persist so the "View" toast action can reload from disk
        chatSession.save()

        return .completed(sessionId: chatSession.sessionId)
    }

    /// Stop the running execution.
    public func cancel() { chatSession.stop() }
}
