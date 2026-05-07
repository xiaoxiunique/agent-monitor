import SwiftUI

struct MonitorView: View {
    @Environment(MonitorStore.self) private var store
    @State private var showingSettings = false

    private let columns = [
        GridItem(.adaptive(minimum: 260), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.allPanes) { pane in
                        NavigationLink {
                            PaneDetailView(pane: pane)
                        } label: {
                            PaneGridItem(pane: pane)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .overlay {
                if store.allPanes.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        "No tmux panes",
                        systemImage: "terminal",
                        description: Text(store.errorMessage ?? "Start a tmux session and check Settings.")
                    )
                    .padding()
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .refreshable {
                await store.refresh()
            }
        }
    }
}

private struct PaneGridItem: View {
    let pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                StatusDot(status: pane.status)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.displayName)
                        .font(.headline)
                        .lineLimit(2)

                    Text("\(pane.command.isEmpty ? "shell" : pane.command) · \(pane.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            Text(pane.recentLines.isEmpty ? pane.path : pane.recentLines)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text(pane.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(pane.status))
                Spacer()
                Text(pane.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusColor(pane.status).opacity(0.28), lineWidth: 1)
        )
    }
}

private struct StatusDot: View {
    let status: PaneStatus

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 10, height: 10)
            .padding(.top, 5)
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
