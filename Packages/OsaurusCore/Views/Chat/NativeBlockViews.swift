//
//  NativeBlockViews.swift
//  osaurus
//
//  Pure AppKit views for the remaining block types that previously required
//  NSHostingView fallbacks. Zero SwiftUI in this file.
//
//    NativeTypingIndicatorView     — bouncing CALayer dots + memory label
//    NativePendingToolCallView     — pulsing dot + tool name + scrolling arg preview
//    NativeArtifactCardView        — accent strip + icon + filename/desc + thumbnail
//    NativePreflightCapabilitiesView — icon + wrapping badge chips
//

import AppKit
import QuartzCore

// MARK: - NativeTypingIndicatorView

final class NativeTypingIndicatorView: NSView {

    // MARK: Subviews

    private let dotStack = NSStackView()
    private var dots: [CALayer] = []
    private let memoryIcon = NSImageView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private var memoryStack: NSStackView?

    // MARK: Animation

    nonisolated(unsafe) private var bounceTimer: Timer?
    nonisolated(unsafe) private var memoryPollTimer: Timer?
    private var currentDot = 0
    private var cancellables: [Any] = []  // Combine sinks

    // MARK: State

    private var theme: (any ThemeProtocol)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
        startAnimation()
        observeMemory()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        bounceTimer?.invalidate()
        memoryPollTimer?.invalidate()
    }

    func configure(theme: any ThemeProtocol) {
        guard self.theme == nil || !isSameTheme(theme) else { return }
        self.theme = theme
        updateColors(theme)
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Dot container
        dotStack.orientation = .horizontal
        dotStack.spacing = 4
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotStack)

        // Create 3 dot host views (CALayer circles drawn inside)
        for _ in 0 ..< 3 {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.widthAnchor.constraint(equalToConstant: 6).isActive = true
            host.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let circle = CALayer()
            circle.cornerRadius = 3
            circle.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            circle.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
            host.layer?.addSublayer(circle)
            dotStack.addArrangedSubview(host)
            dots.append(circle)
        }

        NSLayoutConstraint.activate([
            dotStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // height is controlled by the parent cell — no fixed height constraint here
    }

    private func observeMemory() {
        memoryPollTimer?.invalidate()
        let monitor = SystemMonitorService.shared
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMemoryLabel(monitor: monitor)
            }
        }
        t.tolerance = 0.5
        memoryPollTimer = t

        updateMemoryLabel(monitor: monitor)
    }

    private func updateMemoryLabel(monitor: SystemMonitorService) {
        guard monitor.totalMemoryGB > 0 else {
            memoryStack?.isHidden = true
            return
        }
        let used = monitor.usedMemoryGB
        let total = monitor.totalMemoryGB
        memoryLabel.stringValue = String(format: "%.1f / %.0f GB", used, total)

        if memoryStack == nil {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false

            memoryIcon.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
            memoryIcon.contentTintColor = .orange
            memoryIcon.translatesAutoresizingMaskIntoConstraints = false
            memoryIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
            memoryIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

            memoryLabel.translatesAutoresizingMaskIntoConstraints = false
            memoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            memoryLabel.textColor = .orange

            stack.addArrangedSubview(memoryIcon)
            stack.addArrangedSubview(memoryLabel)
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant: 10),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            memoryStack = stack
        }
        memoryStack?.isHidden = false
    }

    private func updateColors(_ theme: any ThemeProtocol) {
        let primary = NSColor(theme.accentColor)
        let secondary = NSColor(theme.tertiaryText).withAlphaComponent(0.6)
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = (i == currentDot ? primary : secondary).cgColor
        }
    }

    private func startAnimation() {
        bounceTimer?.invalidate()
        bounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bounceDot()
            }
        }
    }

    private func bounceDot() {
        let prev = currentDot
        currentDot = (currentDot + 1) % 3

        let primary = (theme.map { NSColor($0.accentColor) }) ?? .controlAccentColor
        let secondary = NSColor.tertiaryLabelColor.withAlphaComponent(0.6)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)

        // raise current dot
        let bounce = CABasicAnimation(keyPath: "position.y")
        bounce.fromValue = dots[currentDot].position.y
        bounce.toValue = dots[currentDot].position.y + 4
        bounce.duration = 0.15
        bounce.autoreverses = true
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dots[currentDot].add(bounce, forKey: "bounce")
        dots[currentDot].backgroundColor = primary.cgColor

        // dim previous
        dots[prev].backgroundColor = secondary.cgColor

        CATransaction.commit()
    }

    private func isSameTheme(_ t: any ThemeProtocol) -> Bool {
        theme?.primaryFontName == t.primaryFontName
    }
}

// MARK: - NativePendingToolCallView

final class NativePendingToolCallView: NSView {

    // MARK: Subviews

    private let pulseLayer = CALayer()
    private let pulseHost = NSView()
    private let categoryIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let argsContainer = NSView()
    private let argsLabel = NSTextField(labelWithString: "")

    // MARK: State

    nonisolated(unsafe) private var pulseTimer: Timer?
    private var isPulseUp = false

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pulseTimer?.invalidate()
    }

    // MARK: Configure

    func configure(
        toolName: String,
        argPreview: String?,
        argSize: Int,
        theme: any ThemeProtocol
    ) {
        let category = ToolCategory.from(toolName: toolName)
        categoryIcon.image = NSImage(systemSymbolName: category.icon, accessibilityDescription: nil)
        categoryIcon.contentTintColor = NSColor(theme.secondaryText)

        nameLabel.stringValue = toolName
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor(theme.primaryText)

        if argSize > 0 {
            let kb = Double(argSize) / 1024.0
            sizeLabel.stringValue = argSize < 1024 ? "\(argSize) B" : String(format: "%.1f KB", kb)
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }
        sizeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = NSColor(theme.tertiaryText)

        pulseLayer.backgroundColor = NSColor(theme.accentColor).cgColor

        if let preview = argPreview, !preview.isEmpty {
            argsLabel.stringValue = preview
            argsLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            argsLabel.textColor = NSColor(theme.tertiaryText)
            argsContainer.isHidden = false
            argsContainer.layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.5).cgColor
        } else {
            argsContainer.isHidden = true
        }

        startPulse()
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Pulse dot host
        pulseHost.translatesAutoresizingMaskIntoConstraints = false
        pulseHost.wantsLayer = true
        pulseLayer.cornerRadius = 4
        pulseLayer.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        pulseHost.layer?.addSublayer(pulseLayer)
        addSubview(pulseHost)

        // Category icon
        categoryIcon.translatesAutoresizingMaskIntoConstraints = false
        categoryIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(categoryIcon)

        // Name label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        // Size label
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.isEditable = false
        sizeLabel.isBordered = false
        sizeLabel.drawsBackground = false
        sizeLabel.isHidden = true
        addSubview(sizeLabel)

        // Args container
        argsContainer.translatesAutoresizingMaskIntoConstraints = false
        argsContainer.wantsLayer = true
        argsContainer.layer?.cornerRadius = 4
        argsContainer.isHidden = true
        addSubview(argsContainer)

        // Args label inside container
        argsLabel.translatesAutoresizingMaskIntoConstraints = false
        argsLabel.isEditable = false
        argsLabel.isBordered = false
        argsLabel.drawsBackground = false
        argsLabel.maximumNumberOfLines = 3
        argsLabel.lineBreakMode = .byWordWrapping
        argsContainer.addSubview(argsLabel)

        let rowH: CGFloat = 32
        NSLayoutConstraint.activate([
            pulseHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pulseHost.centerYAnchor.constraint(equalTo: topAnchor, constant: rowH / 2),
            pulseHost.widthAnchor.constraint(equalToConstant: 8),
            pulseHost.heightAnchor.constraint(equalToConstant: 8),

            categoryIcon.leadingAnchor.constraint(equalTo: pulseHost.trailingAnchor, constant: 8),
            categoryIcon.centerYAnchor.constraint(equalTo: pulseHost.centerYAnchor),
            categoryIcon.widthAnchor.constraint(equalToConstant: 12),
            categoryIcon.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: categoryIcon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: pulseHost.centerYAnchor),

            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            sizeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            argsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            argsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            argsContainer.topAnchor.constraint(equalTo: topAnchor, constant: rowH + 4),
            argsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            argsContainer.heightAnchor.constraint(equalToConstant: 44),

            argsLabel.leadingAnchor.constraint(equalTo: argsContainer.leadingAnchor, constant: 8),
            argsLabel.trailingAnchor.constraint(equalTo: argsContainer.trailingAnchor, constant: -8),
            argsLabel.topAnchor.constraint(equalTo: argsContainer.topAnchor, constant: 4),
            argsLabel.bottomAnchor.constraint(lessThanOrEqualTo: argsContainer.bottomAnchor, constant: -4),
        ])
    }

    private func startPulse() {
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPulseTick()
            }
        }
    }

    private func applyPulseTick() {
        isPulseUp.toggle()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        pulseLayer.opacity = isPulseUp ? 1.0 : 0.3
        CATransaction.commit()
    }
}

// MARK: - NativeArtifactCardView

final class NativeArtifactCardView: NSView {

    // MARK: Subviews

    private let accentStrip = NSView()
    private let iconBadge = NSImageView()
    private let iconBg = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    // MARK: State

    private var currentArtifactId: String = ""

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(artifact: SharedArtifact, theme: any ThemeProtocol) {
        guard artifact.id != currentArtifactId else { return }
        currentArtifactId = artifact.id

        let accent = NSColor(theme.accentColor)
        accentStrip.layer?.backgroundColor = accent.cgColor
        layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.5).cgColor
        layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.2).cgColor

        // icon based on mime type
        let iconName = Self.iconName(for: artifact)
        iconBadge.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconBadge.contentTintColor = accent
        iconBg.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor

        nameLabel.stringValue = artifact.filename
        nameLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.bodySize), weight: .semibold)
        nameLabel.textColor = NSColor(theme.primaryText)

        typeLabel.stringValue = Self.typePill(for: artifact)
        typeLabel.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
        typeLabel.textColor = NSColor(theme.tertiaryText)

        if let desc = artifact.description, !desc.isEmpty {
            descLabel.stringValue = desc
            descLabel.isHidden = false
        } else {
            descLabel.isHidden = true
        }
        descLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1)
        descLabel.textColor = NSColor(theme.tertiaryText)

        sizeLabel.stringValue = Self.formatSize(artifact.fileSize)
        sizeLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2)
        sizeLabel.textColor = NSColor(theme.tertiaryText)

        // async thumbnail for image artifacts
        if artifact.mimeType.hasPrefix("image/") {
            thumbnailView.isHidden = false
            let hostPath = artifact.hostPath
            let artId = artifact.id
            if let img = ChatImageCache.shared.cachedImage(for: artId) {
                thumbnailView.image = img
            } else {
                Task { @MainActor in
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: hostPath)) {
                        let img = await ChatImageCache.shared.decode(data, id: artId)
                        self.thumbnailView.image = img
                    }
                }
            }
        } else {
            thumbnailView.isHidden = true
        }
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        accentStrip.translatesAutoresizingMaskIntoConstraints = false
        accentStrip.wantsLayer = true
        addSubview(accentStrip)

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.wantsLayer = true
        iconBg.layer?.cornerRadius = 8
        addSubview(iconBg)

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.imageScaling = .scaleProportionallyUpOrDown
        iconBg.addSubview(iconBadge)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        typeLabel.isEditable = false; typeLabel.isBordered = false; typeLabel.drawsBackground = false
        typeLabel.maximumNumberOfLines = 1
        addSubview(typeLabel)

        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.isEditable = false; descLabel.isBordered = false; descLabel.drawsBackground = false
        descLabel.maximumNumberOfLines = 1
        addSubview(descLabel)

        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.isEditable = false; sizeLabel.isBordered = false; sizeLabel.drawsBackground = false
        addSubview(sizeLabel)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.isHidden = true
        addSubview(thumbnailView)

        NSLayoutConstraint.activate([
            accentStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentStrip.topAnchor.constraint(equalTo: topAnchor),
            accentStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentStrip.widthAnchor.constraint(equalToConstant: 4),

            iconBg.leadingAnchor.constraint(equalTo: accentStrip.trailingAnchor, constant: 10),
            iconBg.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconBg.widthAnchor.constraint(equalToConstant: 32),
            iconBg.heightAnchor.constraint(equalToConstant: 32),

            iconBadge.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconBadge.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 16),
            iconBadge.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: iconBg.topAnchor),

            typeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            typeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            typeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            descLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 8),
            sizeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            thumbnailView.widthAnchor.constraint(equalToConstant: 80),
        ])
    }

    // MARK: - Static Helpers

    private static func iconName(for artifact: SharedArtifact) -> String {
        if artifact.isDirectory { return "folder.fill" }
        let mime = artifact.mimeType
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "video.fill" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime == "application/pdf" { return "doc.fill" }
        if mime.hasPrefix("text/") { return "doc.text.fill" }
        return "doc.fill"
    }

    private static func typePill(for artifact: SharedArtifact) -> String {
        if artifact.isDirectory { return "folder" }
        let parts = artifact.mimeType.split(separator: "/")
        return parts.last.map(String.init) ?? artifact.mimeType
    }

    private static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - NativePreflightCapabilitiesView

final class NativePreflightCapabilitiesView: NSView {

    // MARK: Subviews

    private let iconView = NSImageView()
    private let badgeContainer = NSView()  // manual wrapping layout
    private var badgeViews: [NSTextField] = []

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(items: [PreflightCapabilityItem], theme: any ThemeProtocol) {
        // choose icon
        let types = Set(items.map(\.type))
        let iconName: String
        if types.count == 1, let only = types.first { iconName = only.icon }
        else { iconName = "sparkles" }
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(theme.tertiaryText)

        // reconcile badges
        for v in badgeViews { v.removeFromSuperview() }
        badgeViews = []

        for item in items {
            let label = makeLabel(text: item.name, theme: theme)
            badgeContainer.addSubview(label)
            badgeViews.append(label)
        }

        layoutBadges()
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            badgeContainer.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            badgeContainer.topAnchor.constraint(equalTo: topAnchor),
            badgeContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        layoutBadges()
    }

    private func layoutBadges() {
        guard !badgeViews.isEmpty else { return }
        let containerWidth = badgeContainer.bounds.width
        guard containerWidth > 0 else { return }

        var x: CGFloat = 0
        var y: CGFloat = 0
        let rowH: CGFloat = 22
        let spacing: CGFloat = 4

        for label in badgeViews {
            label.sizeToFit()
            let w = label.frame.width + 16
            let h: CGFloat = rowH
            if x + w > containerWidth && x > 0 {
                x = 0
                y += rowH + spacing
            }
            label.frame = CGRect(x: x, y: y, width: w, height: h)
            x += w + spacing
        }

        let totalH = y + rowH
        if badgeContainer.frame.height != totalH {
            badgeContainer.frame.size.height = totalH
            invalidateIntrinsicContentSize()
        }
    }

    private func makeLabel(text: String, theme: any ThemeProtocol) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        label.textColor = NSColor(theme.secondaryText)
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.4).cgColor
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.3).cgColor
        return label
    }
}

// MARK: - NativeCodeBlockView

final class NativeCodeBlockView: NSView {

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sub = super.hitTest(point) { return sub }
        if NSPointInRect(point, bounds) { return self }
        return nil
    }

    // MARK: Subviews

    private let headerView = NSView()
    private let langLabel = NSTextField(labelWithString: "code")
    private let copyButton = NSButton()
    private var codeView: CodeNSTextView?
    private var codeHeightConstraint: NSLayoutConstraint?
    
    // MARK: Callback
    
    var onHeightChanged: (() -> Void)?

    // MARK: State

    private var lastCode = ""
    private var lastLang: String? = nil
    private var lastWidth: CGFloat = 0
    private var lastThemeId = ""
    private var copyResetTask: Task<Void, Never>?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(code: String, language: String?, width: CGFloat, theme: any ThemeProtocol) {
        let themeId = "\(theme.monoFontName)|\(theme.codeSize)"
        let codeChanged = code != lastCode || language != lastLang
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeId != lastThemeId

        guard codeChanged || widthChanged || themeChanged else { return }

        lastCode = code
        lastLang = language
        lastWidth = width
        lastThemeId = themeId

        langLabel.stringValue = language?.lowercased() ?? "code"
        langLabel.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        langLabel.textColor = NSColor(theme.tertiaryText)

        headerView.layer?.backgroundColor = NSColor(theme.codeBlockBackground).withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = NSColor(theme.codeBlockBackground).cgColor

        let cv = ensureCodeView(theme: theme)
        if widthChanged {
            cv.textContainer?.containerSize = NSSize(width: width - 24, height: .greatestFiniteMagnitude)
        }
        if codeChanged || themeChanged || widthChanged {
            applyHighlighting(to: cv, code: code, language: language, theme: theme)
        }
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        addSubview(headerView)

        langLabel.translatesAutoresizingMaskIntoConstraints = false
        langLabel.isEditable = false; langLabel.isBordered = false; langLabel.drawsBackground = false
        headerView.addSubview(langLabel)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = ""
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.isBordered = false
        copyButton.alphaValue = 1 // Ensure it's visible
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        headerView.addSubview(copyButton)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            langLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            langLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 20),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func ensureCodeView(theme: any ThemeProtocol) -> CodeNSTextView {
        if let cv = codeView { return cv }
        let cv = CodeNSTextView()
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.isEditable = false
        cv.isSelectable = true
        cv.isRichText = true
        cv.drawsBackground = false
        cv.backgroundColor = .clear
        cv.textContainerInset = .zero
        cv.isVerticallyResizable = false
        cv.isHorizontallyResizable = false
        cv.textContainer?.containerSize = NSSize(width: lastWidth - 24, height: .greatestFiniteMagnitude)
        cv.textContainer?.widthTracksTextView = false
        cv.textContainer?.lineFragmentPadding = 0
        cv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        cv.insertionPointColor = NSColor(theme.cursorColor)
        cv.lineNumberColor = NSColor(theme.tertiaryText).withAlphaComponent(0.4)
        addSubview(cv)
        
        let hc = cv.heightAnchor.constraint(equalToConstant: 0)
        hc.isActive = true
        codeHeightConstraint = hc
        
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cv.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            cv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        codeView = cv
        return cv
    }
    
    // provide intrinsic content size so the view can size itself
    override var intrinsicContentSize: NSSize {
        let codeHeight = codeHeightConstraint?.constant ?? 0
        let totalHeight = 28 + codeHeight + 8 // header + code + padding
        // ensure minimum visible height even if code hasn't been measured yet
        return NSSize(width: NSView.noIntrinsicMetric, height: max(totalHeight, 60))
    }

    private func applyHighlighting(
        to cv: CodeNSTextView,
        code: String,
        language: String?,
        theme: any ThemeProtocol
    ) {
        let attrStr = CodeContentView.attributedString(
            code: code,
            language: language,
            baseWidth: lastWidth - 24,
            theme: theme
        )
        cv.textStorage?.setAttributedString(attrStr)
        cv.codeFontSize = CGFloat(theme.codeSize) * 0.85
        cv.lineCount = code.components(separatedBy: "\n").count
        
        // update height constraint based on measured text height
        if let tc = cv.textContainer, let lm = cv.layoutManager {
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height)
            codeHeightConstraint?.constant = h
            // invalidate intrinsic content size so the view can resize
            invalidateIntrinsicContentSize()
            // notify parent that height has changed
            onHeightChanged?()
        }
    }

    // MARK: - Mouse tracking for copy button visibility

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 0
        }
    }

    // MARK: Actions

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastCode, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyButton.contentTintColor = .systemGreen
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            self.copyButton.contentTintColor = nil
        }
    }
}
