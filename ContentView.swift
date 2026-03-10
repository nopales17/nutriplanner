//
//  ContentView.swift
//  nutriplanner
//
//  Created by Paolo on 1/28/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    private struct EstimateQueueItem: Identifiable, Equatable {
        let id: UUID = UUID()
        let meal: String
    }

    private enum OpenAIModelOption: String, CaseIterable, Identifiable {
        case gpt5Nano = "gpt-5-nano"
        case gpt4oMini = "gpt-4o-mini"
        case gpt5Mini = "gpt-5-mini"

        static let defaultOption: OpenAIModelOption = .gpt5Nano

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gpt5Nano:
                return "Cheapest: GPT-5 nano"
            case .gpt4oMini:
                return "Low-cost: GPT-4o mini"
            case .gpt5Mini:
                return "Basic thinking: GPT-5 mini"
            }
        }

        var priceSummary: String {
            switch self {
            case .gpt5Nano:
                return "$0.05 input / $0.40 output per 1M tokens"
            case .gpt4oMini:
                return "$0.15 input / $0.60 output per 1M tokens"
            case .gpt5Mini:
                return "$0.25 input / $2.00 output per 1M tokens"
            }
        }
    }

    private enum GoalSex: String, CaseIterable, Identifiable {
        case male
        case female

        var id: String { rawValue }

        var label: String {
            switch self {
            case .male: return "Male"
            case .female: return "Female"
            }
        }
    }

    private enum ActivityLevel: String, CaseIterable, Identifiable {
        case sedentary
        case light
        case moderate
        case active
        case veryActive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sedentary: return "Sedentary"
            case .light: return "Lightly active"
            case .moderate: return "Moderately active"
            case .active: return "Active"
            case .veryActive: return "Very active"
            }
        }

        var multiplier: Double {
            switch self {
            case .sedentary: return 1.2
            case .light: return 1.375
            case .moderate: return 1.55
            case .active: return 1.725
            case .veryActive: return 1.9
            }
        }
    }

    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_model") private var selectedOpenAIModel = OpenAIModelOption.defaultOption.rawValue
    @AppStorage("meal_logs_json") private var logsJSON = "[]"
    @AppStorage("daily_calorie_goal_kcal") private var dailyCalorieGoal: Double = 2200
    @AppStorage("goal_sex") private var goalSexRawValue: String = GoalSex.male.rawValue
    @AppStorage("goal_age") private var goalAge: Int = 30
    @AppStorage("goal_height_cm") private var goalHeightCm: Double = 175
    @AppStorage("goal_weight_kg") private var goalWeightKg: Double = 75
    @AppStorage("goal_activity_level") private var goalActivityLevelRawValue: String = ActivityLevel.moderate.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var meal = ""
    @State private var estimateQueue: [EstimateQueueItem] = []
    @State private var activeEstimateQueueID: EstimateQueueItem.ID? = nil
    @State private var debugJSON: String? = nil
    @State private var logs: [MealLog] = []
    @State private var expandedLogID: UUID? = nil
    @State private var logError: String? = nil
    @State private var updatingLogIDs: Set<UUID> = []
    @State private var editingLogID: UUID? = nil
    @State private var editingMealText: String = ""
    @State private var isEstimatingQueue = false
    @State private var estimateError: String? = nil
    @State private var showEstimateSuccess = false
    @State private var estimateSuccessMessage = "Success! Logged to Health."
    private let successBannerSeconds: Double = 4

    private let hk = HealthKitManager()

    init() {
        if
            let data = logsJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([MealLog].self, from: data)
        {
            _logs = State(initialValue: decoded)
        }
    }

    var body: some View {
        TabView {
            NavigationStack {
                estimateView
            }
            .tabItem {
                Label("Estimate", systemImage: "pencil.and.list.clipboard")
            }

            NavigationStack {
                logView
            }
            .tabItem {
                Label("Log", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                settingsView
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .onChange(of: logs) { newValue in
            logsJSON = Self.encodeLogs(newValue)
        }
    }

    private var estimateView: some View {
        ZStack {
            themeBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showEstimateSuccess {
                        Text(estimateSuccessMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.green.opacity(0.85))
                            )
                            .transition(.opacity)
                    }
                    if let estimateError {
                        Text(estimateError)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.red.opacity(0.85))
                            )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if !estimateQueue.isEmpty {
                            Text("Queue")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(estimateQueue.enumerated()), id: \.element.id) { index, item in
                                        HStack(alignment: .center, spacing: 10) {
                                            if activeEstimateQueueID == item.id {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "clock")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text("\(index + 1). \(item.meal)")
                                                .font(.footnote)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)

                                            Spacer(minLength: 0)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.24 : 0.16))
                                        )
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .frame(maxHeight: 160)
                        }

                        Text("Enter one meal item")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $meal)
                            .frame(minHeight: 110, maxHeight: 170)
                            .padding(8)
                            .scrollContentBackground(.hidden)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.24 : 0.16))
                            )
                            .textInputAutocapitalization(.sentences)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { dismissKeyboard() }
                                }
                            }

                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)

                        HStack(alignment: .center, spacing: 8) {
                            if isEstimatingQueue {
                                Text("Logging queue (\(estimateQueue.count) pending)…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button(action: enqueueMealFromInput) {
                                Text("Generate")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.55, green: 0.38, blue: 0.88))
                            .disabled(trimmedMealInput.isEmpty)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.69, green: 0.54, blue: 0.95),
                                                Color(red: 0.84, green: 0.70, blue: 0.98)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                    )

                    if let debugJSON {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Debug JSON (decode failed)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: .constant(debugJSON))
                                .frame(minHeight: 160)
                                .font(.footnote.monospaced())
                                .padding(10)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Estimate")
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    private var settingsView: some View {
        ZStack {
            themeBackground
            Form {
                Section("OpenAI API Key") {
                    SecureField("sk-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { dismissKeyboard() }
                            }
                        }
                    Text("Stored on this device for this app. Delete the app to clear.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Model") {
                    Picker("OpenAI Model", selection: $selectedOpenAIModel) {
                        ForEach(OpenAIModelOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Endpoint model id: \(selectedModelOption.rawValue)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Price: \(selectedModelOption.priceSummary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Ordered cheapest to most capable for text responses.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Daily Calorie Goal") {
                    Stepper(value: $dailyCalorieGoal, in: 1200...5000, step: 25) {
                        Text("Daily goal: \(Int(dailyCalorieGoal)) kcal")
                    }

                    Picker("Sex", selection: $goalSexRawValue) {
                        ForEach(GoalSex.allCases) { sex in
                            Text(sex.label).tag(sex.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(value: $goalAge, in: 16...90, step: 1) {
                        Text("Age: \(goalAge)")
                    }

                    Stepper(value: $goalHeightCm, in: 130...220, step: 1) {
                        Text("Height: \(Int(goalHeightCm)) cm")
                    }

                    Stepper(value: $goalWeightKg, in: 40...200, step: 0.5) {
                        Text("Weight: \(String(format: "%.1f", goalWeightKg)) kg")
                    }

                    Picker("Activity", selection: $goalActivityLevelRawValue) {
                        ForEach(ActivityLevel.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("Estimated maintenance")
                        Spacer()
                        Text("\(Int(estimatedDailyCalories)) kcal")
                            .foregroundStyle(.secondary)
                    }

                    Button("Use Estimated Goal") {
                        dailyCalorieGoal = estimatedDailyCalories
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear {
                if OpenAIModelOption(rawValue: selectedOpenAIModel) == nil {
                    selectedOpenAIModel = OpenAIModelOption.defaultOption.rawValue
                }
            }
        }
        .navigationTitle("Settings")
        .scrollDismissesKeyboard(.interactively)
    }

    @MainActor
    private func enqueueMealFromInput() {
        guard !trimmedMealInput.isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            estimateError = "Missing API key."
            return
        }

        estimateError = nil
        estimateQueue.append(EstimateQueueItem(meal: trimmedMealInput))
        meal = ""

        guard !isEstimatingQueue else { return }
        Task { await processEstimateQueue() }
    }

    @MainActor
    private func processEstimateQueue() async {
        guard !isEstimatingQueue else { return }
        guard !estimateQueue.isEmpty else { return }

        isEstimatingQueue = true
        debugJSON = nil

        do {
            try await hk.requestAuth()
        } catch {
            estimateError = error.localizedDescription
            isEstimatingQueue = false
            return
        }

        let client = OpenAIClient(apiKey: apiKey, model: selectedModelOption.rawValue)

        while !estimateQueue.isEmpty {
            let queuedItem = estimateQueue[0]
            activeEstimateQueueID = queuedItem.id

            do {
                let estimate = try await client.estimateNutrition(mealText: queuedItem.meal)
                let newLog = MealLog(meal: queuedItem.meal, estimate: estimate, date: Date())
                try await hk.writeAll(estimate, date: newLog.date, entryID: newLog.id)
                logs.insert(newLog, at: 0)
                estimateQueue.removeFirst()
                showEstimateSuccessBanner("Success! Logged 1 item to Health.")
            } catch {
                if error is DecodingError {
                    debugJSON = OpenAIClient.lastExtractedJSON
                }
                estimateError = error.localizedDescription

                if let failedIndex = estimateQueue.firstIndex(where: { $0.id == queuedItem.id }) {
                    estimateQueue.remove(at: failedIndex)
                }
            }
        }

        activeEstimateQueueID = nil
        isEstimatingQueue = false
    }

    @MainActor
    private func showEstimateSuccessBanner(_ message: String) {
        estimateSuccessMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showEstimateSuccess = true
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(successBannerSeconds * 1_000_000_000))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showEstimateSuccess = false
                }
            }
        }
    }

    private var themeBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.13, green: 0.10, blue: 0.20),
                    Color(red: 0.22, green: 0.16, blue: 0.32)
                ]
                : [
                    Color(red: 0.93, green: 0.90, blue: 0.98),
                    Color(red: 0.84, green: 0.78, blue: 0.95)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var groupedLogsByDay: [Date: [MealLog]] {
        let calendar = Calendar.current
        return Dictionary(grouping: logs) { calendar.startOfDay(for: $0.date) }
    }

    private var logSections: [DaySection] {
        let calendar = Calendar.current
        let sortedDays = groupedLogsByDay.keys.sorted(by: >)
        return sortedDays.map { day in
            let entries = (groupedLogsByDay[day] ?? []).sorted(by: { $0.date > $1.date })
            let totals = entries.reduce(NutritionEstimate()) { $0 + $1.estimate }
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = dayTitleFormatter.string(from: day)
            }
            return DaySection(id: day, title: title, entries: entries, totals: totals)
        }
    }

    private var dayTitleFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private var selectedGoalSex: GoalSex {
        GoalSex(rawValue: goalSexRawValue) ?? .male
    }

    private var selectedActivityLevel: ActivityLevel {
        ActivityLevel(rawValue: goalActivityLevelRawValue) ?? .moderate
    }

    private var estimatedDailyCalories: Double {
        let baseBMR: Double
        switch selectedGoalSex {
        case .male:
            baseBMR = 10 * goalWeightKg + 6.25 * goalHeightCm - 5 * Double(goalAge) + 5
        case .female:
            baseBMR = 10 * goalWeightKg + 6.25 * goalHeightCm - 5 * Double(goalAge) - 161
        }
        let maintenance = baseBMR * selectedActivityLevel.multiplier
        return max(1200, Self.roundToNearest(maintenance, step: 25))
    }

    private var weeklySummary: WeeklySummary {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: startOfToday)?.start else {
            return .empty
        }

        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEEE")

        var days: [WeekDayTotal] = []
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfWeek) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let dayEntries = groupedLogsByDay[dayStart] ?? []
            let totals = dayEntries.reduce(NutritionEstimate()) { $0 + $1.estimate }
            let dayCalories = max(0, totals.dietary_energy_kcal)
            days.append(
                WeekDayTotal(
                    id: dayStart,
                    label: dayFormatter.string(from: dayStart),
                    calories: dayCalories,
                    proteinCalories: max(0, totals.protein_g * 4),
                    carbsCalories: max(0, totals.carbs_g * 4),
                    fatCalories: max(0, totals.fat_total_g * 9),
                    goal: dailyCalorieGoal
                )
            )
        }

        let totalCalories = days.reduce(0) { $0 + $1.calories }
        return WeeklySummary(days: days, totalCalories: totalCalories)
    }

    private var logView: some View {
        ZStack {
            themeBackground
            LogsTableView(
                sections: logSections,
                weeklySummary: weeklySummary,
                expandedID: $expandedLogID,
                editingID: $editingLogID,
                draftMeal: $editingMealText,
                onDelete: { id in deleteLogs(by: [id]) },
                onToggleExpanded: { id in
                    #if DEBUG
                    let action = (expandedLogID == id) ? "collapse" : "expand"
                    print("[ContentView] toggle \(action) id=\(id)")
                    #endif
                    if expandedLogID == id {
                        expandedLogID = nil
                    } else {
                        expandedLogID = id
                    }
                },
                onEdit: { id in
                    dismissKeyboard()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if editingLogID == id {
                            editingLogID = nil
                            editingMealText = ""
                        } else {
                            editingLogID = id
                            editingMealText = logs.first(where: { $0.id == id })?.meal ?? ""
                        }
                    }
                },
                onCancelEdit: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editingLogID = nil
                        editingMealText = ""
                    }
                },
                onUpdate: { id, newMeal in
                    if let entry = logs.first(where: { $0.id == id }) {
                        updateLog(entry, newMeal: newMeal)
                    }
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(.container, edges: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .alert("Delete Failed", isPresented: Binding(
                get: { logError != nil },
                set: { newValue in
                    if !newValue { logError = nil }
            }
        )) {
                Button("OK") { logError = nil }
            } message: {
                Text(logError ?? "Unknown error.")
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.16),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .allowsHitTesting(false)
            }
        }
    }

    private func deleteLogs(by ids: [UUID]) {
        let entries = logs.filter { ids.contains($0.id) }
        Task {
            do {
                try await hk.requestAuth()
                for entry in entries {
                    try await hk.deleteAll(for: entry.id)
                }
                await MainActor.run {
                    logs.removeAll { ids.contains($0.id) }
                }
            } catch {
                await MainActor.run {
                    logError = error.localizedDescription
                }
            }
        }
    }

    private func updateLog(_ entry: MealLog, newMeal: String) {
        guard !updatingLogIDs.contains(entry.id) else { return }
        let trimmedMeal = newMeal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMeal.isEmpty else {
            logError = "Meal description can't be empty."
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logError = "Missing API key."
            return
        }
        dismissKeyboard()
        updatingLogIDs.insert(entry.id)
        Task {
            do {
                try await hk.requestAuth()
                let client = OpenAIClient(apiKey: apiKey, model: selectedModelOption.rawValue)
                let estimate = try await client.estimateNutrition(mealText: trimmedMeal)
                try await hk.deleteAll(for: entry.id)
                try await hk.writeAll(estimate, date: entry.date, entryID: entry.id)
                let updated = MealLog(meal: trimmedMeal, estimate: estimate, date: entry.date, id: entry.id)
                await MainActor.run {
                    if let index = logs.firstIndex(where: { $0.id == entry.id }) {
                        logs[index] = updated
                    }
                    if editingLogID == entry.id {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            editingLogID = nil
                            editingMealText = ""
                        }
                    }
                    updatingLogIDs.remove(entry.id)
                }
            } catch {
                await MainActor.run {
                    logError = error.localizedDescription
                    updatingLogIDs.remove(entry.id)
                }
            }
        }
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private var selectedModelOption: OpenAIModelOption {
        OpenAIModelOption(rawValue: selectedOpenAIModel) ?? .defaultOption
    }

    private var trimmedMealInput: String {
        meal.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LogRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var entry: MealLog
    @Binding var isExpanded: Bool
    let isEditing: Bool
    @Binding var draftMeal: String
    let isUpdating: Bool
    let onUpdate: () -> Void
    let onEdit: () -> Void
    let onCancelEdit: () -> Void
    @State private var summaryHeight: CGFloat = 0
    @State private var baselineSummaryHeight: CGFloat = 0

    private var cardFill: some ShapeStyle {
        .ultraThinMaterial
    }

    private enum MacroTarget {
        static let calories = 2000.0
        static let protein = 50.0
        static let carbs = 275.0
        static let fat = 78.0
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                CaloriePillView(calories: entry.estimate.dietary_energy_kcal)
                Text(entry.meal)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(isUpdating)
            }
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            MacroBarView(
                protein: entry.estimate.protein_g,
                carbs: entry.estimate.carbs_g,
                fat: entry.estimate.fat_total_g
            )

            HStack {
                Spacer()
                Button(action: {
                    if !isEditing {
                        toggleExpanded()
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "Collapse" : "Expand")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit meal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Meal description", text: $draftMeal, axis: .vertical)
                            .textInputAutocapitalization(.sentences)
                            .lineLimit(2, reservesSpace: true)
                        Button(action: onUpdate) {
                            if isUpdating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Update")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdating || draftMeal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                #if canImport(UIKit)
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                #endif
                            }
                        }
                    }
                    Button("Close") {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        #endif
                        onCancelEdit()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryContent
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: SummaryHeightKey.self, value: geo.size.height)
                    }
                )
                .frame(height: summaryHeight > 0 ? summaryHeight : nil, alignment: .topLeading)
        }
        .onPreferenceChange(SummaryHeightKey.self) { newValue in
            if abs(summaryHeight - newValue) > 0.5 {
                summaryHeight = newValue
            }
            if !isEditing && !isExpanded && abs(baselineSummaryHeight - newValue) > 0.5 {
                baselineSummaryHeight = newValue
            }
        }
        .padding(12)
        .background(summaryBackground)
    }

    var body: some View {
        VStack(spacing: 0) {
            cardContent
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.vertical, isExpanded ? 0 : 6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if !isEditing {
                toggleExpanded()
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .onAppear {
            if baselineSummaryHeight == 0 {
                baselineSummaryHeight = summaryHeight
            }
        }
    }

    private var summaryBackground: some View {
        let corners: UIRectCorner = isExpanded ? [.topLeft, .topRight] : [.allCorners]
        return RoundedCornerShape(radius: 16, corners: corners)
            .fill(cardFill)
            .background(
                RoundedCornerShape(radius: 16, corners: corners)
                    .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
            )
            .overlay(
                RoundedCornerShape(radius: 16, corners: corners)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.69, green: 0.54, blue: 0.95),
                                Color(red: 0.84, green: 0.70, blue: 0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

private struct SummaryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct LogMicroRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let items: [NutrientItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            Text("Micronutrients")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MicronutrientGrid(items: items)
        }
        .padding(12)
        .background(
            RoundedCornerShape(radius: 16, corners: [.bottomLeft, .bottomRight])
                .fill(.ultraThinMaterial)
                .background(
                    RoundedCornerShape(radius: 16, corners: [.bottomLeft, .bottomRight])
                        .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
                )
                .overlay(
                    RoundedCornerShape(radius: 16, corners: [.bottomLeft, .bottomRight])
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.69, green: 0.54, blue: 0.95),
                                    Color(red: 0.84, green: 0.70, blue: 0.98)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 6)
        .padding(.top, 0)
        .padding(.bottom, 6)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

struct RoundedCornerShape: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}


struct CaloriePillView: View {
    let calories: Double
    private let tiers = 5
    private let maxCalories = 1000.0
    private let lCells: [(x: Int, y: Int)] = [
        (0, 0), (0, 1), (0, 2), (1, 2), (2, 2)
    ]

    private var filledCount: Int {
        let clamped = min(max(calories, 0), maxCalories)
        return min(tiers, max(0, Int(ceil(clamped / (maxCalories / Double(tiers))))))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let spacing: CGFloat = 2
            let cell = (side - (spacing * 2)) / 3
            let badgeSize = (cell * 2) + spacing

            ZStack(alignment: .topLeading) {
                ForEach(Array(lCells.enumerated()), id: \.offset) { index, coord in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index < filledCount ? Color.green : Color.green.opacity(0.22))
                        .frame(width: cell, height: cell)
                        .offset(
                            x: CGFloat(coord.x) * (cell + spacing),
                            y: CGFloat(coord.y) * (cell + spacing)
                        )
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.14))
                    .frame(width: badgeSize, height: badgeSize)
                    .offset(x: cell + spacing, y: 0)

                VStack(spacing: 1) {
                    Text(String(format: "%.0f", calories))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text("kcal")
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundStyle(Color.green)
                .frame(width: badgeSize, height: badgeSize)
                .offset(x: cell + spacing, y: 0)
            }
        }
        .frame(width: 42, height: 42)
    }
}

struct DayTotalsHeaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let totals: NutritionEstimate

    private enum MacroTarget {
        static let calories = 2000.0
        static let protein = 50.0
        static let carbs = 275.0
        static let fat = 78.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(spacing: 16) {
                MacroDialView(
                    title: "Calories",
                    value: totals.dietary_energy_kcal,
                    target: MacroTarget.calories,
                    unit: "kcal",
                    tint: .green
                )
                MacroDialView(
                    title: "Protein",
                    value: totals.protein_g,
                    target: MacroTarget.protein,
                    unit: "g",
                    tint: .blue
                )
                MacroDialView(
                    title: "Carbs",
                    value: totals.carbs_g,
                    target: MacroTarget.carbs,
                    unit: "g",
                    tint: .orange
                )
                MacroDialView(
                    title: "Fat",
                    value: totals.fat_total_g,
                    target: MacroTarget.fat,
                    unit: "g",
                    tint: .pink
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.69, green: 0.54, blue: 0.95),
                                    Color(red: 0.84, green: 0.70, blue: 0.98)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

struct WeeklyTotalsCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let summary: WeeklySummary

    private var maxScaleValue: Double {
        let maxDayCalories = summary.days.map { $0.calories }.max() ?? 0
        let maxGoal = summary.days.map { $0.goal }.max() ?? 0
        return max(max(maxDayCalories, maxGoal) * 1.1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Week Total")
                    .font(.headline)
                Spacer()
                Text("\(Int(summary.totalCalories)) kcal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(summary.days) { day in
                    WeekDayBarView(day: day, maxScaleValue: maxScaleValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Goal line marks each day target.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.62, green: 0.79, blue: 0.96),
                                    Color(red: 0.46, green: 0.65, blue: 0.90)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 12)
    }
}

private struct WeekDayBarView: View {
    let day: WeekDayTotal
    let maxScaleValue: Double

    private var safeMax: Double {
        max(maxScaleValue, 1)
    }

    private var caloriesClamped: Double {
        min(max(day.calories, 0), safeMax)
    }

    private var goalClamped: Double {
        min(max(day.goal, 0), safeMax)
    }

    private var barSegments: [(Color, Double)] {
        let macroTotal = max(day.proteinCalories + day.carbsCalories + day.fatCalories, 1)
        return [
            (.pink, day.fatCalories / macroTotal),
            (.orange, day.carbsCalories / macroTotal),
            (.blue, day.proteinCalories / macroTotal)
        ]
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let height = geo.size.height
                let caloriesHeight = height * CGFloat(caloriesClamped / safeMax)
                let goalY = height * CGFloat(1 - (goalClamped / safeMax))

                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    VStack(spacing: 0) {
                        ForEach(Array(barSegments.enumerated()), id: \.offset) { _, segment in
                            Rectangle()
                                .fill(segment.0.opacity(0.92))
                                .frame(height: caloriesHeight * CGFloat(segment.1))
                        }
                    }
                    .frame(width: geo.size.width * 0.78, height: caloriesHeight, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .offset(y: height - caloriesHeight)

                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: geo.size.width * 0.9, height: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .stroke(Color.black.opacity(0.14), lineWidth: 0.5)
                        )
                        .offset(y: goalY - 1)
                }
            }
            .frame(height: 108)

            Text(day.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MacroBarView: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    private var total: Double {
        max(protein + carbs + fat, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let proteinWidth = width * CGFloat(protein / total)
                let carbsWidth = width * CGFloat(carbs / total)
                let fatWidth = width * CGFloat(fat / total)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: proteinWidth)
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: carbsWidth)
                    Rectangle()
                        .fill(Color.pink)
                        .frame(width: fatWidth)
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
            .frame(height: 10)

            HStack(spacing: 8) {
                Text(String(format: "%.0f", protein))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(String(format: "%.0f", carbs))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(String(format: "%.0f", fat))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.pink)
            }
        }
    }
}

private struct MacroDialView: View {
    let title: String
    let value: Double
    let target: Double
    let unit: String
    let tint: Color

    var body: some View {
        let progress = target > 0 ? min(value / target, 1) : 0
        let displayValue = String(format: "%.0f", value)
        let displayGoal = String(format: "%.0f", target)

        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(displayValue)
                        .font(.subheadline.weight(.semibold))
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 70)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Goal \(displayGoal) \(unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NutrientItem: Identifiable {
    let id = UUID()
    let name: String
    let value: Double
    let unit: String

    var displayValue: String {
        let format = value < 10 ? "%.1f" : "%.0f"
        return String(format: format, value)
    }
}

struct MicronutrientGrid: View {
    let items: [NutrientItem]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(item.displayValue)\(item.unit)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct MealLog: Identifiable, Codable, Equatable {
    let id: UUID
    var meal: String
    let estimate: NutritionEstimate
    let date: Date

    init(meal: String, estimate: NutritionEstimate, date: Date, id: UUID = UUID()) {
        self.id = id
        self.meal = meal
        self.estimate = estimate
        self.date = date
    }

    var macroMicroSummary: String {
        let n = estimate
        return """
        kcal: \(n.dietary_energy_kcal)
        protein_g: \(n.protein_g)
        carbs_g: \(n.carbs_g)
        fiber_g: \(n.fiber_g)
        sugar_g: \(n.sugar_g)
        fat_total_g: \(n.fat_total_g)
        fat_saturated_g: \(n.fat_saturated_g)
        fat_monounsaturated_g: \(n.fat_monounsaturated_g)
        fat_polyunsaturated_g: \(n.fat_polyunsaturated_g)
        cholesterol_mg: \(n.cholesterol_mg)
        sodium_mg: \(n.sodium_mg)
        potassium_mg: \(n.potassium_mg)
        vitamin_a_ug: \(n.vitamin_a_ug)
        vitamin_c_mg: \(n.vitamin_c_mg)
        vitamin_d_ug: \(n.vitamin_d_ug)
        vitamin_e_mg: \(n.vitamin_e_mg)
        vitamin_k_ug: \(n.vitamin_k_ug)
        vitamin_b6_mg: \(n.vitamin_b6_mg)
        vitamin_b12_ug: \(n.vitamin_b12_ug)
        thiamin_b1_mg: \(n.thiamin_b1_mg)
        riboflavin_b2_mg: \(n.riboflavin_b2_mg)
        niacin_b3_mg: \(n.niacin_b3_mg)
        folate_ug: \(n.folate_ug)
        biotin_ug: \(n.biotin_ug)
        pantothenic_acid_b5_mg: \(n.pantothenic_acid_b5_mg)
        calcium_mg: \(n.calcium_mg)
        iron_mg: \(n.iron_mg)
        phosphorus_mg: \(n.phosphorus_mg)
        iodine_ug: \(n.iodine_ug)
        magnesium_mg: \(n.magnesium_mg)
        zinc_mg: \(n.zinc_mg)
        selenium_ug: \(n.selenium_ug)
        copper_mg: \(n.copper_mg)
        manganese_mg: \(n.manganese_mg)
        chromium_ug: \(n.chromium_ug)
        molybdenum_ug: \(n.molybdenum_ug)
        chloride_mg: \(n.chloride_mg)
        caffeine_mg: \(n.caffeine_mg)
        water_mL: \(n.water_mL)
        alcoholic_beverages_count: \(n.alcoholic_beverages_count)
        """
    }

    var micronutrientItems: [NutrientItem] {
        let n = estimate
        return [
            NutrientItem(name: "Fiber", value: n.fiber_g, unit: "g"),
            NutrientItem(name: "Sugar", value: n.sugar_g, unit: "g"),
            NutrientItem(name: "Sat. Fat", value: n.fat_saturated_g, unit: "g"),
            NutrientItem(name: "Mono Fat", value: n.fat_monounsaturated_g, unit: "g"),
            NutrientItem(name: "Poly Fat", value: n.fat_polyunsaturated_g, unit: "g"),
            NutrientItem(name: "Cholesterol", value: n.cholesterol_mg, unit: "mg"),
            NutrientItem(name: "Sodium", value: n.sodium_mg, unit: "mg"),
            NutrientItem(name: "Potassium", value: n.potassium_mg, unit: "mg"),
            NutrientItem(name: "Vitamin A", value: n.vitamin_a_ug, unit: "ug"),
            NutrientItem(name: "Vitamin C", value: n.vitamin_c_mg, unit: "mg"),
            NutrientItem(name: "Vitamin D", value: n.vitamin_d_ug, unit: "ug"),
            NutrientItem(name: "Vitamin E", value: n.vitamin_e_mg, unit: "mg"),
            NutrientItem(name: "Vitamin K", value: n.vitamin_k_ug, unit: "ug"),
            NutrientItem(name: "B6", value: n.vitamin_b6_mg, unit: "mg"),
            NutrientItem(name: "B12", value: n.vitamin_b12_ug, unit: "ug"),
            NutrientItem(name: "B1", value: n.thiamin_b1_mg, unit: "mg"),
            NutrientItem(name: "B2", value: n.riboflavin_b2_mg, unit: "mg"),
            NutrientItem(name: "B3", value: n.niacin_b3_mg, unit: "mg"),
            NutrientItem(name: "Folate", value: n.folate_ug, unit: "ug"),
            NutrientItem(name: "Biotin", value: n.biotin_ug, unit: "ug"),
            NutrientItem(name: "B5", value: n.pantothenic_acid_b5_mg, unit: "mg"),
            NutrientItem(name: "Calcium", value: n.calcium_mg, unit: "mg"),
            NutrientItem(name: "Iron", value: n.iron_mg, unit: "mg"),
            NutrientItem(name: "Phosphorus", value: n.phosphorus_mg, unit: "mg"),
            NutrientItem(name: "Iodine", value: n.iodine_ug, unit: "ug"),
            NutrientItem(name: "Magnesium", value: n.magnesium_mg, unit: "mg"),
            NutrientItem(name: "Zinc", value: n.zinc_mg, unit: "mg"),
            NutrientItem(name: "Selenium", value: n.selenium_ug, unit: "ug"),
            NutrientItem(name: "Copper", value: n.copper_mg, unit: "mg"),
            NutrientItem(name: "Manganese", value: n.manganese_mg, unit: "mg"),
            NutrientItem(name: "Chromium", value: n.chromium_ug, unit: "ug"),
            NutrientItem(name: "Molybdenum", value: n.molybdenum_ug, unit: "ug"),
            NutrientItem(name: "Chloride", value: n.chloride_mg, unit: "mg"),
            NutrientItem(name: "Caffeine", value: n.caffeine_mg, unit: "mg"),
            NutrientItem(name: "Water", value: n.water_mL, unit: "mL"),
            NutrientItem(name: "Alcohol", value: n.alcoholic_beverages_count, unit: "serv")
        ]
    }

    static func == (lhs: MealLog, rhs: MealLog) -> Bool {
        lhs.id == rhs.id &&
            lhs.meal == rhs.meal &&
            lhs.estimate == rhs.estimate &&
            lhs.date == rhs.date
    }
}

private extension ContentView {
    static func roundToNearest(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    static func encodeLogs(_ logs: [MealLog]) -> String {
        guard let data = try? JSONEncoder().encode(logs) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
