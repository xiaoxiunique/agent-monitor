import Foundation

enum PaneStatus: String, Codable, CaseIterable, Identifiable {
    case running
    case waiting
    case idle
    case failed
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .failed: "Failed"
        case .done: "Done"
        }
    }
}

struct Pane: Codable, Identifiable, Equatable {
    let id: String
    let target: String
    let session: String
    let windowIndex: String
    let windowName: String
    let paneIndex: String
    let command: String
    let path: String
    let active: Bool
    let pid: Int?
    let title: String
    let tail: String
    let status: PaneStatus
    let reason: String
    let updatedAt: Date

    var displayName: String {
        "\(session) / \(windowName.isEmpty ? windowIndex : windowName)"
    }

    var recentLines: String {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(5).joined(separator: "\n")
    }
}

struct Snapshot: Codable, Equatable {
    let ok: Bool
    let now: Date
    let panes: [Pane]
    let error: String?
}

struct SnapshotEnvelope: Codable {
    let type: String?
    let snapshot: Snapshot?
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all
    case waiting
    case running
    case failed
    case done
    case idle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .waiting: "Waiting"
        case .running: "Running"
        case .failed: "Failed"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    func matches(_ pane: Pane) -> Bool {
        switch self {
        case .all: true
        case .waiting: pane.status == .waiting
        case .running: pane.status == .running
        case .failed: pane.status == .failed
        case .done: pane.status == .done
        case .idle: pane.status == .idle
        }
    }
}
