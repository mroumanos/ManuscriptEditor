// ActivityLog.swift
//
// One entry in the manuscript's activity log (the Log pane).  The log records
// user-visible events — every banner (success and error), manual saves,
// stamps, rollbacks, syncs, journal add/delete.  Automatic keystroke saves
// are deliberately never logged.
//
// Entries persist to `log.json` beside `manuscript.json` (not inside it, so
// version snapshots never carry the log along).

import Foundation

struct LogEntry: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case success, warning, error, info

        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            case .info:    return "info.circle.fill"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date = Date()
    var kind: Kind
    var message: String
    /// Longer context (full error text, sync details) shown when expanded.
    var detail: String? = nil
    /// Who made the change (the app-wide user identity).
    var author: String? = nil
    /// Where it happened: "Source" or the journal's name.
    var context: String? = nil
}
