//
//  NativeMarkdownView.swift
//  osaurus
//
//  Pure-AppKit markdown renderer for chat cells.
//  For content with no code blocks / images / math (the vast majority of streaming
//  paragraphs), renders directly into a SelectableNSTextView — zero NSHostingView.
//  For mixed-content segments each segment type gets its own native view.
//
//  Height lifecycle:
//  1. `configure()` sets text, optionally rebuilds attributed string.
//  2. `measuredHeight(for:)` calls layoutManager.usedRect for an exact height.
//  3. Coordinator caches the height and calls noteHeightOfRows only on delta > 2pt.
//

import AppKit

// MARK: - NativeMarkdownView

final class NativeMarkdownView: NSView {

    // MARK: Subviews

    /// Primary text view — used when all segments are plain text.
    private var textView: SelectableNSTextView?
    /// Per-segment views (code blocks, images, math blocks).
    private var segmentViews: [(view: NSView, key: String)] = []
    /// only used in mixed segment layout — needed for correct height (spacingBefore between segments).
    private var lastMixedSegments: [ContentSegment] = []
    private var heightConstraint: NSLayoutConstraint?

    // MARK: State

    private var coordinator = SelectableTextView.Coordinator()
    private var lastText: String = ""
    private var lastBlocks: [SelectableTextBlock] = []
    private var lastWidth: CGFloat = 0
    private var lastThemeFingerprint: String = ""
    private var parseTask: Task<Void, Never>?

    // MARK: Callback

    /// Called after the attributed string is set and height can be measured.
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        
        // small placeholder until configure() runs measuredHeight (pure text path used to skip that and left 100pt)
        let hc = heightAnchor.constraint(equalToConstant: 8)
        hc.isActive = true
        heightConstraint = hc
    }

    required init?(coder: NSCoder) { fatalError() }
    
    // provide intrinsic content size based on height constraint
    override var intrinsicContentSize: NSSize {
        let height = heightConstraint?.constant ?? 8
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: Configure (text-based entry point)

    func configure(
        text: String,
        width: CGFloat,
        theme: any ThemeProtocol,
        cacheKey: String?,
        isStreaming: Bool
    ) {
        let themeFingerprint = makeThemeFingerprint(theme)
        let textChanged = text != lastText
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeFingerprint != lastThemeFingerprint

        guard textChanged || widthChanged || themeChanged else { return }

        lastWidth = width
        lastThemeFingerprint = themeFingerprint

        if let cached = ThreadCache.shared.markdown(for: text) {
            applySegments(cached.segments, cacheKey: cacheKey, textChanged: textChanged || themeChanged, widthChanged: widthChanged, width: width, theme: theme)
            lastText = text
            return
        }

        let blocks = parseBlocks(text)
        let segs = groupBlocksIntoSegments(blocks)
        ThreadCache.shared.setMarkdown(blocks: blocks, segments: segs, for: text)
        applySegments(segs, cacheKey: cacheKey, textChanged: true, widthChanged: false, width: width, theme: theme)
        lastText = text
    }

    // MARK: Configure (pre-parsed blocks entry point, used by applyMixedSegments)

    func configureWithBlocks(_ blocks: [SelectableTextBlock], width: CGFloat, theme: any ThemeProtocol, cacheKey: String?) {
        let themeFingerprint = makeThemeFingerprint(theme)
        let textChanged = blocks != lastBlocks
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeFingerprint != lastThemeFingerprint

        guard textChanged || widthChanged || themeChanged else { return }

        lastWidth = width
        lastThemeFingerprint = themeFingerprint

        removeSegmentViews()
        let tv = ensureTextView(width: width, theme: theme)

        if widthChanged {
            tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        updateTextViewColors(tv, theme: theme)

        if textChanged || widthChanged || themeChanged {
            coordinator.cacheKey = cacheKey
            let stv = SelectableTextView(blocks: blocks, baseWidth: width, theme: theme)
            if !widthChanged && !lastBlocks.isEmpty {
                stv.updateTextStorageIncrementally(textView: tv, oldBlocks: lastBlocks, newBlocks: blocks, coordinator: coordinator)
            } else {
                tv.textStorage?.setAttributedString(stv.buildAttributedString(coordinator: coordinator))
            }
            lastBlocks = blocks
            tv.needsDisplay = true
        }

        // nested NativeMarkdownView (text segment inside mixed content) must update heightConstraint
        // or the default 100pt sticks and following segments overlap the text.
        _ = measuredHeight(for: width)
        onHeightChanged?()
    }

    // MARK: Height

    func measuredHeight(for width: CGFloat) -> CGFloat {
        if let tv = textView {
            tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height) + 8
            heightConstraint?.constant = max(h, 8) // ensure minimum height
            invalidateIntrinsicContentSize()
            return max(h, 8)
        }
        
        // multi segment: match applyMixedSegments — 4pt top, then each segment's spacingBefore + height.
        layoutSubtreeIfNeeded()
        var totalH: CGFloat = 4
        for seg in lastMixedSegments {
            guard let entry = segmentViews.first(where: { $0.key == seg.id }) else { continue }
            totalH += seg.spacingBefore
            totalH += measureMixedSegmentHeight(entry.view, width: width)
        }
        totalH += 4
        totalH = max(totalH, 20)

        heightConstraint?.constant = totalH
        invalidateIntrinsicContentSize()
        return totalH
    }

    private func measureMixedSegmentHeight(_ view: NSView, width: CGFloat) -> CGFloat {
        if let nmv = view as? NativeMarkdownView {
            return nmv.measuredHeight(for: width)
        }
        if let cb = view as? NativeCodeBlockView {
            cb.layoutSubtreeIfNeeded()
            let h = cb.intrinsicContentSize.height
            if h > 0 && h != NSView.noIntrinsicMetric { return h }
            return max(cb.bounds.height, 60)
        }
        if let iv = view as? NSImageView {
            return iv.bounds.height > 0 ? iv.bounds.height : 160
        }
        if let field = view as? NSTextField {
            field.layoutSubtreeIfNeeded()
            let h = field.intrinsicContentSize.height
            if h > 0 && h != NSView.noIntrinsicMetric { return h }
            return max(field.bounds.height, 24)
        }
        view.layoutSubtreeIfNeeded()
        return max(view.bounds.height, 0)
    }

    // MARK: - Private: Unified Segment Dispatch

    private func applySegments(
        _ segments: [ContentSegment],
        cacheKey: String?,
        textChanged: Bool,
        widthChanged: Bool,
        width: CGFloat,
        theme: any ThemeProtocol
    ) {
        let isPureText = segments.allSatisfy { if case .textGroup = $0.kind { return true }; return false }

        if isPureText {
            // collect all text blocks from every text-group segment
            var allBlocks: [SelectableTextBlock] = []
            for seg in segments {
                if case .textGroup(let blocks) = seg.kind { allBlocks.append(contentsOf: blocks) }
            }
            applyPureTextBlocks(allBlocks, cacheKey: cacheKey, textChanged: textChanged, widthChanged: widthChanged, width: width, theme: theme)
        } else {
            applyMixedSegments(segments, cacheKey: cacheKey, width: width, theme: theme)
        }
    }

    // MARK: - Private: Pure Text Path

    private func applyPureTextBlocks(
        _ blocks: [SelectableTextBlock],
        cacheKey: String?,
        textChanged: Bool,
        widthChanged: Bool,
        width: CGFloat,
        theme: any ThemeProtocol
    ) {
        removeSegmentViews()

        let tv = ensureTextView(width: width, theme: theme)

        if widthChanged {
            tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }

        updateTextViewColors(tv, theme: theme)

        if textChanged || widthChanged {
            coordinator.cacheKey = cacheKey
            let stv = SelectableTextView(blocks: blocks, baseWidth: width, theme: theme)
            if !widthChanged && !lastBlocks.isEmpty {
                stv.updateTextStorageIncrementally(
                    textView: tv, oldBlocks: lastBlocks, newBlocks: blocks, coordinator: coordinator
                )
            } else {
                tv.textStorage?.setAttributedString(stv.buildAttributedString(coordinator: coordinator))
            }
            lastBlocks = blocks
            tv.needsDisplay = true
        }

        // must update heightConstraint — init leaves 100pt; otherwise user bubbles stay artificially tall
        _ = measuredHeight(for: width)
        onHeightChanged?()
    }

    // MARK: - Private: Mixed Segment Path

    private func applyMixedSegments(
        _ segments: [ContentSegment],
        cacheKey: String?,
        width: CGFloat,
        theme: any ThemeProtocol
    ) {
        removeTextView()
        lastMixedSegments = segments

        let requiredKeys = segments.map { $0.id }
        // remove stale segment views
        segmentViews = segmentViews.filter { entry in
            if requiredKeys.contains(entry.key) { return true }
            entry.view.removeFromSuperview()
            return false
        }

        // this prevents conflicts as segments move or get pinned/unpinned from bottom.
        let subviewPointers = Set(subviews.map { Unmanaged.passUnretained($0).toOpaque() })
        let verticalConstraints = constraints.filter { c in
            if c.firstAttribute == .top || c.firstAttribute == .bottom {
                if let first = c.firstItem as? NSView, subviewPointers.contains(Unmanaged.passUnretained(first).toOpaque()) {
                    return true
                }
            }
            return false
        }
        removeConstraints(verticalConstraints)

        var prevAnchor: NSLayoutYAxisAnchor = topAnchor
        var prevOffset: CGFloat = 4

        for seg in segments {
            let existingEntry = segmentViews.first(where: { $0.key == seg.id })
            let segView: NSView

            switch seg.kind {
            case .textGroup(let blocks):
                // use configureWithBlocks — passes exact blocks, no re-parsing
                let mv: NativeMarkdownView
                if let existing = existingEntry?.view as? NativeMarkdownView {
                    mv = existing
                } else {
                    mv = NativeMarkdownView()
                    mv.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(mv)
                }
                mv.onHeightChanged = { [weak self] in
                    self?.onHeightChanged?()
                }
                mv.configureWithBlocks(blocks, width: width, theme: theme, cacheKey: cacheKey)
                segView = mv

            case .codeBlock(let code, let language):
                let cv: NativeCodeBlockView
                if let existing = existingEntry?.view as? NativeCodeBlockView {
                    cv = existing
                } else {
                    cv = NativeCodeBlockView()
                    cv.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(cv)
                }
                cv.onHeightChanged = { [weak self] in
                    self?.onHeightChanged?()
                }
                cv.configure(code: code, language: language, width: width, theme: theme)
                segView = cv

            case .image(let urlString, _):
                let iv: NSImageView
                if let existing = existingEntry?.view as? NSImageView {
                    iv = existing
                } else {
                    iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.wantsLayer = true
                    iv.layer?.cornerRadius = 6
                    iv.layer?.masksToBounds = true
                    iv.heightAnchor.constraint(equalToConstant: 160).isActive = true
                    addSubview(iv)
                    if let url = URL(string: urlString) {
                        Task { @MainActor in
                            if let data = try? Data(contentsOf: url),
                               let img = NSImage(data: data) { iv.image = img }
                        }
                    }
                }
                segView = iv

            case .math:
                let lv: NSTextField
                if let existing = existingEntry?.view as? NSTextField {
                    lv = existing
                } else {
                    lv = NSTextField(labelWithString: "")
                    lv.translatesAutoresizingMaskIntoConstraints = false
                    lv.isEditable = false; lv.isBordered = false; lv.drawsBackground = false
                    lv.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.codeSize), weight: .regular)
                    lv.textColor = NSColor(theme.primaryText)
                    lv.maximumNumberOfLines = 0
                    lv.lineBreakMode = .byWordWrapping
                    addSubview(lv)
                }
                if case .math(let latex) = seg.kind { lv.stringValue = latex }
                segView = lv
            }

            NSLayoutConstraint.activate([
                segView.leadingAnchor.constraint(equalTo: leadingAnchor),
                segView.trailingAnchor.constraint(equalTo: trailingAnchor),
                segView.topAnchor.constraint(equalTo: prevAnchor, constant: prevOffset + seg.spacingBefore),
            ])
            
            if existingEntry == nil {
                segmentViews.append((view: segView, key: seg.id))
            }

            prevAnchor = segView.bottomAnchor
            prevOffset = 0
        }
        _ = measuredHeight(for: width)
        onHeightChanged?()
    }

    // MARK: - Private: Text View

    private func ensureTextView(width: CGFloat, theme: any ThemeProtocol) -> SelectableNSTextView {
        if let tv = textView { return tv }

        let tv = SelectableNSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.translatesAutoresizingMaskIntoConstraints = false

        updateTextViewColors(tv, theme: theme)

        addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor),
            tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])

        self.textView = tv
        return tv
    }

    private func updateTextViewColors(_ tv: SelectableNSTextView, theme: any ThemeProtocol) {
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        tv.insertionPointColor = NSColor(theme.cursorColor)
        tv.accentColor = NSColor(theme.accentColor)
        tv.blockquoteBarColor = NSColor(theme.accentColor).withAlphaComponent(0.6)
        tv.secondaryBackgroundColor = NSColor(theme.secondaryBackground)
    }

    private func scheduleBackgroundParse(text: String) {
        parseTask?.cancel()
        parseTask = Task {
            let (blocks, segs) = await Task.detached(priority: .userInitiated) {
                let b = parseBlocks(text)
                return (b, groupBlocksIntoSegments(b))
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                ThreadCache.shared.setMarkdown(blocks: blocks, segments: segs, for: text)
            }
        }
    }

    // MARK: - Cleanup

    private func removeTextView() {
        textView?.removeFromSuperview()
        textView = nil
        lastBlocks = []
    }

    private func removeSegmentViews() {
        for entry in segmentViews { entry.view.removeFromSuperview() }
        segmentViews = []
        lastMixedSegments = []
    }

    // MARK: - Theme Fingerprint

    private func makeThemeFingerprint(_ theme: any ThemeProtocol) -> String {
        "\(theme.primaryFontName)|\(theme.bodySize)|\(theme.codeSize)"
    }
}
