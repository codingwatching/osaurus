//
//  NativeMessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass — pure AppKit rendering for all block types.
//  Zero NSHostingView in cell rendering paths. All content is rendered via
//  native AppKit views: NativeMarkdownView, NativeThinkingView,
//  NativeToolCallGroupView, NativeTypingIndicatorView, etc.
//

import AppKit

// MARK: - Cell Rendering Context

/// Passed to NativeMessageCellView.configure() — bundles all rendering inputs.
struct CellRenderingContext {
    let width: CGFloat
    let agentName: String
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let theme: any ThemeProtocol
    let expandedIds: Set<String>
    let onToggleExpand: (String) -> Void
    /// Called by native views after they've measured their own height.
    /// Coordinator updates heightCache and calls noteHeightOfRows if delta > 2pt.
    var onHeightMeasured: ((CGFloat, String) -> Void)? = nil
    var isTurnHovered: Bool = false
    var editingTurnId: UUID? = nil
    var editText: (() -> String, (String) -> Void)? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onCopy: ((UUID) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil
    var onEdit: ((UUID) -> Void)? = nil
    var onDelete: ((UUID) -> Void)? = nil
}

// MARK: - Cell-Isolated ExpandedBlocksStore Proxy

// MARK: - Native Header View

/// Pure AppKit header row: name label + hover-revealed action buttons.
final class NativeHeaderView: NSView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let editingBadge = NSTextField(labelWithString: "Editing")
    private let actionStack = NSStackView()
    private var isEditing = false

    private var turnId: UUID = UUID()
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    private var onEdit: ((UUID) -> Void)?
    private var onDelete: ((UUID) -> Void)?
    private var storedOnCancelEdit: (() -> Void)?
    private var currentRole: MessageRole = .assistant
    private var currentTheme: (any ThemeProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        editingBadge.translatesAutoresizingMaskIntoConstraints = false
        editingBadge.isHidden = true
        addSubview(editingBadge)

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.alignment = .centerY
        actionStack.alphaValue = 0
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            editingBadge.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            editingBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        turnId: UUID,
        role: MessageRole,
        name: String,
        isEditing: Bool,
        isHovered: Bool,
        theme: any ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
        onCancelEdit: (() -> Void)?
    ) {
        self.turnId = turnId
        self.isEditing = isEditing
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.storedOnCancelEdit = onCancelEdit
        self.currentRole = role
        self.currentTheme = theme

        nameLabel.stringValue = name
        nameLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) + 1, weight: .semibold)
        nameLabel.textColor = role == .user ? NSColor(theme.accentColor) : NSColor(theme.secondaryText)

        editingBadge.stringValue = "Editing"
        editingBadge.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        editingBadge.textColor = NSColor(theme.accentColor).withAlphaComponent(0.7)
        editingBadge.isHidden = !isEditing

        rebuildActionButtons(role: role, theme: theme, onCancelEdit: onCancelEdit)
        setHovered(isHovered, animated: false)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let alpha: CGFloat = (hovered || isEditing) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                actionStack.animator().alphaValue = alpha
            }
        } else {
            actionStack.alphaValue = alpha
        }
    }

    private func rebuildActionButtons(role: MessageRole, theme: any ThemeProtocol, onCancelEdit: (() -> Void)?) {
        for v in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        addBtn(icon: "doc.on.doc", theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }

        if role == .assistant {
            addBtn(icon: "arrow.counterclockwise", theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onRegenerate?(self.turnId)
            }
        } else {
            addBtn(icon: "pencil", theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onEdit?(self.turnId)
            }
            addBtn(icon: "trash", theme: theme, tint: NSColor(theme.errorColor)) { [weak self] in
                guard let self else { return }
                self.onDelete?(self.turnId)
            }
        }

        if isEditing, let onCancelEdit {
            addBtn(icon: "xmark", theme: theme, tint: nil, action: onCancelEdit)
        }
    }

    private func addBtn(icon: String, theme: any ThemeProtocol, tint: NSColor?, action: @escaping () -> Void) {
        let btn = ActionButton(action: action)
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.contentTintColor = tint ?? NSColor(theme.secondaryText)
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 22),
            btn.heightAnchor.constraint(equalToConstant: 22),
        ])
        actionStack.addArrangedSubview(btn)
    }
}

// MARK: - ActionButton

private final class ActionButton: NSButton {
    private let block: () -> Void
    init(action: @escaping () -> Void) {
        self.block = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}

// MARK: - NativeMessageCellView

final class NativeMessageCellView: NSTableCellView {

    // MARK: Subviews

    private var spacerView: NSView?
    private var nativeHeaderView: NativeHeaderView?

    // Native views (no NSHostingView)
    private var nativeMarkdownView: NativeMarkdownView?
    private var nativeThinkingView: NativeThinkingView?
    private var nativeToolCallGroupView: NativeToolCallGroupView?
    private var userMessageContainer: NSView?
    private var userTextView: NativeMarkdownView?
    private var userImageStack: NSStackView?
    private var nativePendingView: NativePendingToolCallView?
    private var nativeTypingView: NativeTypingIndicatorView?
    private var nativeArtifactView: NativeArtifactCardView?
    private var nativePreflightView: NativePreflightCapabilitiesView?

    // MARK: State

    private var currentKindTag: ContentBlockKindTag?
    private var currentBlockId: String?

    // MARK: Identity

    static let reuseId = NSUserInterfaceItemIdentifier("NativeMessageCell")

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(block: ContentBlock, context: CellRenderingContext) {
        let tag = block.kind.kindTag
        let sameKind = tag == currentKindTag
        currentKindTag = tag
        currentBlockId = block.id

        switch block.kind {
        case .groupSpacer:
            configureAsSpacer(sameKind: sameKind)

        case let .header(role, name, _):
            configureAsHeader(block: block, role: role, name: name, context: context, sameKind: sameKind)

        case let .paragraph(_, text, isStreaming, _):
            configureAsParagraph(block: block, text: text, isStreaming: isStreaming, context: context, sameKind: sameKind)

        case let .thinking(_, text, isStreaming):
            configureAsThinking(block: block, text: text, isStreaming: isStreaming, context: context, sameKind: sameKind)

        case let .toolCallGroup(calls):
            configureAsToolCallGroup(block: block, calls: calls, context: context, sameKind: sameKind)

        case let .userMessage(text, attachments):
            configureAsUserMessage(block: block, text: text, attachments: attachments, context: context, sameKind: sameKind)

        case let .pendingToolCall(toolName, argPreview, argSize):
            configureAsPendingToolCall(block: block, toolName: toolName, argPreview: argPreview, argSize: argSize, context: context, sameKind: sameKind)

        case .typingIndicator:
            configureAsTypingIndicator(context: context, sameKind: sameKind)

        case let .sharedArtifact(artifact):
            configureAsArtifact(block: block, artifact: artifact, context: context, sameKind: sameKind)

        case let .preflightCapabilities(items):
            configureAsPreflight(block: block, items: items, context: context, sameKind: sameKind)

        default:
            // last resort: no hosted fallback — render a compact unsupported-block placeholder
            configureAsUnsupported(sameKind: sameKind)
        }
    }

    /// Direct hover update on the header row — no SwiftUI re-render needed.
    func setTurnHovered(_ hovered: Bool) {
        nativeHeaderView?.setHovered(hovered)
    }

    // MARK: - Spacer

    private func configureAsSpacer(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 16),
        ])
        spacerView = v
    }

    // MARK: - Header

    private func configureAsHeader(
        block: ContentBlock,
        role: MessageRole,
        name: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeHeaderView == nil {
            removeAllContentViews()
            let hv = NativeHeaderView()
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                hv.heightAnchor.constraint(equalToConstant: 28),
            ])
            nativeHeaderView = hv
        }

        let displayName = role == .user ? "You" : (name.isEmpty ? "Assistant" : name)
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: role,
            name: displayName,
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit
        )
    }

    // MARK: - Paragraph (native NSTextView)

    private func configureAsParagraph(
        block: ContentBlock, text: String, isStreaming: Bool,
        context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativeMarkdownView == nil {
            removeAllContentViews()
            let mv = NativeMarkdownView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            NSLayoutConstraint.activate([
                mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                mv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeMarkdownView = mv
        }
        let mv = nativeMarkdownView!
        mv.onHeightChanged = { [weak self, weak mv] in
            guard let self, let mv, let id = self.currentBlockId else { return }
            let h = mv.measuredHeight(for: context.width - 32)
            context.onHeightMeasured?(h + 8, id)
        }
        mv.configure(
            text: text,
            width: context.width - 32,
            theme: context.theme,
            cacheKey: block.id,
            isStreaming: isStreaming
        )
    }

    // MARK: - Thinking (NativeThinkingView)

    private func configureAsThinking(
        block: ContentBlock, text: String, isStreaming: Bool,
        context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativeThinkingView == nil {
            removeAllContentViews()
            let tv = NativeThinkingView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeThinkingView = tv
        }
        let tv = nativeThinkingView!
        let thinkingLen: Int?
        if case .thinking(_, _, _) = block.kind { thinkingLen = text.count }
        else { thinkingLen = nil }

        tv.configure(
            thinking: text,
            thinkingLength: thinkingLen,
            width: context.width - 32,
            isStreaming: isStreaming,
            isExpanded: context.expandedIds.contains(block.id),
            theme: context.theme,
            blockId: block.id,
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeThinkingView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let tv = self.nativeThinkingView, let id = self.currentBlockId else { return }
                let h = tv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - Tool Call Group (NativeToolCallGroupView)

    private func configureAsToolCallGroup(
        block: ContentBlock, calls: [ToolCallItem],
        context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativeToolCallGroupView == nil {
            removeAllContentViews()
            let gv = NativeToolCallGroupView()
            gv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                gv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                gv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeToolCallGroupView = gv
        }
        nativeToolCallGroupView?.configure(
            calls: calls,
            expandedIds: context.expandedIds,
            width: context.width - 32,
            theme: context.theme,
            onToggle: { id in context.onToggleExpand(id) },
            onHeightChanged: { [weak self] in
                guard let self, let gv = self.nativeToolCallGroupView, let id = self.currentBlockId else { return }
                let h = gv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - User Message (native text + image thumbnails)

    private func configureAsUserMessage(
        block: ContentBlock, text: String, attachments: [Attachment],
        context: CellRenderingContext, sameKind: Bool
    ) {
        let images = attachments.filter(\.isImage)
        let theme = context.theme
        let innerWidth = max(context.width - 32, 100)

        if !sameKind || userMessageContainer == nil {
            removeAllContentViews()

            // container fills the cell — height is owned by the height delegate
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.masksToBounds = false // prevent border clipping
            addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            userMessageContainer = container

            // "You" header inside the bubble (matches SwiftUI HeaderBlockContent behavior)
            let hv = NativeHeaderView()
            hv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                hv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                hv.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                hv.heightAnchor.constraint(equalToConstant: 24),
            ])
            nativeHeaderView = hv

            if !text.isEmpty {
                let mv = NativeMarkdownView()
                mv.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(mv)
                // NMV inset inside bubble
                NSLayoutConstraint.activate([
                    mv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                    mv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                    mv.topAnchor.constraint(equalTo: hv.bottomAnchor, constant: 4),
                ])
                userTextView = mv
            }

            if !images.isEmpty {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                let anchor = userTextView.map { $0.bottomAnchor } ?? hv.bottomAnchor as NSLayoutYAxisAnchor
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                    stack.topAnchor.constraint(equalTo: anchor, constant: 8),
                    stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                    stack.heightAnchor.constraint(equalToConstant: 96),
                ])
                userImageStack = stack
            }
        }

        // apply bubble background + border on every configure pass (theme may change)
        if let container = userMessageContainer {
            let radius = CGFloat(theme.bubbleCornerRadius)
            let bubbleColor: NSColor = {
                if let c = theme.userBubbleColor { return NSColor(c).withAlphaComponent(theme.userBubbleOpacity) }
                return NSColor(theme.accentColor).withAlphaComponent(theme.userBubbleOpacity)
            }()
            container.layer?.cornerRadius = radius
            container.layer?.backgroundColor = bubbleColor.cgColor
            container.layer?.masksToBounds = false // don't clip border
            let borderColor: NSColor = theme.showEdgeLight
                ? NSColor(theme.glassEdgeLight)
                : NSColor(theme.primaryBorder).withAlphaComponent(theme.borderOpacity)
            container.layer?.borderWidth = CGFloat(theme.messageBorderWidth)
            container.layer?.borderColor = borderColor.cgColor
        }

        // update "You" header
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: .user,
            name: "You",
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: theme,
            onCopy: context.onCopy,
            onRegenerate: nil,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit
        )

        if let mv = userTextView, !text.isEmpty {
            // header = 10 top + 24 label + 4 gap = 38pt; text below; 16pt bottom breathing room
            mv.onHeightChanged = { [weak self] in
                guard let self, let id = self.currentBlockId else { return }
                let textH = self.userTextView?.measuredHeight(for: innerWidth - 24) ?? 0
                let totalH = 38 + textH + 16 + CGFloat(images.count) * 104
                context.onHeightMeasured?(totalH, id)
            }
            mv.configure(text: text, width: innerWidth - 24, theme: theme, cacheKey: block.id, isStreaming: context.isStreaming)
        }

        if let stack = userImageStack {
            while stack.arrangedSubviews.count < images.count {
                let iv = NSImageView()
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 8
                iv.layer?.masksToBounds = true
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: 96).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 96).isActive = true
                stack.addArrangedSubview(iv)
            }
            while stack.arrangedSubviews.count > images.count {
                let last = stack.arrangedSubviews.last!
                stack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }

            for (index, attachment) in images.enumerated() {
                guard let iv = stack.arrangedSubviews[index] as? NSImageView else { continue }
                let attachId = attachment.id.uuidString
                if let img = ChatImageCache.shared.cachedImage(for: attachId) {
                    iv.image = img
                } else if let data = attachment.imageData {
                    Task { @MainActor in
                        let img = await ChatImageCache.shared.decode(data, id: attachId)
                        iv.image = img
                    }
                }
            }
        }
    }

    // MARK: - PendingToolCall

    private func configureAsPendingToolCall(
        block: ContentBlock, toolName: String, argPreview: String?,
        argSize: Int, context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativePendingView == nil {
            removeAllContentViews()
            let pv = NativePendingToolCallView()
            pv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pv)
            NSLayoutConstraint.activate([
                pv.leadingAnchor.constraint(equalTo: leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: trailingAnchor),
                pv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativePendingView = pv
        }
        nativePendingView?.configure(toolName: toolName, argPreview: argPreview, argSize: argSize, theme: context.theme)
    }

    // MARK: - TypingIndicator

    private func configureAsTypingIndicator(context: CellRenderingContext, sameKind: Bool) {
        if !sameKind || nativeTypingView == nil {
            removeAllContentViews()
            let tv = NativeTypingIndicatorView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                tv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                tv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
            nativeTypingView = tv
        }
        nativeTypingView?.configure(theme: context.theme)
    }

    // MARK: - SharedArtifact

    private func configureAsArtifact(
        block: ContentBlock, artifact: SharedArtifact,
        context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativeArtifactView == nil {
            removeAllContentViews()
            let av = NativeArtifactCardView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                av.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                av.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
            nativeArtifactView = av
        }
        nativeArtifactView?.configure(artifact: artifact, theme: context.theme)
    }

    // MARK: - PreflightCapabilities

    private func configureAsPreflight(
        block: ContentBlock, items: [PreflightCapabilityItem],
        context: CellRenderingContext, sameKind: Bool
    ) {
        if !sameKind || nativePreflightView == nil {
            removeAllContentViews()
            let pfv = NativePreflightCapabilitiesView()
            pfv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pfv)
            NSLayoutConstraint.activate([
                pfv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                pfv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                pfv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                pfv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
            nativePreflightView = pfv
        }
        nativePreflightView?.configure(items: items, theme: context.theme)
    }

    // MARK: - Unsupported (should never appear; zero-height placeholder)

    private func configureAsUnsupported(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 0),
        ])
        spacerView = v
    }

    // MARK: - Helpers

    private func removeAllContentViews() {
        spacerView?.removeFromSuperview(); spacerView = nil
        nativeHeaderView?.removeFromSuperview(); nativeHeaderView = nil
        nativeMarkdownView?.removeFromSuperview(); nativeMarkdownView = nil
        nativeThinkingView?.removeFromSuperview(); nativeThinkingView = nil
        nativeToolCallGroupView?.removeFromSuperview(); nativeToolCallGroupView = nil
        nativePendingView?.removeFromSuperview(); nativePendingView = nil
        nativeTypingView?.removeFromSuperview(); nativeTypingView = nil
        nativeArtifactView?.removeFromSuperview(); nativeArtifactView = nil
        nativePreflightView?.removeFromSuperview(); nativePreflightView = nil
        userMessageContainer?.removeFromSuperview(); userMessageContainer = nil
        userTextView = nil; userImageStack = nil
    }
}

// MARK: - ContentBlockKindTag

/// Lightweight discriminator used to detect kind changes without comparing full associated values.
enum ContentBlockKindTag: Equatable {
    case header, paragraph, toolCallGroup, thinking, userMessage, pendingToolCall
    case typingIndicator, groupSpacer, sharedArtifact, preflightCapabilities, other
}

extension ContentBlockKind {
    var kindTag: ContentBlockKindTag {
        switch self {
        case .header: return .header
        case .paragraph: return .paragraph
        case .toolCallGroup: return .toolCallGroup
        case .thinking: return .thinking
        case .userMessage: return .userMessage
        case .pendingToolCall: return .pendingToolCall
        case .typingIndicator: return .typingIndicator
        case .groupSpacer: return .groupSpacer
        case .sharedArtifact: return .sharedArtifact
        case .preflightCapabilities: return .preflightCapabilities
        }
    }
}

// MARK: - NativeCellHeightEstimator

/// Provides height estimates for rows without triggering a full SwiftUI layout pass.
/// Used by the NSTableView height delegate as a fast path.
enum NativeCellHeightEstimator {

    static func estimatedHeight(
        for block: ContentBlock,
        width: CGFloat,
        theme: any ThemeProtocol,
        isExpanded: Bool
    ) -> CGFloat {
        switch block.kind {
        case .groupSpacer:
            return 16

        case .header:
            // 12 top + 28 label + 12 bottom
            return 52

        case .typingIndicator:
            return 48

        case let .pendingToolCall(_, argPreview, _):
            return argPreview != nil ? 80 : 62

        case let .thinking(_, text, _):
            if !isExpanded { return 58 }
            let innerW = max(width - 64, 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + charsPerLine - 1) / charsPerLine)
            return 58 + min(CGFloat(lines) * 22 + 32, 356)

        case let .paragraph(_, text, _, _):
            let innerW = max(width - 32, 100)
            let cacheKey = "\(block.id)-w\(Int(innerW))"
            if let cached = ThreadCache.shared.height(for: cacheKey) {
                return cached + 24
            }
            let chars = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + chars - 1) / chars)
            return CGFloat(lines) * 22 + 24

        case let .userMessage(text, attachments):
            // header: 10 top + 24 label + 4 gap = 38pt; text below; 16pt bottom = 54pt base
            
            // "You" header
            var h: CGFloat = 38
            let innerW = max(width - 32, 100)
            if !text.isEmpty {
                let textW = innerW - 24
                let cacheKey = "\(block.id)-w\(Int(textW))"
                if let cached = ThreadCache.shared.height(for: cacheKey) {
                    h += cached + 16
                } else {
                    let chars = max(Int(textW / 7), 20)
                    let lines = max(1, (text.count + chars - 1) / chars)
                    h += CGFloat(lines) * 22 + 16
                }
            }
            h += CGFloat(attachments.filter(\.isImage).count) * 120
            return max(h, 64)

        case let .toolCallGroup(calls):
            // each row self-sizes at ~41pt (40pt header + 1pt separator)
            return CGFloat(calls.count) * 41 + 8

        default:
            return 80
        }
    }
}
