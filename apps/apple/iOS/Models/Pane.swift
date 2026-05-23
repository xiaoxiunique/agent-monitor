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

enum InteractionMessageRole: String, Codable, Equatable {
    case agent
    case user
    case system
}

enum InteractionMessageKind: String, Codable, Equatable {
    case summary
    case status
    case question
    case permissionRequest = "permission_request"
    case progress
    case error
    case done
    case notification
}

enum InteractionMessagePriority: String, Codable, Equatable {
    case low
    case normal
    case high
}

enum InteractionActionStyle: String, Codable, Equatable {
    case `default`
    case destructive
}

struct InteractionAction: Codable, Equatable {
    let label: String
    let payload: String
    let style: InteractionActionStyle?
}

struct InteractionSource: Codable, Equatable {
    let type: String
    let excerpt: String
}

struct InteractionMessage: Codable, Identifiable, Equatable {
    let id: String
    let paneId: String
    let role: InteractionMessageRole
    let kind: InteractionMessageKind
    let priority: InteractionMessagePriority
    let title: String
    let body: String
    let actions: [InteractionAction]?
    let source: InteractionSource?
    let createdAt: Date
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
    let messages: [InteractionMessage]?

    var displayName: String {
        "\(session) / \(windowName.isEmpty ? windowIndex : windowName)"
    }

    var recentLines: String {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(5).joined(separator: "\n")
    }

    var isCodexPane: Bool {
        let haystack = "\(session)\n\(command)\n\(title)\n\(tail)".lowercased()
        return session.hasPrefix("cx_") || haystack.contains("codex")
    }

    var sendSubmitKey: String {
        isCodexPane ? "Tab" : "Enter"
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
