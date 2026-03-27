//
//  MessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass that hosts a SwiftUI ContentBlockView
//  via NSHostingView. Supports efficient cell reuse: on reconfiguration
//  we update `rootView` in place rather than tearing down the hosting view.
//
//  Row heights are derived automatically via `usesAutomaticRowHeights`
//  on the table view -- the hosting view's intrinsic content size drives
//  the row height through pinned Auto Layout constraints.
//
//  AnyView is intentionally avoided: CellRootView is a concrete typed
//  wrapper so SwiftUI can use ContentBlockView's Equatable conformance
//  to skip re-renders when the block content has not changed.
//

import AppKit
import SwiftUI

// MARK: - CellRootView

/// Thin typed wrapper around ContentBlockView. Using a concrete type rather
/// than AnyView lets SwiftUI apply ContentBlockView's Equatable conformance
/// and skip layout/render passes when block content is unchanged.
struct CellRootView: View {
    var block: ContentBlock
    var width: CGFloat
    var agentName: String
    var isTurnHovered: Bool
    var theme: ThemeProtocol
    var expandedBlocksStore: ExpandedBlocksStore
    var onCopy: ((UUID) -> Void)?
    var onRegenerate: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var editingTurnId: UUID?
    var editText: Binding<String>?
    var onConfirmEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?

    private let horizontalPadding: CGFloat = 12

    var body: some View {
        ContentBlockView(
            block: block,
            width: width - (horizontalPadding * 2),
            agentName: agentName,
            isTurnHovered: isTurnHovered,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )
        .environment(\.theme, theme)
        .environmentObject(expandedBlocksStore)
        .padding(.horizontal, horizontalPadding)
    }
}

// MARK: - MessageCellView

@MainActor
final class MessageCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MessageCellView")

    // MARK: - Private State

    /// The embedded hosting view rendering the SwiftUI content.
    private var hostingView: NSHostingView<CellRootView>?

    /// Block ID currently displayed; used to detect reuse externally.
    private(set) var blockId: String?

    /// Horizontal padding stored so CellRootView can reference the same value.
    private let horizontalPadding: CGFloat = 12

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Configuration

    /// Configure with a content block and all required rendering context.
    ///
    /// If a hosting view already exists it updates `rootView` in place,
    /// which is significantly cheaper than recreating the view hierarchy.
    /// Because `CellRootView` holds a typed `ContentBlockView` (not `AnyView`),
    /// SwiftUI can use `ContentBlockView`'s `Equatable` conformance to skip
    /// the layout pass entirely when the block content has not changed.
    func configure(
        block: ContentBlock,
        width: CGFloat,
        agentName: String,
        isTurnHovered: Bool,
        theme: ThemeProtocol,
        expandedBlocksStore: ExpandedBlocksStore,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
        editingTurnId: UUID?,
        editText: Binding<String>?,
        onConfirmEdit: (() -> Void)?,
        onCancelEdit: (() -> Void)?
    ) {
        blockId = block.id

        let rootView = CellRootView(
            block: block,
            width: width,
            agentName: agentName,
            isTurnHovered: isTurnHovered,
            theme: theme,
            expandedBlocksStore: expandedBlocksStore,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            createHostingView(rootView: rootView)
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        blockId = nil
    }

    // MARK: - Private Helpers

    private func createHostingView(rootView: CellRootView) {
        let hv = NSHostingView(rootView: rootView)
        hv.translatesAutoresizingMaskIntoConstraints = false
        hv.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(hv)

        // pin all four edges; usesAutomaticRowHeights derives row height from
        // these constraints + the hosting view's intrinsic content size.
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: topAnchor),
            hv.leadingAnchor.constraint(equalTo: leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = hv
    }
}
