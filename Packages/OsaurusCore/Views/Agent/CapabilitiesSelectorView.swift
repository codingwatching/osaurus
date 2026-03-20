//
//  CapabilitiesSelectorView.swift
//  osaurus
//
//  Unified capabilities selector with tools and skills grouped by source.
//

import Combine
import SwiftUI

// MARK: - Unified Group Model

/// A single source of capabilities (plugin, MCP provider, etc.) containing
/// both tools and skills.
struct CapabilityGroup: Identifiable {
    enum Source: Hashable {
        case plugin(id: String, name: String)
        case sandboxPlugin(id: String, name: String)
        case mcpProvider(id: UUID, name: String)
        case memory
        case builtIn
        case standaloneSkills
    }

    let source: Source
    var tools: [ToolRegistry.ToolEntry]
    var skills: [Skill]
    var hasRoutes: Bool

    var id: String {
        switch source {
        case .plugin(let id, _): return "plugin-\(id)"
        case .sandboxPlugin(let id, _): return "sandbox-plugin-\(id)"
        case .mcpProvider(let id, _): return "mcp-\(id.uuidString)"
        case .memory: return "memory"
        case .builtIn: return "builtin"
        case .standaloneSkills: return "standalone-skills"
        }
    }

    var displayName: String {
        switch source {
        case .plugin(_, let name), .sandboxPlugin(_, let name), .mcpProvider(_, let name): return name
        case .memory: return "Memory"
        case .builtIn: return "Built-in"
        case .standaloneSkills: return "Skills"
        }
    }

    var icon: String {
        switch source {
        case .plugin, .sandboxPlugin: return "puzzlepiece.extension"
        case .mcpProvider: return "cloud"
        case .memory: return "brain"
        case .builtIn: return "gearshape"
        case .standaloneSkills: return "lightbulb"
        }
    }

    var pluginId: String? {
        switch source {
        case .plugin(let id, _), .sandboxPlugin(let id, _): return id
        default: return nil
        }
    }

    var totalCount: Int { tools.count + skills.count }
}

// MARK: - ViewModel

@MainActor
final class CapabilitiesSelectorViewModel: ObservableObject {
    let agentId: UUID
    let isWorkMode: Bool

    @Published private(set) var groups: [CapabilityGroup] = []
    @Published private(set) var allTools: [ToolRegistry.ToolEntry] = []
    @Published private(set) var allSkills: [Skill] = []
    @Published private(set) var rows: [CapabilityRow] = []
    @Published var searchText = ""
    @Published var expandedGroups: Set<String> = []

    private var cancellables = Set<AnyCancellable>()

    private let toolRegistry = ToolRegistry.shared
    private let skillManager = SkillManager.shared
    private let agentManager = AgentManager.shared
    private let sandboxPluginManager = SandboxPluginManager.shared

    init(agentId: UUID, isWorkMode: Bool) {
        self.agentId = agentId
        self.isWorkMode = isWorkMode

        Publishers.Merge3(
            toolRegistry.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            sandboxPluginManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Publishers.Merge(
                NotificationCenter.default.publisher(for: .toolsListChanged).map { _ in () },
                NotificationCenter.default.publisher(for: .skillsListChanged).map { _ in () }
            ).eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.rebuildCache() }
        .store(in: &cancellables)

        $searchText
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)

        rebuildCache()
    }

    // MARK: - Derived State

    var agentRestrictedTools: Set<String> {
        isWorkMode ? toolRegistry.workConflictingToolNames : []
    }

    var phasedLoading: Bool {
        ChatConfigurationStore.load().phasedContextLoading
    }

    var filteredGroups: [CapabilityGroup] {
        guard !searchText.isEmpty else { return groups }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }

        return groups.compactMap { group in
            let groupNameMatches = group.displayName.localizedCaseInsensitiveContains(query)
            let matchedTools = group.tools.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }
            let matchedSkills = group.skills.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }

            if groupNameMatches { return group }
            if !matchedTools.isEmpty || !matchedSkills.isEmpty {
                var filtered = group
                filtered.tools = matchedTools
                filtered.skills = matchedSkills
                return filtered
            }
            return nil
        }
    }

    var enabledToolCount: Int {
        allTools.filter { $0.enabled }.count
    }

    var enabledSkillCount: Int {
        allSkills.filter { isSkillEnabled($0.name) }.count
    }

    var totalEnabledCount: Int { enabledToolCount + enabledSkillCount }
    var totalCount: Int { allTools.count + allSkills.count }

    var totalTokenEstimate: Int {
        let phased = phasedLoading
        let toolTokens = allTools.filter { $0.enabled }.reduce(0) {
            $0 + (phased ? $1.catalogEntryTokens : $1.estimatedTokens)
        }
        let skillTokens = allSkills.filter { isSkillEnabled($0.name) }.reduce(0) {
            $0 + skillTokenEstimate($1)
        }
        return toolTokens + skillTokens
    }

    private let toolCountWarningThreshold = 25

    var showToolCountWarning: Bool {
        enabledToolCount >= toolCountWarningThreshold
    }

    // MARK: - Queries

    func isSkillEnabled(_ name: String) -> Bool {
        if let overrides = agentManager.effectiveSkillOverrides(for: agentId),
            let value = overrides[name]
        {
            return value
        }
        return skillManager.skill(named: name)?.enabled ?? false
    }

    func isGroupExpanded(_ groupId: String) -> Bool {
        !searchText.isEmpty || expandedGroups.contains(groupId)
    }

    func enabledCount(for group: CapabilityGroup) -> Int {
        let toolsEnabled = group.tools.filter { $0.enabled }.count
        let skillsEnabled = group.skills.filter { isSkillEnabled($0.name) }.count
        return toolsEnabled + skillsEnabled
    }

    func skillTokenEstimate(_ skill: Skill) -> Int {
        if phasedLoading {
            return max(5, (skill.name.count + skill.description.count + 6) / 4)
        }
        return max(5, (skill.name.count + skill.description.count + skill.instructions.count + 50) / 4)
    }

    var hasOverrides: Bool {
        let agent = agentManager.agent(for: agentId)
        return (agent?.enabledTools?.isEmpty == false)
            || (agent?.enabledSkills?.isEmpty == false)
            || (agent?.enabledPlugins?.isEmpty == false)
    }

    // MARK: - Actions

    func toggleTool(_ name: String, enabled: Bool) {
        agentManager.setToolEnabled(!enabled, tool: name, for: agentId)
    }

    func toggleSkill(_ name: String) {
        agentManager.setSkillEnabled(!isSkillEnabled(name), skill: name, for: agentId)
    }

    func toggleGroup(_ groupId: String) {
        expandedGroups.formSymmetricDifference([groupId])
        rebuildRows()
    }

    func enableAll() {
        let restricted = agentRestrictedTools
        for group in groups {
            if let pluginId = group.pluginId {
                agentManager.setPluginEnabled(true, plugin: pluginId, for: agentId)
            }
            agentManager.enableAllTools(
                for: agentId,
                tools: group.tools.map { $0.name }.filter { !restricted.contains($0) }
            )
            agentManager.enableAllSkills(for: agentId, skills: group.skills.map { $0.name })
        }
    }

    func disableAll() {
        for group in groups {
            if let pluginId = group.pluginId {
                agentManager.setPluginEnabled(false, plugin: pluginId, for: agentId)
            }
            agentManager.disableAllTools(for: agentId, tools: group.tools.map { $0.name })
            agentManager.disableAllSkills(for: agentId, skills: group.skills.map { $0.name })
        }
    }

    func enableAllInGroup(_ group: CapabilityGroup) {
        let restricted = agentRestrictedTools
        if let pluginId = group.pluginId {
            agentManager.setPluginEnabled(true, plugin: pluginId, for: agentId)
        }
        agentManager.enableAllTools(
            for: agentId,
            tools: group.tools.map { $0.name }.filter { !restricted.contains($0) }
        )
        agentManager.enableAllSkills(for: agentId, skills: group.skills.map { $0.name })
    }

    func disableAllInGroup(_ group: CapabilityGroup) {
        if let pluginId = group.pluginId {
            agentManager.setPluginEnabled(false, plugin: pluginId, for: agentId)
        }
        agentManager.disableAllTools(for: agentId, tools: group.tools.map { $0.name })
        agentManager.disableAllSkills(for: agentId, skills: group.skills.map { $0.name })
    }

    func resetToDefaults() {
        guard var agent = agentManager.agent(for: agentId) else { return }
        agent.enabledTools = nil
        agent.enabledSkills = nil
        agent.enabledPlugins = nil
        agentManager.update(agent)
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }

    func openManagement() {
        AppDelegate.shared?.showManagementWindow(initialTab: .tools)
    }

    // MARK: - Cache Rebuild

    private func rebuildCache() {
        let overrides = agentManager.effectiveToolOverrides(for: agentId)
        let tools = toolRegistry.listSelectableCapabilityTools(withOverrides: overrides)
        allTools = tools

        let allSkillsList = skillManager.skills
        allSkills = allSkillsList

        var builtGroups: [CapabilityGroup] = []
        var assignedToolNames: Set<String> = []
        var assignedSkillNames: Set<String> = []

        for plugin in PluginRepositoryService.shared.plugins where plugin.isInstalled {
            let pluginId = plugin.pluginId
            let displayName = plugin.displayName
            let specToolNames = (plugin.capabilities?.tools ?? []).map { $0.name }
            let matchedTools = tools.filter { specToolNames.contains($0.name) }
            let pluginSkills = skillManager.pluginSkills(for: pluginId)
            let loadedPlugin = PluginManager.shared.loadedPlugin(for: pluginId)
            let hasRoutes = !(loadedPlugin?.routes.isEmpty ?? true) || loadedPlugin?.webConfig != nil

            if !matchedTools.isEmpty || !pluginSkills.isEmpty || hasRoutes {
                builtGroups.append(
                    CapabilityGroup(
                        source: .plugin(id: pluginId, name: displayName),
                        tools: matchedTools,
                        skills: pluginSkills,
                        hasRoutes: hasRoutes
                    )
                )
                assignedToolNames.formUnion(matchedTools.map { $0.name })
                assignedSkillNames.formUnion(pluginSkills.map { $0.name })
            }
        }

        for installed in sandboxPluginManager.plugins(for: agentId.uuidString) where installed.status == .ready {
            let plugin = installed.plugin
            let matched = tools.filter {
                $0.name.hasPrefix("\(plugin.id)_") && !assignedToolNames.contains($0.name)
            }

            if !matched.isEmpty {
                builtGroups.append(
                    CapabilityGroup(
                        source: .sandboxPlugin(id: plugin.id, name: plugin.name),
                        tools: matched,
                        skills: [],
                        hasRoutes: false
                    )
                )
                assignedToolNames.formUnion(matched.map { $0.name })
            }
        }

        let providerManager = MCPProviderManager.shared
        for provider in providerManager.configuration.providers {
            guard providerManager.providerStates[provider.id]?.isConnected == true else { continue }

            let prefix =
                provider.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" } + "_"

            let matched = tools.filter { $0.name.hasPrefix(prefix) && !assignedToolNames.contains($0.name) }
            if !matched.isEmpty {
                builtGroups.append(
                    CapabilityGroup(
                        source: .mcpProvider(id: provider.id, name: provider.name),
                        tools: matched,
                        skills: [],
                        hasRoutes: false
                    )
                )
                assignedToolNames.formUnion(matched.map { $0.name })
            }
        }

        let memoryToolNames: Set<String> = [
            "search_working_memory", "search_conversations",
            "search_summaries", "search_graph",
        ]
        let memoryTools = tools.filter { memoryToolNames.contains($0.name) && !assignedToolNames.contains($0.name) }
        if !memoryTools.isEmpty {
            builtGroups.insert(
                CapabilityGroup(
                    source: .memory,
                    tools: memoryTools,
                    skills: [],
                    hasRoutes: false
                ),
                at: 0
            )
            assignedToolNames.formUnion(memoryTools.map { $0.name })
        }

        let remainingTools = tools.filter { !assignedToolNames.contains($0.name) }
        if !remainingTools.isEmpty {
            builtGroups.append(
                CapabilityGroup(
                    source: .builtIn,
                    tools: remainingTools,
                    skills: [],
                    hasRoutes: false
                )
            )
        }

        let standaloneSkills = allSkillsList.filter { !assignedSkillNames.contains($0.name) }
        if !standaloneSkills.isEmpty {
            builtGroups.append(
                CapabilityGroup(
                    source: .standaloneSkills,
                    tools: [],
                    skills: standaloneSkills,
                    hasRoutes: false
                )
            )
        }

        groups = builtGroups
        rebuildRows()
    }

    // MARK: - Flattened Rows

    private func rebuildRows() {
        var built: [CapabilityRow] = []
        let restricted = agentRestrictedTools
        let phased = phasedLoading

        for group in filteredGroups {
            let expanded = isGroupExpanded(group.id)
            let enabled = enabledCount(for: group)

            built.append(
                .groupHeader(
                    id: group.id,
                    name: group.displayName,
                    icon: group.icon,
                    enabledCount: enabled,
                    totalCount: group.totalCount,
                    isExpanded: expanded,
                    toolCount: group.tools.count,
                    skillCount: group.skills.count,
                    hasRoutes: group.hasRoutes
                )
            )

            if expanded {
                for tool in group.tools {
                    built.append(
                        .tool(
                            id: tool.name,
                            name: tool.name,
                            description: tool.description,
                            enabled: tool.enabled,
                            isAgentRestricted: restricted.contains(tool.name),
                            catalogTokens: phased ? tool.catalogEntryTokens : tool.estimatedTokens,
                            estimatedTokens: tool.estimatedTokens
                        )
                    )
                }
                for skill in group.skills {
                    let enabled = isSkillEnabled(skill.name)
                    built.append(
                        .skill(
                            id: skill.name,
                            name: skill.name,
                            description: skill.description,
                            enabled: enabled,
                            isBuiltIn: skill.isBuiltIn,
                            isFromPlugin: skill.isFromPlugin,
                            estimatedTokens: skillTokenEstimate(skill)
                        )
                    )
                }
            }
        }
        rows = built
    }
}

// MARK: - Capabilities Selector View

struct CapabilitiesSelectorView: View {
    let agentId: UUID
    var isWorkMode: Bool = false
    var isInline: Bool = false

    @StateObject private var vm: CapabilitiesSelectorViewModel

    @Environment(\.theme) private var theme

    init(agentId: UUID, isWorkMode: Bool = false, isInline: Bool = false) {
        self.agentId = agentId
        self.isWorkMode = isWorkMode
        self.isInline = isInline
        _vm = StateObject(wrappedValue: CapabilitiesSelectorViewModel(agentId: agentId, isWorkMode: isWorkMode))
    }

    // MARK: - Body

    var body: some View {
        let content = VStack(spacing: 0) {
            header
            if vm.showToolCountWarning {
                toolCountWarningBanner
            }
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if vm.rows.isEmpty {
                emptyState
            } else {
                itemList
            }
        }

        if isInline {
            content
                .frame(maxWidth: .infinity)
                .frame(height: min(CGFloat(vm.totalCount * 48 + 200), 600))
        } else {
            content
                .frame(width: 420, height: min(CGFloat(vm.totalCount * 48 + 200), 540))
                .background(popoverBackground)
                .overlay(popoverBorder)
                .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
        }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.primaryBackground)
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.primaryBorder.opacity(0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            if !isInline {
                HStack {
                    Text("Capabilities")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    if vm.totalEnabledCount > 0 {
                        HeaderTokenBadge(count: vm.totalTokenEstimate)
                    }

                    Text("\(vm.totalEnabledCount)/\(vm.totalCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(vm.showToolCountWarning ? theme.warningColor : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                vm.showToolCountWarning
                                    ? theme.warningColor.opacity(0.12)
                                    : theme.secondaryBackground
                            )
                        )
                }
            }

            HStack(spacing: 8) {
                CapabilityActionButton(title: "Enable All", action: vm.enableAll)
                CapabilityActionButton(title: "Disable All", action: vm.disableAll)

                if isInline && vm.hasOverrides {
                    CapabilityActionButton(
                        title: "Reset to Defaults",
                        icon: "arrow.uturn.backward",
                        action: vm.resetToDefaults
                    )
                }

                Spacer()

                CapabilityActionButton(
                    title: "Manage",
                    icon: "gearshape",
                    isSecondary: true,
                    action: vm.openManagement
                )
                .help("Open tools & skills management")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isInline ? 8 : 12)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            TextField("Search capabilities...", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: vm.searchText.isEmpty)
    }

    // MARK: - Tool Count Warning

    private var toolCountWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(theme.warningColor)

            Text("Too many tools may cause hallucinations and increase token usage. Disable tools you don't need.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No capabilities found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Item List

    private var itemList: some View {
        CapabilitiesTableRepresentable(
            rows: vm.rows,
            theme: theme,
            onToggleGroup: { vm.toggleGroup($0) },
            onEnableAllInGroup: { id in
                if let group = vm.groups.first(where: { $0.id == id }) {
                    vm.enableAllInGroup(group)
                }
            },
            onDisableAllInGroup: { id in
                if let group = vm.groups.first(where: { $0.id == id }) {
                    vm.disableAllInGroup(group)
                }
            },
            onToggleTool: { vm.toggleTool($0, enabled: $1) },
            onToggleSkill: { vm.toggleSkill($0) }
        )
    }
}

// MARK: - Token Badge (used in header)

private struct HeaderTokenBadge: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text("~\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("tokens").font(.system(size: 9)).opacity(0.6)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.secondaryBackground.opacity(0.5)))
    }
}

// MARK: - Action Button

private struct CapabilityActionButton: View {
    let title: String
    var icon: String? = nil
    var isSecondary: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isSecondary ? 0.5 : (isHovered ? 0.95 : 0.8)))
                    .overlay(
                        isHovered
                            ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentColor.opacity(0.08), Color.clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            : nil
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.1),
                                theme.primaryBorder.opacity(isHovered ? 0.15 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onPopoverHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var foregroundColor: Color {
        if isSecondary {
            return isHovered ? theme.accentColor : theme.secondaryText
        }
        return isHovered ? theme.accentColor : theme.primaryText
    }
}

// MARK: - Preview

#if DEBUG
    struct CapabilitiesSelectorView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            var body: some View {
                CapabilitiesSelectorView(agentId: Agent.defaultId, isWorkMode: false)
                    .padding()
                    .frame(width: 500, height: 600)
                    .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
