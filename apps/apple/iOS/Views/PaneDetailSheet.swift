import SwiftUI

struct PaneDetailView: View {
    let pane: Pane

    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: DetailTab = .actions
    @State private var inputText = ""
    @State private var vimMode = false
    @State private var showKillConfirmation = false

    private var currentPane: Pane {
        store.allPanes.first(where: { $0.id == pane.id }) ?? pane
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedTab != .terminal {
                Picker("Detail", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
            }

            Group {
                switch selectedTab {
                case .actions:
                    ActionsPaneView(
                        pane: currentPane,
                        inputText: $inputText,
                        vimMode: $vimMode,
                        showKillConfirmation: $showKillConfirmation
                    )
                case .terminal:
                    TerminalPaneView(pane: currentPane)
                case .status:
                    StatusPaneView(pane: currentPane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(selectedTab == .terminal ? Color.black : Color(.systemBackground))
        .navigationTitle(selectedTab == .terminal ? "" : currentPane.session)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selectedTab == .terminal)
        .toolbar {
            if selectedTab == .terminal {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                    }
                    .tint(.white)
                    .accessibilityLabel("Back")
                }
            }
        }
        .toolbarBackground(selectedTab == .terminal ? .hidden : .automatic, for: .navigationBar)
        .confirmationDialog(
            "Kill tmux session \(currentPane.session)?",
            isPresented: $showKillConfirmation,
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                Task {
                    await store.killSession(currentPane.session)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes every window and pane in that tmux session.")
        }
        .task(id: selectedTab) {
            guard selectedTab != .terminal else { return }
            while !Task.isCancelled {
                await store.refresh(showLoading: false)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

private struct StatusPaneView: View {
    let pane: Pane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(pane.status.title, systemImage: "circle.fill")
                        .foregroundStyle(statusColor(pane.status))
                    Spacer()
                    Text(pane.updatedAt, style: .time)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))

                MetadataGrid(pane: pane)

                Text(pane.tail.isEmpty ? "No output yet." : pane.tail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding()
        }
    }
}

private struct MetadataGrid: View {
    let pane: Pane

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetadataTile(title: "Command", value: pane.command.isEmpty ? "shell" : pane.command)
            MetadataTile(title: "Pane", value: pane.id)
            MetadataTile(title: "Target", value: pane.target)
            MetadataTile(title: "PID", value: pane.pid.map(String.init) ?? "-")
            MetadataTile(title: "Path", value: pane.path)
                .gridCellColumns(2)
        }
    }
}

private struct MetadataTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ActionsPaneView: View {
    let pane: Pane
    @Binding var inputText: String
    @Binding var vimMode: Bool
    @Binding var showKillConfirmation: Bool

    @Environment(MonitorStore.self) private var store
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LatestTerminalTail(pane: pane)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            QuickReplyComposer(
                pane: pane,
                inputText: $inputText,
                vimMode: $vimMode,
                composerFocused: $composerFocused,
                showKillConfirmation: $showKillConfirmation
            )
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct LatestTerminalTail: View {
    let pane: Pane

    private var output: String {
        pane.tail.isEmpty ? "No output yet." : pane.tail
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(pane.status))
                        .frame(width: 7, height: 7)
                    Text("latest")
                }

                Spacer()

                Text(pane.updatedAt, style: .time)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.green.opacity(0.9))
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(red: 0.03, green: 0.04, blue: 0.03))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(output)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .lineSpacing(3)
                            .foregroundStyle(Color(red: 0.86, green: 0.90, blue: 0.82))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id("tail-bottom")
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.02, green: 0.025, blue: 0.02))
                .onAppear {
                    proxy.scrollTo("tail-bottom", anchor: .bottom)
                }
                .onChange(of: pane.tail) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("tail-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.green.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct QuickReplyComposer: View {
    let pane: Pane
    @Binding var inputText: String
    @Binding var vimMode: Bool
    var composerFocused: FocusState<Bool>.Binding
    @Binding var showKillConfirmation: Bool

    @Environment(MonitorStore.self) private var store

    private let quickMessages = ["继续", "yes", "no", "done", "LGTM"]
    private let quickKeys = [
        ("Enter", "Enter"),
        ("Esc", "C-["),
        ("Ctrl-C", "C-c")
    ]

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickMessages, id: \.self) { message in
                        Button(message) {
                            Task { await store.sendText(message, to: pane, vimMode: vimMode) }
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()
                        .frame(height: 24)

                    ForEach(quickKeys, id: \.0) { title, key in
                        Button(title) {
                            Task { await store.sendKey(key, to: pane) }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive) {
                        showKillConfirmation = true
                    } label: {
                        Image(systemName: "xmark.octagon")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a quick reply", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused(composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    sendCurrentText()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Toggle("Vim mode", isOn: $vimMode)
                .font(.caption)
                .foregroundStyle(.secondary)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.thinMaterial)
    }

    private func sendCurrentText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        composerFocused.wrappedValue = false
        Task { await store.sendText(text, to: pane, vimMode: vimMode) }
    }
}
