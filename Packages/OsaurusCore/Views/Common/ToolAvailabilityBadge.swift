//
//  ToolAvailabilityBadge.swift
//  osaurus
//
//  Compact availability status marker shared by tool diagnostics surfaces.
//

import SwiftUI

struct ToolAvailabilityBadge: View {
    let availability: ToolAvailability

    @Environment(\.theme) private var theme

    private var tint: Color {
        switch availability.primaryReason {
        case .available, .alreadyLoaded, .loadableViaCapabilitiesLoad:
            return theme.accentColor
        case .disabled, .hiddenByAgentScope, .hiddenByExecutionMode, .notSelectedByPreflight:
            return theme.secondaryText
        case .permissionBlocked, .missingPermission, .notInstalled, .notRegistered, .pluginConfigRequired:
            return theme.warningColor
        }
    }

    var body: some View {
        Text(availability.displayLabel)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 1))
            )
            .help(availability.compactSummary)
    }
}
