import SwiftUI
import UIKit

struct DaySection: Identifiable, Hashable {
    let id: Date
    let title: String
    let entries: [MealLog]
    let totals: NutritionEstimate

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DaySection, rhs: DaySection) -> Bool {
        lhs.id == rhs.id
    }
}

struct LogsTableView: UIViewControllerRepresentable {
    let sections: [DaySection]
    @Binding var expandedID: UUID?
    @Binding var editingID: UUID?
    @Binding var draftMeal: String
    let onDelete: (UUID) -> Void
    let onToggleExpanded: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onCancelEdit: () -> Void
    let onUpdate: (UUID, String) -> Void

    func makeUIViewController(context: Context) -> LogsTableViewController {
        LogsTableViewController()
    }

    func updateUIViewController(_ uiViewController: LogsTableViewController, context: Context) {
        uiViewController.update(
            sections: sections,
            expandedID: expandedID,
            editingID: editingID,
            draftMeal: draftMeal,
            onDelete: onDelete,
            onToggleExpanded: onToggleExpanded,
            onEdit: onEdit,
            onCancelEdit: onCancelEdit,
            onUpdate: onUpdate
        )
    }
}
