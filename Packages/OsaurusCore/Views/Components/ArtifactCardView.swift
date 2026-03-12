//
//  ArtifactCardView.swift
//  osaurus
//
//  Inline card for rendering a SharedArtifact in chat and work views.
//  Supports image thumbnails, PDF first-page previews, audio duration badges,
//  video frame thumbnails, text previews, and directories.
//
//  Performance: All previews use static NSImage thumbnails loaded asynchronously.
//  No live PDFView, AVPlayerView, or WKWebView is created inline — those live
//  only in ArtifactViewerSheet.
//

import AVFoundation
import PDFKit
import SwiftUI

struct ArtifactCardView: View {
    let artifact: SharedArtifact

    private static let thumbnailHeight: CGFloat = 160

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var showGlow = false
    @State private var loadedImage: NSImage?
    @State private var pdfThumbnail: NSImage?
    @State private var pdfPageCount: Int?
    @State private var videoThumbnail: NSImage?
    @State private var audioDuration: String?

    var body: some View {
        HStack(spacing: 0) {
            accentStrip
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                contentPreview
                footerRow
            }
            .padding(12)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    theme.primaryBorder.opacity(showGlow ? 0.35 : (isHovered ? 0.25 : 0.15)),
                    lineWidth: showGlow ? 1.5 : 1
                )
        )
        .shadow(color: showGlow ? theme.accentColor.opacity(0.12) : .clear, radius: 6, y: 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .onAppear {
            showGlow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.5)) { showGlow = false }
            }
        }
    }

    // MARK: - Accent Strip

    private var accentStrip: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 10, bottomLeading: 10),
            style: .continuous
        )
        .fill(theme.accentColor)
        .frame(width: 4)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(artifact.filename)
                        .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    typePill
                }
                if let desc = artifact.description, !desc.isEmpty {
                    Text(desc)
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
    }

    private var iconBadge: some View {
        Image(systemName: iconName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: iconGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var typePill: some View {
        Text(artifact.categoryLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground.opacity(0.6)))
    }

    // MARK: - Content Preview

    @ViewBuilder
    private var contentPreview: some View {
        if artifact.isImage, !artifact.hostPath.isEmpty {
            imagePreview.padding(.top, 8)
        } else if artifact.isPDF, !artifact.hostPath.isEmpty {
            pdfPreview.padding(.top, 8)
        } else if artifact.isVideo, !artifact.hostPath.isEmpty {
            videoPreview.padding(.top, 8)
        } else if artifact.isAudio, !artifact.hostPath.isEmpty {
            audioPreview.padding(.top, 8)
        } else if artifact.isHTML || (artifact.isDirectory && hasIndexHTML) {
            htmlBadge.padding(.top, 8)
        } else if artifact.isText, let content = artifact.content, !content.isEmpty {
            textPreview(content).padding(.top, 8)
        }
    }

    private var imagePreview: some View {
        thumbnailContainer(thumbnail: loadedImage)
            .task(id: artifact.hostPath) {
                loadedImage = NSImage(contentsOf: URL(fileURLWithPath: artifact.hostPath))
            }
    }

    private var pdfPreview: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailContainer(thumbnail: pdfThumbnail)

            if let count = pdfPageCount {
                Text("\(count) page\(count == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(6)
            }
        }
        .task(id: artifact.hostPath) {
            await loadPDFThumbnail()
        }
    }

    private var videoPreview: some View {
        ZStack {
            thumbnailContainer(thumbnail: videoThumbnail)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white, .black.opacity(0.5))
                .shadow(radius: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { openWithDefaultApp() }
        .task(id: artifact.hostPath) {
            await loadVideoThumbnail()
        }
    }

    private func thumbnailContainer(thumbnail: NSImage?) -> some View {
        ZStack {
            theme.tertiaryBackground.opacity(0.3)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var audioPreview: some View {
        HStack(spacing: 10) {
            Button {
                openWithDefaultApp()
            } label: {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .offset(x: 1)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.filename)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let dur = audioDuration {
                        Text(dur)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Text(formatSize(artifact.fileSize))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(0.4))
        )
        .task(id: artifact.hostPath) {
            await loadAudioDuration()
        }
    }

    private var htmlBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text("Web Page")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text(formatSize(artifact.fileSize))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(0.4))
        )
    }

    private func textPreview(_ content: String) -> some View {
        let lines = content.components(separatedBy: "\n").prefix(6)
        let preview = lines.joined(separator: "\n")
        return Text(preview)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.secondaryText)
            .lineLimit(6)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            Spacer()

            if !artifact.hostPath.isEmpty {
                if artifact.isHTML || (artifact.isDirectory && hasIndexHTML) {
                    actionButton("Open in Browser", icon: "safari") { openInBrowser() }
                }
                actionButton("Open in Finder", icon: "folder") { openInFinder() }
            }
        }
        .padding(.top, 8)
        .opacity(isHovered ? 1 : 0.6)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func openInFinder() {
        guard !artifact.hostPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.hostPath)])
    }

    private func openInBrowser() {
        guard !artifact.hostPath.isEmpty else { return }
        let url: URL
        if artifact.isDirectory {
            url = URL(fileURLWithPath: artifact.hostPath).appendingPathComponent("index.html")
        } else {
            url = URL(fileURLWithPath: artifact.hostPath)
        }
        NSWorkspace.shared.open(url)
    }

    private func openWithDefaultApp() {
        guard !artifact.hostPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: artifact.hostPath))
    }

    // MARK: - Helpers

    private var iconName: String {
        if artifact.isDirectory { return "folder.fill" }
        if artifact.isImage { return "photo" }
        if artifact.isPDF { return "doc.richtext.fill" }
        if artifact.isVideo { return "film" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }

    private var iconGradient: [Color] {
        if artifact.isImage { return [Color(hex: "8b5cf6"), Color(hex: "7c3aed")] }
        if artifact.isPDF { return [Color(hex: "ef4444"), Color(hex: "dc2626")] }
        if artifact.isVideo { return [Color(hex: "ec4899"), Color(hex: "db2777")] }
        if artifact.isAudio { return [Color(hex: "f59e0b"), Color(hex: "d97706")] }
        if artifact.isHTML { return [Color(hex: "3b82f6"), Color(hex: "2563eb")] }
        if artifact.isDirectory { return [Color(hex: "f59e0b"), Color(hex: "d97706")] }
        return [Color(hex: "6b7280"), Color(hex: "4b5563")]
    }

    private var hasIndexHTML: Bool {
        guard artifact.isDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: artifact.hostPath).appendingPathComponent("index.html").path
        )
    }

    @ViewBuilder
    private var cardBackground: some View {
        ZStack {
            if theme.glassEnabled {
                theme.secondaryBackground.opacity(0.5)
            } else {
                theme.secondaryBackground
            }
            if isHovered {
                theme.accentColor.opacity(0.04)
            }
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Async Thumbnail Loaders

    private func loadPDFThumbnail() async {
        let url = URL(fileURLWithPath: artifact.hostPath)
        guard let doc = PDFDocument(url: url) else { return }
        let count = doc.pageCount
        guard let page = doc.page(at: 0) else { return }
        let thumb = page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
        await MainActor.run {
            pdfThumbnail = thumb
            pdfPageCount = count
        }
    }

    private func loadVideoThumbnail() async {
        let url = URL(fileURLWithPath: artifact.hostPath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 600)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            let thumb = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { videoThumbnail = thumb }
        } catch {
            print("[ArtifactCard] Video thumbnail failed: \(error)")
        }
    }

    private func loadAudioDuration() async {
        let url = URL(fileURLWithPath: artifact.hostPath)
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return }
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            let formatted = String(format: "%d:%02d", mins, secs)
            await MainActor.run { audioDuration = formatted }
        } catch {
            print("[ArtifactCard] Audio duration failed: \(error)")
        }
    }
}
