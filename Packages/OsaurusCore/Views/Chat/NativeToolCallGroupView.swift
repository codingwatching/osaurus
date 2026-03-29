//
//  NativeToolCallGroupView.swift
//  osaurus
//
//  Pure AppKit replacement for GroupedToolCallsContainerView + InlineToolCallView.
//  Zero NSHostingView overhead; uses CALayer for backgrounds/borders, NSStackView
//  for rows, and NativeMarkdownView for expanded content.
//
//  Expand state is passed externally (coordinator-owned), so toggling one row
//  only invalidates the single row's height — not the entire cell.
//

import AppKit

// MARK: - ToolCategory + AppKit

extension ToolCategory {
    /// First color of the SwiftUI gradient, translated to NSColor.
    var primaryNSColor: NSColor {
        switch self {
        case .file:     return NSColor(red: 0.96, green: 0.62, blue: 0.27, alpha: 1)
        case .search:   return NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1)
        case .terminal: return NSColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1)
        case .network:  return NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        case .database: return NSColor(red: 0.93, green: 0.29, blue: 0.60, alpha: 1)
        case .code:     return NSColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1)
        case .general:  return NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        }
    }
}

// MARK: - NativeToolCallGroupView

final class NativeToolCallGroupView: NSView {

    // MARK: Subviews

    private let accentStrip = NSView()
    private let rowStack = NSStackView()
    private var rowViews: [NativeToolCallRowView] = []

    /// pins group height — intrinsic alone is not always honored when only top is pinned to the cell.
    private var groupHeightConstraint: NSLayoutConstraint?

    // MARK: State

    private var lastCallCount = 0

    // MARK: Callbacks

    var onToggle: ((String) -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(
        calls: [ToolCallItem],
        expandedIds: Set<String>,
        width: CGFloat,
        theme: any ThemeProtocol,
        onToggle: @escaping (String) -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged

        let statusColor = statusNSColor(calls: calls, theme: theme)
        accentStrip.layer?.backgroundColor = statusColor.withAlphaComponent(0.7).cgColor

        layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = statusColor.withAlphaComponent(0.25).cgColor

        while rowViews.count < calls.count {
            let row = NativeToolCallRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            rowStack.addArrangedSubview(row)
            rowViews.append(row)
        }
        while rowViews.count > calls.count {
            let removed = rowViews.removeLast()
            rowStack.removeArrangedSubview(removed)
            removed.removeFromSuperview()
        }

        let innerWidth = max(0, width - 8 - 6) // subtract accent strip + padding
        for (index, item) in calls.enumerated() {
            let row = rowViews[index]
            let isExpanded = expandedIds.contains(item.call.id)
            row.configure(
                item: item,
                index: index,
                totalCount: calls.count,
                isExpanded: isExpanded,
                width: innerWidth,
                theme: theme
            ) { [weak self] in
                self?.onToggle?(item.call.id)
            } onHeightChanged: { [weak self] in
                self?.onHeightChanged?()
            }
        }

        let totalH = measuredHeight()
        if let c = groupHeightConstraint {
            c.constant = max(totalH, 1)
        } else {
            let c = heightAnchor.constraint(equalToConstant: max(totalH, 1))
            c.priority = .required
            c.isActive = true
            groupHeightConstraint = c
        }
        invalidateIntrinsicContentSize()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        rowViews.reduce(0) { $0 + $1.measuredHeight() }
    }
    
    // provide intrinsic content size for auto layout
    override var intrinsicContentSize: NSSize {
        let height = measuredHeight()
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: - Private

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        accentStrip.translatesAutoresizingMaskIntoConstraints = false
        accentStrip.wantsLayer = true
        accentStrip.layer?.cornerRadius = 2
        addSubview(accentStrip)

        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            // accentStrip tracks rowStack height (not the group view's total height)
            accentStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            accentStrip.topAnchor.constraint(equalTo: topAnchor),
            accentStrip.bottomAnchor.constraint(equalTo: rowStack.bottomAnchor),
            accentStrip.widthAnchor.constraint(equalToConstant: 3),

            rowStack.leadingAnchor.constraint(equalTo: accentStrip.trailingAnchor, constant: 5),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func statusNSColor(calls: [ToolCallItem], theme: any ThemeProtocol) -> NSColor {
        if calls.contains(where: { $0.result == nil }) {
            return NSColor(theme.accentColor)
        } else if calls.contains(where: { $0.result?.hasPrefix("[REJECTED]") == true }) {
            return NSColor(theme.errorColor)
        } else {
            return NSColor(theme.successColor)
        }
    }
}

// MARK: - NativeToolCallRowView

final class NativeToolCallRowView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    private let statusIcon = NSImageView()
    private let categoryIcon = NSImageView()
    private let categoryBg = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let argPreviewLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    // Expanded content
    private let contentContainer = NSView()
    private var argsView: NativeMarkdownView?
    private var resultView: NativeMarkdownView?
    private let separatorView = NSView()

    // MARK: Self-sizing height constraint

    private var rowHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var cachedArgs: String?
    private var currentItemId: String = ""
    private var currentWidth: CGFloat = 0

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(
        item: ToolCallItem,
        index: Int,
        totalCount: Int,
        isExpanded: Bool,
        width: CGFloat,
        theme: any ThemeProtocol,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let isNew = item.call.id != currentItemId
        currentItemId = item.call.id

        let (statusImg, statusColor) = statusInfo(item: item, theme: theme)
        statusIcon.image = NSImage(systemSymbolName: statusImg, accessibilityDescription: nil)
        statusIcon.contentTintColor = statusColor

        let category = ToolCategory.from(toolName: item.call.function.name)
        categoryIcon.image = NSImage(systemSymbolName: category.icon, accessibilityDescription: nil)
        let tintColor = category.primaryNSColor
        categoryIcon.contentTintColor = tintColor
        categoryBg.layer?.backgroundColor = tintColor.withAlphaComponent(0.15).cgColor

        nameLabel.stringValue = item.call.function.name
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor(theme.primaryText)

        if let preview = PreviewGenerator.jsonPreview(item.call.function.arguments, maxLength: 80) {
            argPreviewLabel.stringValue = preview
            argPreviewLabel.isHidden = false
        } else {
            argPreviewLabel.isHidden = true
        }
        argPreviewLabel.font = NSFont.systemFont(ofSize: 11)
        argPreviewLabel.textColor = NSColor(theme.tertiaryText)

        updateChevron(expanded: isExpanded, animated: !isNew && isExpanded != self.isExpanded)
        self.isExpanded = isExpanded

        separatorView.isHidden = !isExpanded
        contentContainer.isHidden = !isExpanded

        if isExpanded {
            let rawArgs = item.call.function.arguments
            if isNew || cachedArgs == nil {
                let pretty = JSONFormatter.prettyJSON(rawArgs)
                cachedArgs = pretty.isEmpty ? rawArgs : pretty
            }
            if let args = cachedArgs {
                let av = ensureArgsView()
                av.configure(text: "```json\n\(args)\n```", width: width - 24, theme: theme,
                             cacheKey: "args-\(item.call.id)", isStreaming: false)
                av.onHeightChanged = { [weak self] in self?.applyHeight() }
            }
            if let result = item.result {
                let displayResult = result.hasPrefix("[REJECTED]") ? result : result
                let rv = ensureResultView()
                rv.isHidden = false
                rv.configure(text: displayResult, width: width - 24, theme: theme,
                             cacheKey: "result-\(item.call.id)", isStreaming: false)
                rv.onHeightChanged = { [weak self] in self?.applyHeight() }
            } else {
                resultView?.isHidden = true
            }
        }

        applyHeight()

        // row separator (hidden for last row)
        if let sep = subviews.last, sep.identifier?.rawValue == "rowSep" {
            sep.isHidden = index >= totalCount - 1
        }
    }

    // MARK: Measured height

    func measuredHeight() -> CGFloat {
        let rowH: CGFloat = 40
        guard isExpanded else { return rowH + 1 }  // 40pt header + 1pt separator line at bottom
        let argsH = argsView?.measuredHeight(for: currentWidth - 24) ?? 0
        let resultH: CGFloat
        if let rv = resultView, !rv.isHidden {
            resultH = 8 + rv.measuredHeight(for: currentWidth - 24)
        } else {
            resultH = 0
        }
        return rowH + 1 + 8 + argsH + resultH + 8
    }

    // MARK: - Private

    private func applyHeight() {
        rowHeight?.constant = measuredHeight()
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // content views first (behind button)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(statusIcon)

        categoryBg.translatesAutoresizingMaskIntoConstraints = false
        categoryBg.wantsLayer = true
        categoryBg.layer?.cornerRadius = 6
        addSubview(categoryBg)

        categoryIcon.translatesAutoresizingMaskIntoConstraints = false
        categoryIcon.imageScaling = .scaleProportionallyUpOrDown
        categoryBg.addSubview(categoryIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        nameLabel.alignment = .left
        nameLabel.usesSingleLineMode = true
        // keep tool name visible — arg preview + chevron must shrink first
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        argPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        argPreviewLabel.isEditable = false; argPreviewLabel.isBordered = false
        argPreviewLabel.drawsBackground = false
        argPreviewLabel.lineBreakMode = .byTruncatingTail; argPreviewLabel.maximumNumberOfLines = 1
        argPreviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        argPreviewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(argPreviewLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(chevron)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        // header button ON TOP — transparent overlay for click handling
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false
        headerButton.target = self; headerButton.action = #selector(tapped)
        addSubview(headerButton)  // added last → front of Z-order

        let rowH: CGFloat = 40

        // self-sizing height constraint
        let h = heightAnchor.constraint(equalToConstant: rowH + 1)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        rowHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: rowH),

            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: rowH / 2),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),

            categoryBg.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            categoryBg.centerYAnchor.constraint(equalTo: statusIcon.centerYAnchor),
            categoryBg.widthAnchor.constraint(equalToConstant: 24),
            categoryBg.heightAnchor.constraint(equalToConstant: 24),

            categoryIcon.centerXAnchor.constraint(equalTo: categoryBg.centerXAnchor),
            categoryIcon.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            categoryIcon.widthAnchor.constraint(equalToConstant: 14),
            categoryIcon.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: categoryBg.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),

            argPreviewLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            argPreviewLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            argPreviewLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: rowH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
        ])

        // row separator line at bottom
        let rowSep = NSView()
        rowSep.identifier = NSUserInterfaceItemIdentifier("rowSep")
        rowSep.translatesAutoresizingMaskIntoConstraints = false
        rowSep.wantsLayer = true
        rowSep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        addSubview(rowSep)
        NSLayoutConstraint.activate([
            rowSep.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowSep.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowSep.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowSep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func ensureArgsView() -> NativeMarkdownView {
        if let v = argsView { return v }
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
        ])
        argsView = v
        return v
    }

    private func ensureResultView() -> NativeMarkdownView {
        if let v = resultView { return v }
        let av = ensureArgsView()
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 8),
        ])
        resultView = v
        return v
    }

    private func statusInfo(item: ToolCallItem, theme: any ThemeProtocol) -> (String, NSColor) {
        if item.result == nil { return ("circle.dotted", NSColor(theme.accentColor)) }
        if item.result?.hasPrefix("[REJECTED]") == true { return ("xmark.circle.fill", NSColor(theme.errorColor)) }
        return ("checkmark.circle.fill", NSColor(theme.successColor))
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        let angle: CGFloat = expanded ? .pi / 2 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            }
        } else {
            chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
    }

    @objc private func tapped() { onToggle?() }
}
