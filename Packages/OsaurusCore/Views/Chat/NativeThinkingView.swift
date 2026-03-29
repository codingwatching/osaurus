//
//  NativeThinkingView.swift
//  osaurus
//
//  Pure AppKit thinking/reasoning disclosure block.
//  Replaces the SwiftUI ThinkingBlockView for table cells, eliminating NSHostingView
//  overhead and keeping expand/collapse height changes local to the coordinator.
//
//  Self-sizing: the view owns a selfHeight constraint (priority 750) so it can
//  report the correct height to the coordinator without a bottomAnchor pin to the cell.
//

import AppKit
import SwiftUI

// MARK: - NativeThinkingView

final class NativeThinkingView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Thinking")
    private let streamingSpinner = NSProgressIndicator()
    private let charCountLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let separatorView = NSView()
    private let contentContainer = NSView()
    private var markdownView: NativeMarkdownView?

    // MARK: Self-sizing height constraint

    private var selfHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var currentWidth: CGFloat = 0

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Colors

    private let thinkingTint = NSColor(red: 0.55, green: 0.45, blue: 0.85, alpha: 1)

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(
        thinking: String,
        thinkingLength: Int?,
        width: CGFloat,
        isStreaming: Bool,
        isExpanded: Bool,
        theme: any ThemeProtocol,
        blockId: String,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let charCount = thinkingLength ?? thinking.count

        titleLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .semibold)
        titleLabel.textColor = thinkingTint

        streamingSpinner.isHidden = !isStreaming
        if isStreaming { streamingSpinner.startAnimation(nil) } else { streamingSpinner.stopAnimation(nil) }

        charCountLabel.isHidden = isExpanded || charCount == 0
        charCountLabel.stringValue = formatCharCount(charCount)
        charCountLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
        charCountLabel.textColor = NSColor(theme.tertiaryText)

        updateChevron(expanded: isExpanded, animated: isExpanded != self.isExpanded)
        self.isExpanded = isExpanded

        layer?.backgroundColor = thinkingTint.withAlphaComponent(0.05).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = thinkingTint.withAlphaComponent(0.15).cgColor

        contentContainer.isHidden = !isExpanded
        separatorView.isHidden = !isExpanded

        if isExpanded {
            let mdv = ensureMarkdownView()
            mdv.configure(
                text: thinking,
                width: width - 28,
                theme: theme,
                cacheKey: "\(blockId)-thinking",
                isStreaming: isStreaming
            )
            mdv.onHeightChanged = { [weak self] in self?.applyHeight() }
        }

        applyHeight()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let headerH: CGFloat = 44
        // collapsed: header only — avoid reserving expanded-content slack (was +14, looked like a dead gap)
        let collapsedBottomInset: CGFloat = 4
        guard isExpanded, let mdv = markdownView else { return headerH + collapsedBottomInset }
        // minus contentContainer insets
        let contentH = mdv.measuredHeight(for: currentWidth - 28 - 28)
        return headerH + 1 + 8 + contentH + 10
    }

    // MARK: - Private

    private func applyHeight() {
        selfHeight?.constant = measuredHeight()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // icons/labels first so they're in front of the button
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)
        iconView.contentTintColor = thinkingTint
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        addSubview(titleLabel)

        streamingSpinner.translatesAutoresizingMaskIntoConstraints = false
        streamingSpinner.style = .spinning; streamingSpinner.controlSize = .small
        streamingSpinner.isIndeterminate = true; streamingSpinner.isHidden = true
        addSubview(streamingSpinner)

        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.isEditable = false; charCountLabel.isBordered = false; charCountLabel.drawsBackground = false
        addSubview(charCountLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        // header button on top — transparent overlay covering the header row for click handling
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)  // added last → front of Z-order

        let headerH: CGFloat = 44

        // self sizing height constraint (priority 750, overridden by external bottomAnchor if present)
        let h = heightAnchor.constraint(equalToConstant: headerH + 4)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        selfHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: headerH),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: topAnchor, constant: headerH / 2),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            streamingSpinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            streamingSpinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            streamingSpinner.widthAnchor.constraint(equalToConstant: 16),
            streamingSpinner.heightAnchor.constraint(equalToConstant: 16),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevronView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            charCountLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            charCountLabel.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: headerH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
        ])
    }

    private func ensureMarkdownView() -> NativeMarkdownView {
        if let mdv = markdownView { return mdv }
        let mdv = NativeMarkdownView()
        mdv.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(mdv)
        NSLayoutConstraint.activate([
            mdv.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            mdv.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            mdv.topAnchor.constraint(equalTo: contentContainer.topAnchor),
        ])
        markdownView = mdv
        return mdv
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        let angle: CGFloat = expanded ? .pi / 2 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                chevronView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            }
        } else {
            chevronView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
    }

    @objc private func headerTapped() { onToggle?() }

    private func formatCharCount(_ count: Int) -> String {
        if count < 1000 { return "\(count) chars" }
        if count < 10_000 { return String(format: "%.1fk chars", Double(count) / 1000) }
        return "\(count / 1000)k chars"
    }
}
