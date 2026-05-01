//
//  AgentAvatarView.swift
//  osaurus
//
//  Reusable agent avatar that shows a mascot image when one is picked, and
//  falls back to the agent name's first-letter monogram otherwise.
//

import SwiftUI

/// Catalog of mascot avatars shipped with the app. The `id` is what gets
/// persisted on `Agent.avatar`. `assetName` resolves to an imageset in
/// `OsaurusCore/Resources/Assets.xcassets`
public enum AgentMascot: String, CaseIterable, Identifiable, Sendable {
    case blue, green, orange, purple, red, yellow

    public var id: String { rawValue }
    public var assetName: String { "osaurus-avatar-\(rawValue)" }

    /// Asset name for the "create-pose" illustration paired with this
    /// mascot color (used by the onboarding Create Agent step).
    ///
    /// NOTE: the yellow asset ships with a typo in the imageset name
    /// (`osuarus-yellow-create` instead of `osaurus-yellow-create`).
    /// We reference the actual filename so the image loads — rename the
    /// imageset upstream if you want to fix it.
    public var createPoseAssetName: String {
        switch self {
        case .yellow: return "osuarus-yellow-create"
        default: return "osaurus-\(rawValue)-create"
        }
    }
}

/// Renders an agent avatar at the given diameter. Uses the mascot image when
/// `mascotId` matches a known `AgentMascot` otherwise draws a tinted circle
/// with the first letter of `name` (or `?` when name is empty)
struct AgentAvatarView: View {
    let mascotId: String?
    let name: String
    let tint: Color
    let diameter: CGFloat
    /// Font size for the monogram fallback. Callers tune this so the letter
    /// reads at the same visual weight as before per call site
    var monogramFontSize: CGFloat = 16
    var borderWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.2), tint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let mascot = mascotId.flatMap(AgentMascot.init(rawValue:)) {
                Image(mascot.assetName, bundle: .module)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(diameter * 0.08)
            } else {
                Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                    .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
            }

            Circle()
                .strokeBorder(tint.opacity(0.5), lineWidth: borderWidth)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}
