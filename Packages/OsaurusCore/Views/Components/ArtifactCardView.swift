//
//  ArtifactCardView.swift
//  osaurus
//
//  Inline card for rendering a SharedArtifact in chat and work views.
//  Supports image thumbnails, text previews, audio badges, and directories.
//

import SwiftUI

struct ArtifactCardView: View {
    let artifact: SharedArtifact

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            contentPreview
            footerRow
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.filename)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconColor.opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
        }
    }

    private var subtitleText: String {
        if artifact.isDirectory {
            return formatSize(artifact.fileSize) + " total"
        }
        if let desc = artifact.description { return desc }
        return formatSize(artifact.fileSize)
    }

    // MARK: - Content Preview

    @ViewBuilder
    private var contentPreview: some View {
        if artifact.isImage, !artifact.hostPath.isEmpty {
            imagePreview
                .padding(.top, 8)
        } else if artifact.isText, let content = artifact.content, !content.isEmpty {
            textPreview(content)
                .padding(.top, 8)
        }
    }

    private var imagePreview: some View {
        let url = URL(fileURLWithPath: artifact.hostPath)
        return Group {
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
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
                    actionButton("Open in Browser", icon: "safari") {
                        openInBrowser()
                    }
                }

                actionButton("Open in Finder", icon: "folder") {
                    openInFinder()
                }
            }
        }
        .padding(.top, 8)
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
        let url = URL(fileURLWithPath: artifact.hostPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    // MARK: - Helpers

    private var iconName: String {
        if artifact.isDirectory { return "folder.fill" }
        if artifact.isImage { return "photo" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }

    private var iconColor: Color {
        if artifact.isImage { return .purple }
        if artifact.isAudio { return .orange }
        if artifact.isHTML { return .blue }
        if artifact.isDirectory { return .cyan }
        return theme.accentColor
    }

    private var hasIndexHTML: Bool {
        guard artifact.isDirectory else { return false }
        let indexPath = URL(fileURLWithPath: artifact.hostPath).appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: indexPath.path)
    }

    @ViewBuilder
    private var cardBackground: some View {
        theme.secondaryBackground.opacity(theme.glassEnabled ? 0.6 : 1.0)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
