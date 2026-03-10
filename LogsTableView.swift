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

struct WeekDayTotal: Identifiable, Hashable {
    let id: Date
    let label: String
    let calories: Double
    let proteinCalories: Double
    let carbsCalories: Double
    let fatCalories: Double
    let goal: Double
}

struct WeeklySummary: Hashable {
    let days: [WeekDayTotal]
    let totalCalories: Double

    static let empty = WeeklySummary(days: [], totalCalories: 0)
}

struct LogsTableView: UIViewControllerRepresentable {
    let sections: [DaySection]
    let weeklySummary: WeeklySummary
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
            weeklySummary: weeklySummary,
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
