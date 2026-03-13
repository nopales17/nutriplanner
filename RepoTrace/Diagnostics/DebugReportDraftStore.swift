import Foundation

struct DebugReportDraft {
    let title: String
    let expectedBehavior: String
    let actualBehavior: String
    let reporterNotes: String
    let screenName: String
}

@MainActor
final class DebugReportDraftStore {
    static let shared = DebugReportDraftStore()

    private var pendingDraft: DebugReportDraft?

    private init() {}

    func stage(_ draft: DebugReportDraft) {
        pendingDraft = draft
    }

    func consume() -> DebugReportDraft? {
        let draft = pendingDraft
        pendingDraft = nil
        return draft
    }
}
