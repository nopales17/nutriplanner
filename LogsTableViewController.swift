import SwiftUI
import UIKit
import Combine

final class LogsTableViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dayTotalsHeaderReuseID = DayTotalsHostingHeaderView.reuseID
    private let logTitleHeaderView = UIView()
    private let logTitleLabel = UILabel()
    private let weekSummaryContainer = UIView()
    private var weekSummaryHost: UIHostingController<WeeklyTotalsCardView>?
    private var weekSummaryHeightConstraint: NSLayoutConstraint?
    private var dataSource: UITableViewDiffableDataSource<Date, String>!
    private var rowKindByID: [String: RowKind] = [:]
    private var sections: [DaySection] = []
    private var weeklySummary: WeeklySummary = .empty
    private var expandedID: UUID? = nil
    private var editingID: UUID? = nil
    private var draftMeal: String = ""
    private var animatingIDs: Set<UUID> = []
    private let animationDuration: TimeInterval = 0.25
    private let tableState = TableState()
    private var heightAnimator: UIViewPropertyAnimator?
    private var pendingAffectedIDs: [UUID] = []
    private var isAnimatingHeight = false
    private var pendingUpdate: PendingUpdate?
    private var updateScheduled = false
    private var layoutPassID: Int = 0
    private var heightCache: [UUID: CGFloat] = [:]
    private var isCollapsingAnimation = false

    private var onDelete: ((UUID) -> Void)?
    private var onToggleExpanded: ((UUID) -> Void)?
    private var onEdit: ((UUID) -> Void)?
    private var onToggleFavorite: ((UUID) -> Void)?
    private var onCancelEdit: (() -> Void)?
    private var onUpdate: ((UUID, String) -> Void)?

    private enum RowKind {
        case entry(UUID)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        tableView.backgroundColor = .clear
        tableView.isOpaque = false
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 120
        tableView.sectionFooterHeight = .leastNormalMagnitude
        tableView.estimatedSectionFooterHeight = 0
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.register(HostingLogCell.self, forCellReuseIdentifier: HostingLogCell.reuseID)
        tableView.register(DayTotalsHostingHeaderView.self, forHeaderFooterViewReuseIdentifier: dayTotalsHeaderReuseID)
        configureLogTitleHeader()

        dataSource = UITableViewDiffableDataSource<Date, String>(tableView: tableView) { [weak self] tableView, _, itemID in
            guard let self else { return UITableViewCell() }
            guard let kind = self.rowKindByID[itemID] else { return UITableViewCell() }
            switch kind {
            case .entry(let itemID):
                guard let cell = tableView.dequeueReusableCell(withIdentifier: HostingLogCell.reuseID) as? HostingLogCell else {
                    return UITableViewCell()
                }
                cell.configure(id: itemID, tableState: self.tableState)
                return cell
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLogTitleHeaderLayout()
        let topInset: CGFloat = 18
        let bottomInset: CGFloat = 88
        if tableView.contentInset.top != topInset || tableView.contentInset.bottom != bottomInset {
            tableView.contentInset.top = topInset
            tableView.scrollIndicatorInsets.top = topInset
            tableView.contentInset.bottom = bottomInset
            tableView.scrollIndicatorInsets.bottom = bottomInset
        }
    }

    private func configureLogTitleHeader() {
        logTitleHeaderView.backgroundColor = .clear
        logTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        logTitleLabel.text = "Log"
        logTitleLabel.textColor = .label
        logTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        logTitleLabel.adjustsFontForContentSizeCategory = true
        weekSummaryContainer.translatesAutoresizingMaskIntoConstraints = false
        weekSummaryContainer.backgroundColor = .clear
        logTitleHeaderView.addSubview(logTitleLabel)
        logTitleHeaderView.addSubview(weekSummaryContainer)
        NSLayoutConstraint.activate([
            logTitleLabel.leadingAnchor.constraint(equalTo: logTitleHeaderView.leadingAnchor, constant: 12),
            logTitleLabel.trailingAnchor.constraint(equalTo: logTitleHeaderView.trailingAnchor, constant: -12),
            logTitleLabel.topAnchor.constraint(equalTo: logTitleHeaderView.topAnchor, constant: 4),
            weekSummaryContainer.leadingAnchor.constraint(equalTo: logTitleHeaderView.leadingAnchor),
            weekSummaryContainer.trailingAnchor.constraint(equalTo: logTitleHeaderView.trailingAnchor),
            weekSummaryContainer.topAnchor.constraint(equalTo: logTitleLabel.bottomAnchor, constant: 8),
            weekSummaryContainer.bottomAnchor.constraint(equalTo: logTitleHeaderView.bottomAnchor, constant: -8)
        ])
        let weekHeight = weekSummaryContainer.heightAnchor.constraint(equalToConstant: 0)
        weekHeight.isActive = true
        weekSummaryHeightConstraint = weekHeight

        let host = UIHostingController(rootView: WeeklyTotalsCardView(summary: weeklySummary))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        weekSummaryContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: weekSummaryContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: weekSummaryContainer.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: weekSummaryContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: weekSummaryContainer.trailingAnchor)
        ])
        host.didMove(toParent: self)
        weekSummaryHost = host
    }

    private func updateLogTitleHeaderLayout() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let summaryHeight = max(
            0,
            ceil(
                weekSummaryHost?.sizeThatFits(
                    in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
                ).height ?? 0
            )
        )
        if weekSummaryHeightConstraint?.constant != summaryHeight {
            weekSummaryHeightConstraint?.constant = summaryHeight
        }
        logTitleHeaderView.setNeedsLayout()
        logTitleHeaderView.layoutIfNeeded()
        let fittingSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let fittedHeight = logTitleHeaderView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let headerHeight = max(44, ceil(fittedHeight))
        let currentFrame = logTitleHeaderView.frame
        if currentFrame.width != width || currentFrame.height != headerHeight || tableView.tableHeaderView == nil {
            logTitleHeaderView.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            tableView.tableHeaderView = logTitleHeaderView
        }
    }

    private func updateWeeklySummaryHeaderContent() {
        weekSummaryHost?.rootView = WeeklyTotalsCardView(summary: weeklySummary)
    }

    func update(
        sections: [DaySection],
        weeklySummary: WeeklySummary,
        expandedID: UUID?,
        editingID: UUID?,
        draftMeal: String,
        onDelete: @escaping (UUID) -> Void,
        onToggleExpanded: @escaping (UUID) -> Void,
        onEdit: @escaping (UUID) -> Void,
        onToggleFavorite: @escaping (UUID) -> Void,
        onCancelEdit: @escaping () -> Void,
        onUpdate: @escaping (UUID, String) -> Void
    ) {
        pendingUpdate = PendingUpdate(
            sections: sections,
            weeklySummary: weeklySummary,
            expandedID: expandedID,
            editingID: editingID,
            draftMeal: draftMeal,
            onDelete: onDelete,
            onToggleExpanded: onToggleExpanded,
            onEdit: onEdit,
            onToggleFavorite: onToggleFavorite,
            onCancelEdit: onCancelEdit,
            onUpdate: onUpdate
        )
        if !updateScheduled {
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.processPendingUpdate()
            }
        }
    }

    private func processPendingUpdate() {
        updateScheduled = false
        guard let payload = pendingUpdate else { return }
        pendingUpdate = nil
        applyUpdate(payload)
        if pendingUpdate != nil {
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.processPendingUpdate()
            }
        }
    }

    private func applyUpdate(_ payload: PendingUpdate) {
        debugLog("applyUpdate payload: sections=\(payload.sections.count) expanded=\(String(describing: payload.expandedID)) editing=\(String(describing: payload.editingID))")

        let previousSections = sections
        let previousWeeklySummary = weeklySummary
        let oldExpandedID = expandedID
        let oldEditingID = editingID

        onDelete = payload.onDelete
        onToggleExpanded = payload.onToggleExpanded
        onEdit = payload.onEdit
        onToggleFavorite = payload.onToggleFavorite
        onCancelEdit = payload.onCancelEdit
        onUpdate = payload.onUpdate
        draftMeal = payload.draftMeal
        sections = payload.sections
        weeklySummary = payload.weeklySummary
        expandedID = payload.expandedID
        editingID = payload.editingID

        if previousWeeklySummary != weeklySummary {
            updateWeeklySummaryHeaderContent()
            updateLogTitleHeaderLayout()
        }

        tableState.sections = payload.sections
        tableState.expandedID = payload.expandedID
        tableState.editingID = payload.editingID
        tableState.draftMeal = payload.draftMeal
        tableState.onToggleExpanded = payload.onToggleExpanded
        tableState.onEdit = payload.onEdit
        tableState.onToggleFavorite = payload.onToggleFavorite
        tableState.onCancelEdit = payload.onCancelEdit
        tableState.onUpdate = payload.onUpdate

        let expandedChanged = oldExpandedID != payload.expandedID
        let editingChanged = oldEditingID != payload.editingID
        let isCollapsing = expandedChanged && oldExpandedID != nil && payload.expandedID == nil
        isCollapsingAnimation = isCollapsing

        let previousSectionIDs = previousSections.map(\.id)
        let newSectionIDs = payload.sections.map(\.id)
        let previousRowIDs = previousSections.flatMap { $0.entries.map(\.id) }
        let newRowIDs = payload.sections.flatMap { $0.entries.map(\.id) }
        let dataChanged = previousSectionIDs != newSectionIDs || previousRowIDs != newRowIDs

        debugLog("dataChanged=\(dataChanged) expandedChanged=\(expandedChanged) editingChanged=\(editingChanged)")

        let affectedIDs = [oldExpandedID, payload.expandedID, oldEditingID, payload.editingID].compactMap { $0 }

        if dataChanged {
            var snapshot = NSDiffableDataSourceSnapshot<Date, String>()
            var rowKinds: [String: RowKind] = [:]
            let totalRows = payload.sections.reduce(0) { $0 + $1.entries.count }
            let shouldAnimateSnapshot = !previousSections.isEmpty && totalRows <= 120
            for section in payload.sections {
                snapshot.appendSections([section.id])
                for entry in section.entries {
                    let entryID = Self.entryRowID(for: entry.id)
                    snapshot.appendItems([entryID], toSection: section.id)
                    rowKinds[entryID] = .entry(entry.id)
                }
            }
            rowKindByID = rowKinds
            debugLog("applySnapshot dataChanged sections=\(payload.sections.count) rows=\(payload.sections.flatMap { $0.entries }.count)")
            dataSource.apply(snapshot, animatingDifferences: shouldAnimateSnapshot) { [weak self] in
                guard let self else { return }
                self.refreshVisibleSectionHeaders()
                if expandedChanged || editingChanged, !affectedIDs.isEmpty {
                    self.debugLog("startHeightAnimation after snapshot affectedIDs=\(affectedIDs)")
                    self.layoutPassID += 1
                    self.tableState.layoutPassID = self.layoutPassID
                    self.logTableState("beforeSchedule(afterSnapshot)", expandedID: payload.expandedID)
                    self.scheduleHeightAnimation(affectedIDs: affectedIDs)
                }
            }
        } else if expandedChanged || editingChanged {
            debugLog("no snapshot apply during expand/edit")
            if !affectedIDs.isEmpty {
                debugLog("startHeightAnimation affectedIDs=\(affectedIDs)")
                layoutPassID += 1
                tableState.layoutPassID = layoutPassID
                logTableState("beforeSchedule", expandedID: payload.expandedID)
                scheduleHeightAnimation(affectedIDs: affectedIDs)
            }
        }
        refreshVisibleSectionHeaders()
    }

    private func scheduleHeightAnimation(affectedIDs: [UUID]) {
        let merged = pendingAffectedIDs + affectedIDs
        pendingAffectedIDs = Array(Set(merged))
        debugLog("scheduleHeightAnimation pending=\(pendingAffectedIDs)")
        if isAnimatingHeight {
            return
        }
        isAnimatingHeight = true
        DispatchQueue.main.async { [weak self] in
            self?.animateHeightChange()
        }
    }

    private func animateHeightChange() {
        let affectedIDs = Array(Set(pendingAffectedIDs))
        pendingAffectedIDs = []
        guard !affectedIDs.isEmpty else {
            finishHeightAnimation()
            return
        }
        logTableState("beforeHeightAnimation", expandedID: expandedID)
        animatingIDs.formUnion(affectedIDs)
        tableState.animatingIDs = animatingIDs
        debugLog("animatingIDs += \(affectedIDs)")
        if !isCollapsingAnimation {
            precomputeVisibleHeights(for: affectedIDs)
        }
        let anchor = captureScrollAnchor(for: affectedIDs)
        debugLog("beginUpdates animation")
        let startOffset = tableView.contentOffset
        let inset = tableView.adjustedContentInset
        let startMaxOffsetY = max(
            -inset.top,
            tableView.contentSize.height - tableView.bounds.height + inset.bottom
        )
        let startBottomGap = startMaxOffsetY - startOffset.y
        let bottomAnchored = startBottomGap < 24
        let animator = UIViewPropertyAnimator(duration: animationDuration, curve: .easeInOut) {
            self.tableView.performBatchUpdates(nil)
            self.tableView.layoutIfNeeded()
            if bottomAnchored {
                let newMaxOffsetY = max(
                    -inset.top,
                    self.tableView.contentSize.height - self.tableView.bounds.height + inset.bottom
                )
                let targetY = newMaxOffsetY - startBottomGap
                self.tableView.contentOffset = CGPoint(
                    x: startOffset.x,
                    y: min(max(targetY, -inset.top), newMaxOffsetY)
                )
            } else {
                self.restoreScrollAnchor(anchor, fallbackOffset: startOffset)
            }
            self.logTableState("duringHeightAnimation", expandedID: self.expandedID)
        }
        heightAnimator = animator
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.animatingIDs.subtract(affectedIDs)
            self.tableState.animatingIDs = self.animatingIDs
            self.debugLog("animatingIDs -= \(affectedIDs)")
            self.heightAnimator = nil
            self.isAnimatingHeight = false
            self.tableState.precomputedHeights = [:]
            self.refreshHeightCache(for: affectedIDs)
            self.isCollapsingAnimation = false
            if !self.pendingAffectedIDs.isEmpty {
                self.debugLog("queued animation detected, restarting")
                self.scheduleHeightAnimation(affectedIDs: [])
            } else {
                self.finishHeightAnimation()
            }
            self.logTableState("afterHeightAnimation", expandedID: self.expandedID)
        }
        animator.startAnimation()
    }

    private func finishHeightAnimation() {
        heightAnimator = nil
        isAnimatingHeight = false
        debugLog("finishHeightAnimation")
    }

    private struct ScrollAnchor {
        enum Kind {
            case bottomGap(CGFloat)
            case rowTop(UUID, CGFloat)
        }
        let kind: Kind
    }

    private func captureScrollAnchor(for affectedIDs: [UUID]) -> ScrollAnchor? {
        let inset = tableView.adjustedContentInset
        let offset = tableView.contentOffset
        let maxOffset = tableView.contentSize.height - tableView.bounds.height + inset.bottom
        let bottomGap = maxOffset - offset.y
        if bottomGap < 24 {
            return ScrollAnchor(kind: .bottomGap(bottomGap))
        }
        if let id = affectedIDs.first, let indexPath = indexPathForItem(id: id) {
            let rect = tableView.rectForRow(at: indexPath)
            let delta = rect.minY - offset.y
            return ScrollAnchor(kind: .rowTop(id, delta))
        }
        return nil
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?, fallbackOffset: CGPoint) {
        let inset = tableView.adjustedContentInset
        let maxOffsetY = max(
            -inset.top,
            tableView.contentSize.height - tableView.bounds.height + inset.bottom
        )
        let minOffsetY = -inset.top
        var targetY = fallbackOffset.y
        if let anchor {
            switch anchor.kind {
            case .bottomGap(let gap):
                targetY = tableView.contentSize.height - tableView.bounds.height + inset.bottom - gap
            case .rowTop(let id, let delta):
                if let indexPath = indexPathForItem(id: id) {
                    let rect = tableView.rectForRow(at: indexPath)
                    targetY = rect.minY - delta
                }
            }
        }
        let clampedY = min(max(targetY, minOffsetY), maxOffsetY)
        tableView.contentOffset = CGPoint(x: fallbackOffset.x, y: clampedY)
    }

    private func precomputeVisibleHeights(for affectedIDs: [UUID]) {
        let visible = tableView.indexPathsForVisibleRows ?? []
        let targetWidth = tableView.bounds.width > 0 ? tableView.bounds.width : (view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width)
        var computed: [UUID: CGFloat] = [:]
        let affectedSet = Set(affectedIDs)
        for indexPath in visible {
            guard let rowID = dataSource.itemIdentifier(for: indexPath) else { continue }
            guard case let .entry(id)? = rowKindByID[rowID] else { continue }
            if affectedSet.contains(id), let cell = tableView.cellForRow(at: indexPath) as? HostingLogCell {
                let height = cell.measureHeight(forWidth: targetWidth)
                if height > 0 {
                    computed[id] = height
                }
            }
        }
        if !computed.isEmpty {
            tableState.precomputedHeights = computed
        }
    }

    private func refreshHeightCache(for ids: [UUID]) {
        for id in ids {
            if let indexPath = indexPathForItem(id: id) {
                let rect = tableView.rectForRow(at: indexPath)
                if rect.height > 0 {
                    heightCache[id] = rect.height
                }
            }
        }
    }

    private func indexPathForItem(id: UUID) -> IndexPath? {
        dataSource.indexPath(for: Self.entryRowID(for: id))
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[LogsTableViewController] \(message)")
        #endif
    }

    private func logTableState(_ label: String, expandedID: UUID?) {
        #if DEBUG
        let offset = tableView.contentOffset
        let inset = tableView.adjustedContentInset
        let size = tableView.contentSize
        let visible = tableView.indexPathsForVisibleRows ?? []
        let expandedIndexPath = expandedID.flatMap { dataSource.indexPath(for: Self.entryRowID(for: $0)) }
        let expandedRect = expandedIndexPath.map { tableView.rectForRow(at: $0) }
        print("[LogsTableViewController] \(label) offset=\(offset) inset=\(inset) contentSize=\(size)")
        print("[LogsTableViewController] \(label) visible=\(visible) expandedIndex=\(String(describing: expandedIndexPath)) expandedRect=\(String(describing: expandedRect)) dragging=\(tableView.isDragging) decel=\(tableView.isDecelerating)")
        #endif
    }

    private struct PendingUpdate {
        let sections: [DaySection]
        let weeklySummary: WeeklySummary
        let expandedID: UUID?
        let editingID: UUID?
        let draftMeal: String
        let onDelete: (UUID) -> Void
        let onToggleExpanded: (UUID) -> Void
        let onEdit: (UUID) -> Void
        let onToggleFavorite: (UUID) -> Void
        let onCancelEdit: () -> Void
        let onUpdate: (UUID, String) -> Void
    }

    private func refreshVisibleSectionHeaders() {
        for sectionIndex in sections.indices {
            guard let header = tableView.headerView(forSection: sectionIndex) as? DayTotalsHostingHeaderView else { continue }
            header.apply(section: sections[sectionIndex])
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections.indices.contains(section) else { return nil }
        let header = (tableView.dequeueReusableHeaderFooterView(withIdentifier: dayTotalsHeaderReuseID)
            as? DayTotalsHostingHeaderView) ?? DayTotalsHostingHeaderView(reuseIdentifier: dayTotalsHeaderReuseID)
        header.apply(section: sections[section])
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        120
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        (view as? DayTotalsHostingHeaderView)?.forceOpaqueState()
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let rowID = dataSource.itemIdentifier(for: indexPath) else { return 140 }
        switch rowKindByID[rowID] {
        case .entry(let id):
            if let cached = heightCache[id] {
                return cached
            }
            return 140
        case .none:
            return 140
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let rowID = dataSource.itemIdentifier(for: indexPath), case let .entry(id)? = rowKindByID[rowID] {
            heightCache[id] = cell.contentView.bounds.height
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Keep delegate conformance without per-frame logging.
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let rowID = dataSource.itemIdentifier(for: indexPath), case let .entry(logID)? = rowKindByID[rowID] else {
            return nil
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.onDelete?(logID)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private static func entryRowID(for id: UUID) -> String {
        "entry|\(id.uuidString)"
    }
}

final class DayTotalsHostingHeaderView: UITableViewHeaderFooterView {
    static let reuseID = "DayTotalsHostingHeaderView"
    private var host: UIHostingController<AnyView>?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundView = UIView()
        backgroundView?.backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = true
        contentView.clipsToBounds = true
    }

    private func ensureHost() {
        guard host == nil else { return }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        if #available(iOS 16.0, *) {
            host.sizingOptions = [.intrinsicContentSize]
        }
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        self.host = host
    }

    func apply(section: DaySection) {
        ensureHost()
        host?.rootView = AnyView(
            DayTotalsHeaderView(title: section.title, totals: section.totals)
        )
        forceOpaqueState()
    }

    func forceOpaqueState() {
        alpha = 1
        contentView.alpha = 1
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        host?.view.layer.removeAllAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        forceOpaqueState()
    }
}

final class TableState: ObservableObject {
    @Published var sections: [DaySection] = []
    @Published var expandedID: UUID? = nil
    @Published var editingID: UUID? = nil
    @Published var draftMeal: String = ""
    @Published var animatingIDs: Set<UUID> = []
    var layoutPassID: Int = 0
    var precomputedHeights: [UUID: CGFloat] = [:]

    var onToggleExpanded: (UUID) -> Void = { _ in }
    var onEdit: (UUID) -> Void = { _ in }
    var onToggleFavorite: (UUID) -> Void = { _ in }
    var onCancelEdit: () -> Void = { }
    var onUpdate: (UUID, String) -> Void = { _, _ in }
}

final class RowIDBox: ObservableObject {
    @Published var id: UUID = UUID()
}

struct LogRowHostedView: View {
    @ObservedObject var idBox: RowIDBox
    @EnvironmentObject var tableState: TableState

    private var log: MealLog? {
        for section in tableState.sections {
            if let match = section.entries.first(where: { $0.id == idBox.id }) {
                return match
            }
        }
        return nil
    }

    var body: some View {
        if let log {
            LogRowCardView(
                log: log,
                isExpanded: tableState.expandedID == log.id,
                isEditing: tableState.editingID == log.id,
                isHeightAnimating: tableState.animatingIDs.contains(log.id),
                draftMeal: tableState.draftMeal,
                onDraftChange: { tableState.draftMeal = $0 },
                onToggleExpanded: { tableState.onToggleExpanded(log.id) },
                onEdit: { tableState.onEdit(log.id) },
                onToggleFavorite: { tableState.onToggleFavorite(log.id) },
                onCancelEdit: { tableState.onCancelEdit() },
                onUpdate: { tableState.onUpdate(log.id, tableState.draftMeal) }
            )
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .frame(height: 80)
        }
    }
}

final class HostingLogCell: UITableViewCell {
    static let reuseID = "HostingLogCell"
    private let rowIDBox = RowIDBox()
    private var hostingController: UIHostingController<AnyView>?
    private weak var tableState: TableState?
    private var fittingCallCount = 0
    private var lastTargetWidth: CGFloat = 0
    private var lastNonZeroWidth: CGFloat = 0

    func configure(id: UUID, tableState: TableState) {
        backgroundColor = .clear
        selectionStyle = .none
        if hostingController == nil || self.tableState !== tableState {
            self.tableState = tableState
            let rootView = AnyView(LogRowHostedView(idBox: rowIDBox).environmentObject(tableState))
            let host = UIHostingController(rootView: rootView)
            if #available(iOS 16.0, *) {
                host.sizingOptions = [.intrinsicContentSize]
            }
            host.view.backgroundColor = .clear
            host.view.setContentHuggingPriority(.required, for: .vertical)
            host.view.setContentCompressionResistancePriority(.required, for: .vertical)
            hostingController = host
            contentView.subviews.forEach { $0.removeFromSuperview() }
            contentView.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])
        }
        rowIDBox.id = id
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        guard let host = hostingController else {
            return super.systemLayoutSizeFitting(
                targetSize,
                withHorizontalFittingPriority: horizontalFittingPriority,
                verticalFittingPriority: verticalFittingPriority
            )
        }
        let tableWidth = (superview as? UITableView)?.bounds.width ?? (superview?.superview as? UITableView)?.bounds.width ?? 0
        var targetWidth = targetSize.width > 0 ? targetSize.width : contentView.bounds.width
        if targetWidth <= 0, tableWidth > 0 { targetWidth = tableWidth }
        if targetWidth <= 0, lastNonZeroWidth > 0 { targetWidth = lastNonZeroWidth }
        if targetWidth <= 0 { targetWidth = UIScreen.main.bounds.width }
        if targetWidth > 0 { lastNonZeroWidth = targetWidth }
        if let cached = tableState?.precomputedHeights[rowIDBox.id] {
            return CGSize(width: targetWidth, height: pixelRound(cached))
        }
        let stableH = max(host.view.bounds.height, contentView.bounds.height, 10)
        host.view.bounds = CGRect(x: 0, y: 0, width: targetWidth, height: stableH)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fittingSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        let size = host.sizeThatFits(in: fittingSize)
        _ = tableWidth
        fittingCallCount += 1
        lastTargetWidth = targetWidth
        return CGSize(width: targetWidth, height: pixelRound(size.height))
    }

    private func pixelRound(_ h: CGFloat) -> CGFloat {
        let scale = UIScreen.main.scale
        return ceil(h * scale) / scale
    }

    func measureHeight(forWidth width: CGFloat) -> CGFloat {
        guard let host = hostingController else { return 0 }
        let targetWidth = width > 0 ? width : (lastNonZeroWidth > 0 ? lastNonZeroWidth : UIScreen.main.bounds.width)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return pixelRound(size.height)
    }
}

private struct LogRowCardView: View {
    let log: MealLog
    let isExpanded: Bool
    let isEditing: Bool
    let isHeightAnimating: Bool
    let draftMeal: String
    let onDraftChange: (String) -> Void
    let onToggleExpanded: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onCancelEdit: () -> Void
    let onUpdate: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private enum MacroTarget {
        static let calories = 2000.0
        static let protein = 50.0
        static let carbs = 275.0
        static let fat = 78.0
    }

    var body: some View {
        let microContent = VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 12)
            Text("Micronutrients")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MicronutrientGrid(items: log.micronutrientItems)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)

        VStack(spacing: 0) {
            editableHeader

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    CaloriePillView(calories: log.estimate.dietary_energy_kcal)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        MacroBarView(
                            protein: log.estimate.protein_g,
                            carbs: log.estimate.carbs_g,
                            fat: log.estimate.fat_total_g,
                            showsValues: false
                        )

                        HStack(alignment: .center, spacing: 8) {
                            HStack(spacing: 3) {
                                Text(String(format: "%.0f", log.estimate.protein_g))
                                    .foregroundStyle(.blue)
                                Text("P")
                                    .foregroundStyle(.blue)
                            }
                            HStack(spacing: 3) {
                                Text(String(format: "%.0f", log.estimate.carbs_g))
                                    .foregroundStyle(.orange)
                                Text("C")
                                    .foregroundStyle(.orange)
                            }
                            HStack(spacing: 3) {
                                Text(String(format: "%.0f", log.estimate.fat_total_g))
                                    .foregroundStyle(.pink)
                                Text("F")
                                    .foregroundStyle(.pink)
                            }
                            Spacer()
                            Button(action: onToggleExpanded) {
                                HStack(spacing: 6) {
                                    Text(isExpanded ? "Collapse" : "Expand")
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .layoutPriority(0)
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                        .layoutPriority(1)
                                        .fixedSize()
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 108, minHeight: 28, alignment: .trailing)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 0)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isHeightAnimating)
                            .accessibilityLabel(isExpanded ? "Collapse details" : "Expand details")
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 0)
            .padding(.bottom, 10)

            microContent
                .opacity(isExpanded ? 1 : 0)
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .accessibilityHidden(!isExpanded)
                .animation(.easeInOut(duration: 0.25), value: isExpanded)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(corners: .allCorners))
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .transaction {
            if isHeightAnimating && isExpanded {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }

    private var editableHeader: some View {
        ZStack(alignment: .topLeading) {
            if isEditing {
                expandedHeaderContent
            } else {
                collapsedHeaderContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isEditing ? Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08) : Color.clear)
        )
    }

    private var collapsedHeaderContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(log.meal)
                .font(.headline)
                .lineLimit(2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                editPencilButton
                favoriteToggleButton
            }
        }
    }

    private var expandedHeaderContent: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(
                "Meal description",
                text: Binding(
                    get: { draftMeal },
                    set: { onDraftChange($0) }
                ),
                axis: .vertical
            )
            .font(.headline)
            .textInputAutocapitalization(.sentences)
            .lineLimit(2, reservesSpace: true)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                        #endif
                    }
                }
            }

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Editing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                editPencilButton
                favoriteToggleButton
                Button(action: onUpdate) {
                    Text("Update")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftMeal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var editPencilButton: some View {
        Button(action: onEdit) {
            Label("Edit", systemImage: "pencil")
                .labelStyle(.iconOnly)
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .disabled(isHeightAnimating)
    }

    private var favoriteToggleButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: log.isFavorite ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(log.isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.bordered)
        .disabled(isHeightAnimating)
        .accessibilityLabel(log.isFavorite ? "Remove favorite" : "Mark as favorite")
    }

    private func cardBackground(corners: UIRectCorner) -> some View {
        RoundedCornerShape(radius: 16, corners: corners)
            .fill(.ultraThinMaterial)
            .background(
                RoundedCornerShape(radius: 16, corners: corners)
                    .fill(Color(.systemBackground).opacity(colorScheme == .dark ? 0.2 : 0.1))
            )
            .overlay(
                RoundedCornerShape(radius: 16, corners: corners)
                    .stroke(
                        isHeightAnimating
                            ? AnyShapeStyle(Color(red: 0.77, green: 0.62, blue: 0.97))
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.69, green: 0.54, blue: 0.95),
                                        Color(red: 0.84, green: 0.70, blue: 0.98)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            ),
                        lineWidth: 1
                    )
            )
    }
}
