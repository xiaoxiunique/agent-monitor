import SwiftUI

// MARK: - Monitor View

struct MonitorView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false

    private var serverProfiles: [ServerProfile] {
        settings.serverProfiles
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AgentMonitorTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Machines")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)

                            ForEach(serverProfiles) { profile in
                                NavigationLink {
                                    ServerWorkSessionsView(profile: profile)
                                } label: {
                                    MachineCard(
                                        profile: profile,
                                        state: store.serverMonitorState(for: profile),
                                        isActive: profile.id == settings.activeServerID
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        selectServer(profile)
                                    } label: {
                                        Label("Set Active", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        await store.refresh()
                        await store.refreshAllServerStates()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .animation(.agentThemeChange, value: colorScheme)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("Agent Monitor")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Personal command center")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await store.refresh()
                    await store.refreshAllServerStates()
                }
            } label: {
                Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
            }
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func selectServer(_ profile: ServerProfile) {
        settings.selectServer(profile.id)
        Haptics.sent(success: true)
        store.start()
    }
}

private struct ServerWorkSessionsView: View {
    let profile: ServerProfile

    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var selectedPaneRoute: PaneNavigationRoute?

    private var state: ServerMonitorState {
        store.serverMonitorState(for: profile)
    }

    private var isActiveServer: Bool {
        profile.id == settings.activeServerID
    }

    private var panes: [Pane] {
        sortedWorkSessions(state.snapshot?.panes ?? [], pinned: settings.pinnedProjects)
    }

    private var hasSnapshot: Bool {
        state.snapshot != nil
    }

    private var hasConnectionProblem: Bool {
        state.connectionState == "offline" || state.connectionState == "unconfigured" || state.errorMessage != nil
    }

    var body: some View {
        ZStack {
            AgentMonitorTheme.backgroundGradient(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if panes.isEmpty && (state.isLoading || state.connectionState == "connecting") {
                    connectionCheckingState
                } else if panes.isEmpty {
                    connectionEmptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            machineStatusStrip

                            if let connectionBannerText {
                                connectionBanner(text: connectionBannerText)
                            }

                            ForEach(panes) { pane in
                                let project = AppSettings.projectName(from: pane.session)
                                Button {
                                    openWorkSession(pane)
                                } label: {
                                    PaneListItem(
                                        pane: pane,
                                        isPinned: settings.isProjectPinned(project)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { projectContextMenu(project) }
                            }

                            if !isActiveServer {
                                Label("Opening a session switches control to this machine.", systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                        .id(profile.id)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        if isActiveServer {
                            await store.refresh()
                        } else {
                            await store.refreshAllServerStates()
                        }
                    }
                }
            }
        }
        .navigationTitle(profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPaneRoute) { route in
            PaneDetailRoute(route: route)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("Configure \(profile.displayName)")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var connectionCheckingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Checking connection")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary.opacity(0.82))
            Text("Connecting to \(profile.displayName). This should resolve within a few seconds.")
                .font(.system(size: 14))
                .foregroundColor(.secondary.opacity(0.86))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)
            Spacer()
        }
    }

    @ViewBuilder
    private var connectionEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 54))
                .foregroundColor(emptyStateTint.opacity(colorScheme == .dark ? 0.72 : 0.64))
            Text(emptyStateTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary.opacity(0.82))
            Text(emptyStateDescription)
                .font(.system(size: 14))
                .foregroundColor(.secondary.opacity(0.86))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)

            HStack(spacing: 10) {
                Button {
                    retryConnection()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isLoading)

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private var connectionBannerText: String? {
        guard hasSnapshot, hasConnectionProblem else { return nil }
        if let lastSeenAt = state.lastSeenAt {
            return "Connection unavailable. Showing last snapshot from \(StableTimeFormatter.shortDateTime(lastSeenAt))."
        }
        return "Connection unavailable. Showing the last available snapshot."
    }

    private var machineStatusStrip: some View {
        HStack(spacing: 10) {
            ResourceMetricPill(title: "CPU", value: state.snapshot?.system?.cpuUsage)
            ResourceMetricPill(title: "MEM", value: state.snapshot?.system?.memoryUsage)

            Spacer(minLength: 8)

            ConnectionDot(
                state: state.connectionState,
                errorMessage: state.errorMessage,
                serverURL: profile.url,
                isLoading: state.isLoading
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AgentMonitorTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: colorScheme == .dark ? 10 : 7, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }

    private func connectionBanner(text: String) -> some View {
        Label(text, systemImage: "wifi.slash")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AgentMonitorTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.red.opacity(0.18), lineWidth: 1)
            )
    }

    private var emptyStateTitle: String {
        if hasConnectionProblem { return "Connection unavailable" }
        return "No active work"
    }

    private var emptyStateIcon: String {
        if hasConnectionProblem { return "wifi.slash" }
        return "sparkles.rectangle.stack"
    }

    private var emptyStateTint: Color {
        hasConnectionProblem ? .red : .secondary
    }

    @ViewBuilder
    private func projectContextMenu(_ project: String) -> some View {
        Button {
            settings.toggleProjectPin(project)
        } label: {
            if settings.isProjectPinned(project) {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin to Top", systemImage: "pin")
            }
        }
    }

    private var emptyStateDescription: String {
        if let errorMessage = state.errorMessage {
            return errorMessage
        }
        let serverURL = profile.trimmedURL
        if serverURL.isEmpty {
            return "Configure service URL in Settings."
        }
        return "Connected to \(profile.displayName). Start a tmux session or check that this is the same machine."
    }

    private func retryConnection() {
        if isActiveServer {
            Task {
                await store.refresh()
                await store.connectWebSocket()
            }
        } else {
            Task { await store.refreshAllServerStates() }
        }
    }

    private func selectServer(_ profile: ServerProfile) {
        settings.selectServer(profile.id)
        Haptics.sent(success: true)
        store.start()
    }

    private func openWorkSession(_ pane: Pane) {
        if !isActiveServer {
            settings.selectServer(profile.id)
            store.start()
        }
        let route = PaneNavigationRoute(
            pane: pane,
            serverIdentity: settings.activeServerIdentity,
            serverName: profile.displayName
        )
        selectedPaneRoute = route
        Haptics.sent(success: true)
    }
}

private struct PaneNavigationRoute: Identifiable, Hashable {
    let id: String
    let pane: Pane
    let serverIdentity: String
    let serverName: String

    init(pane: Pane, serverIdentity: String, serverName: String) {
        id = "\(serverIdentity)\u{1f}\(pane.id)"
        self.pane = pane
        self.serverIdentity = serverIdentity
        self.serverName = serverName
    }

    static func == (lhs: PaneNavigationRoute, rhs: PaneNavigationRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private func sortedWorkSessions(_ panes: [Pane], pinned: [String]) -> [Pane] {
    panes.sorted { a, b in
        let aPriority = workSessionPriority(a)
        let bPriority = workSessionPriority(b)
        if aPriority != bPriority { return aPriority < bPriority }

        let aProject = AppSettings.projectName(from: a.session)
        let bProject = AppSettings.projectName(from: b.session)
        let aPinned = pinned.contains(aProject)
        let bPinned = pinned.contains(bProject)

        if aPinned != bPinned { return aPinned }
        if aPinned && bPinned {
            let aIndex = pinned.firstIndex(of: aProject) ?? 0
            let bIndex = pinned.firstIndex(of: bProject) ?? 0
            if aIndex != bIndex { return aIndex < bIndex }
        }
        if aProject != bProject {
            return aProject.localizedCaseInsensitiveCompare(bProject) == .orderedAscending
        }
        if a.session.hasPrefix("cc_") && !b.session.hasPrefix("cc_") { return true }
        if !a.session.hasPrefix("cc_") && b.session.hasPrefix("cc_") { return false }
        return a.updatedAt > b.updatedAt
    }
}

private func workSessionPriority(_ pane: Pane) -> Int {
    switch pane.status {
    case .waiting: 0
    case .failed: 1
    case .running: 2
    case .done: 3
    case .idle: 4
    }
}

private struct MachineCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let profile: ServerProfile
    let state: ServerMonitorState
    let isActive: Bool

    private var panes: [Pane] {
        state.snapshot?.panes ?? []
    }

    private var waitingCount: Int {
        panes.filter { $0.status == .waiting }.count
    }

    private var failedCount: Int {
        panes.filter { $0.status == .failed }.count
    }

    private var runningCount: Int {
        panes.filter { $0.status == .running }.count
    }

    private var doneCount: Int {
        panes.filter { $0.status == .done }.count
    }

    private var headline: String {
        if waitingCount > 0 { return "\(waitingCount) waiting for you" }
        if failedCount > 0 { return "\(failedCount) need attention" }
        if runningCount > 0 { return "\(runningCount) running" }
        if doneCount > 0 { return "\(doneCount) recently done" }
        if state.connectionState == "offline" { return "Offline" }
        if state.connectionState == "unconfigured" { return "Needs setup" }
        return panes.isEmpty ? "No active work" : "\(panes.count) sessions"
    }

    private var statusTint: Color {
        if state.connectionState == "offline" || state.connectionState == "unconfigured" { return .red }
        if waitingCount > 0 { return .yellow }
        if failedCount > 0 { return .red }
        if runningCount > 0 { return .green }
        if doneCount > 0 { return .blue }
        return .secondary
    }

    private var detail: String {
        if state.connectionState == "live" || state.connectionState == "reconnecting" {
            return profile.trimmedURL.isEmpty ? "Connected" : profile.trimmedURL
        }
        if let lastSeenAt = state.lastSeenAt {
            return "Last seen \(StableTimeFormatter.shortDateTime(lastSeenAt))"
        }
        if let error = state.errorMessage, !error.isEmpty {
            return error
        }
        return profile.trimmedURL.isEmpty ? "No URL configured" : profile.trimmedURL
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(statusTint.opacity(0.13))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(statusTint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text(headline)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusTint)
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
                .padding(.top, 14)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentMonitorTheme.surface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusTint.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: colorScheme == .dark ? 12 : 8, x: 0, y: 3)
    }
}

private enum StableTimeFormatter {
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let recentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func shortDateTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return todayFormatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return recentFormatter.string(from: date)
        }
        return fullFormatter.string(from: date)
    }
}

private struct PaneDetailRoute: View {
    let route: PaneNavigationRoute
    let showsInputBar: Bool
    let showsNavigationChrome: Bool
    let terminalHorizontalPadding: CGFloat

    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var lastKnownPane: Pane?

    init(
        route: PaneNavigationRoute,
        showsInputBar: Bool = true,
        showsNavigationChrome: Bool = true,
        terminalHorizontalPadding: CGFloat = 3
    ) {
        self.route = route
        self.showsInputBar = showsInputBar
        self.showsNavigationChrome = showsNavigationChrome
        self.terminalHorizontalPadding = terminalHorizontalPadding
        _lastKnownPane = State(initialValue: route.pane)
    }

    private var isRouteActiveServer: Bool {
        settings.activeServerIdentity == route.serverIdentity
    }

    private var pane: Pane? {
        guard isRouteActiveServer else { return nil }
        return store.allPanes.first(where: { $0.id == route.pane.id })
    }

    private var displayPane: Pane? {
        pane ?? lastKnownPane
    }

    var body: some View {
        Group {
            if let displayPane {
                PaneDetailView(
                    pane: displayPane,
                    isLiveServer: isRouteActiveServer,
                    serverName: route.serverName,
                    showsInputBar: showsInputBar,
                    showsNavigationChrome: showsNavigationChrome,
                    terminalHorizontalPadding: terminalHorizontalPadding
                )
            } else {
                ContentUnavailableView(
                    "Pane closed",
                    systemImage: "terminal",
                    description: Text("This tmux pane is no longer available.")
                )
            }
        }
        .onAppear {
            rememberPaneIfAvailable(pane)
        }
        .onChange(of: isRouteActiveServer) { _, isActive in
            if isActive {
                rememberPaneIfAvailable(pane)
            }
        }
        .onChange(of: pane) { _, nextPane in
            rememberPaneIfAvailable(nextPane)
        }
    }

    private func rememberPaneIfAvailable(_ pane: Pane?) {
        guard let pane else { return }
        lastKnownPane = pane
    }
}

// MARK: - Connection Status

private struct ResourceMetricPill: View {
    let title: String
    let value: Double?

    private var displayValue: String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(displayValue)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.86))
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill), in: Capsule())
        .accessibilityLabel("\(title) \(displayValue)")
    }
}

private struct ConnectionDot: View {
    let state: String
    let errorMessage: String?
    let serverURL: String
    let isLoading: Bool

    private var trimmedURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLive: Bool {
        !trimmedURL.isEmpty && (state == "live" || state == "reconnecting")
    }

    private var isChecking: Bool {
        !trimmedURL.isEmpty && !isLive && errorMessage == nil && (state == "connecting" || state == "unknown")
    }

    private var tint: Color {
        isLive ? .green : .red
    }

    private var title: String {
        if isLive { return "Live" }
        if isChecking { return "Checking" }
        return "Offline"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, options: .repeating, value: isChecking && isLoading)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .accessibilityLabel("Connection \(title)")
    }
}

private struct ConnectionStatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: String
    let errorMessage: String?
    let serverName: String
    let serverURL: String
    let isLoading: Bool
    let onOpenSettings: () -> Void

    private var trimmedURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isProblemState: Bool {
        trimmedURL.isEmpty || state == "offline" || state == "unconfigured" || (state != "live" && errorMessage != nil)
    }

    private var isCheckingState: Bool {
        !isProblemState && (state == "connecting" || state == "reconnecting")
    }

    private var title: String {
        if trimmedURL.isEmpty || state == "unconfigured" {
            return "Server not configured"
        }
        switch state {
        case "live":
            return "Server connected"
        case "connecting":
            if errorMessage != nil { return "Server disconnected" }
            return "Checking server"
        case "reconnecting":
            if errorMessage != nil { return "Server disconnected" }
            return "Server connected"
        default:
            return "Server disconnected"
        }
    }

    private var detail: String {
        if trimmedURL.isEmpty || state == "unconfigured" {
            return "Set the Mac service URL before monitoring agents."
        }
        if let errorMessage, !errorMessage.isEmpty, state != "live" {
            return errorMessage
        }
        if serverName == trimmedURL || serverName.isEmpty {
            return trimmedURL
        }
        return "\(serverName) · \(trimmedURL)"
    }

    private var iconName: String {
        if isProblemState { return "wifi.slash" }
        if state == "live" || state == "reconnecting" { return "checkmark.circle.fill" }
        return "wifi"
    }

    private var tint: Color {
        if isProblemState { return .red }
        if state == "live" || state == "reconnecting" { return .green }
        return .secondary
    }

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, value: isCheckingState && isLoading)

                Text(compactTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AgentMonitorTheme.surface(for: colorScheme), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(isProblemState ? 0.35 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var compactTitle: String {
        if trimmedURL.isEmpty || state == "unconfigured" {
            return "Setup"
        }
        switch state {
        case "live", "reconnecting":
            return "Live"
        case "connecting":
            return errorMessage == nil ? "Checking" : "Offline"
        default:
            return "Offline"
        }
    }
}

// MARK: - Pane List Item

private struct PaneListItem: View {
    @Environment(\.colorScheme) private var colorScheme
    let pane: Pane
    let isPinned: Bool

    private var projectName: String {
        AppSettings.projectName(from: pane.session)
    }

    private var cleanTitle: String {
        // Strip leading spinner chars (braille pattern dots used by Claude Code)
        var title = pane.title
        while let first = title.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || first.value == 0x2733 || first == " " {
            title = String(title.unicodeScalars.dropFirst())
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private var displayTitle: String {
        if !cleanTitle.isEmpty && cleanTitle != pane.command {
            return cleanTitle
        }
        if !pane.command.isEmpty {
            return pane.command
        }
        return pane.session
    }

    var body: some View {
        HStack(spacing: 13) {
            AgentAvatar(session: pane.session, size: 44)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(projectName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.6))
                    }

                    Spacer()

                    Text(pane.updatedAt, style: .time)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Text(displayTitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentMonitorTheme.surface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: colorScheme == .dark ? 12 : 8, x: 0, y: 3)
    }
}

// MARK: - Agent Avatar

struct AgentAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: String
    var size: CGFloat = 48

    private enum AgentType {
        case claude, codex, generic
    }

    private var agentType: AgentType {
        if session.hasPrefix("cc_") { return .claude }
        if session.hasPrefix("cx_") { return .codex }
        return .generic
    }

    var body: some View {
        Group {
            switch agentType {
            case .claude:
                Image("claude-avatar")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.1)
                    .background(AgentMonitorTheme.elevatedSurface(for: colorScheme))
            case .codex:
                Image("codex-avatar")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.06)
                    .background(AgentMonitorTheme.elevatedSurface(for: colorScheme))
            case .generic:
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }
}

func statusColor(_ status: PaneStatus) -> Color {
    switch status {
    case .running: .green
    case .waiting: .yellow
    case .idle: .gray
    case .failed: .red
    case .done: .blue
    }
}
