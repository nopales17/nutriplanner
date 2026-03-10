import SwiftUI
import UIKit
import Combine

final class LogsTableViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let dayHeaderRowReuseID = "DayHeaderRowCell"
    private let logTitleHeaderView = UIView()
    private let logTitleLabel = UILabel()
    private let pinnedHeaderContainer = UIView()
    private var pinnedHeaderHost: UIHostingController<DayTotalsHeaderView>?
    private var pinnedHeaderHeightConstraint: NSLayoutConstraint?
    private var pinnedHeaderDayID: Date?
    private var dataSource: UITableViewDiffableDataSource<Date, String>!
    private var rowKindByID: [String: RowKind] = [:]
    private var sections: [DaySection] = []
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
    private var onCancelEdit: (() -> Void)?
    private var onUpdate: ((UUID, String) -> Void)?

    private enum RowKind {
        case dayHeader(Date)
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
        tableView.sectionHeaderHeight = .leastNormalMagnitude
        tableView.estimatedSectionHeaderHeight = 0
        tableView.sectionFooterHeight = .leastNormalMagnitude
        tableView.estimatedSectionFooterHeight = 0
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.register(HostingLogCell.self, forCellReuseIdentifier: HostingLogCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: dayHeaderRowReuseID)
        configureLogTitleHeader()
        configurePinnedHeader()

        dataSource = UITableViewDiffableDataSource<Date, String>(tableView: tableView) { [weak self] tableView, _, itemID in
            guard let self else { return UITableViewCell() }
            guard let kind = self.rowKindByID[itemID] else { return UITableViewCell() }
            switch kind {
            case .dayHeader(let day):
                let cell = tableView.dequeueReusableCell(withIdentifier: self.dayHeaderRowReuseID) ?? UITableViewCell()
                guard let section = self.sections.first(where: { $0.id == day }) else {
                    cell.contentConfiguration = nil
                    return cell
                }
                cell.backgroundColor = .clear
                cell.selectionStyle = .none
                cell.contentConfiguration = UIHostingConfiguration {
                    DayTotalsHeaderView(title: section.title, totals: section.totals)
                }
                .margins(.all, 0)
                cell.alpha = 1
                cell.transform = .identity
                cell.contentView.alpha = 1
                cell.layer.removeAllAnimations()
                cell.contentView.layer.removeAllAnimations()
                return cell
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
        updatePinnedHeaderState()
    }

    private func configureLogTitleHeader() {
        logTitleHeaderView.backgroundColor = .clear
        logTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        logTitleLabel.text = "Log"
        logTitleLabel.textColor = .label
        logTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        logTitleLabel.adjustsFontForContentSizeCategory = true
        logTitleHeaderView.addSubview(logTitleLabel)
        NSLayoutConstraint.activate([
            logTitleLabel.leadingAnchor.constraint(equalTo: logTitleHeaderView.leadingAnchor, constant: 12),
            logTitleLabel.trailingAnchor.constraint(equalTo: logTitleHeaderView.trailingAnchor, constant: -12),
            logTitleLabel.topAnchor.constraint(equalTo: logTitleHeaderView.topAnchor, constant: 4),
            logTitleLabel.bottomAnchor.constraint(equalTo: logTitleHeaderView.bottomAnchor, constant: -8)
        ])
    }

    private func updateLogTitleHeaderLayout() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
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

    private func configurePinnedHeader() {
        pinnedHeaderContainer.translatesAutoresizingMaskIntoConstraints = false
        pinnedHeaderContainer.backgroundColor = .clear
        pinnedHeaderContainer.isUserInteractionEnabled = false
        pinnedHeaderContainer.isHidden = true
        view.addSubview(pinnedHeaderContainer)

        NSLayoutConstraint.activate([
            pinnedHeaderContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pinnedHeaderContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pinnedHeaderContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let heightConstraint = pinnedHeaderContainer.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        pinnedHeaderHeightConstraint = heightConstraint

        let host = UIHostingController(rootView: DayTotalsHeaderView(title: "", totals: NutritionEstimate()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        pinnedHeaderContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: pinnedHeaderContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: pinnedHeaderContainer.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: pinnedHeaderContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: pinnedHeaderContainer.trailingAnchor)
        ])
        host.didMove(toParent: self)
        pinnedHeaderHost = host
    }

    func update(
        sections: [DaySection],
        expandedID: UUID?,
        editingID: UUID?,
        draftMeal: String,
        onDelete: @escaping (UUID) -> Void,
        onToggleExpanded: @escaping (UUID) -> Void,
        onEdit: @escaping (UUID) -> Void,
        onCancelEdit: @escaping () -> Void,
        onUpdate: @escaping (UUID, String) -> Void
    ) {
        pendingUpdate = PendingUpdate(
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
        let oldExpandedID = expandedID
        let oldEditingID = editingID

        onDelete = payload.onDelete
        onToggleExpanded = payload.onToggleExpanded
        onEdit = payload.onEdit
        onCancelEdit = payload.onCancelEdit
        onUpdate = payload.onUpdate
        draftMeal = payload.draftMeal
        sections = payload.sections
        expandedID = payload.expandedID
        editingID = payload.editingID

        tableState.sections = payload.sections
        tableState.expandedID = payload.expandedID
        tableState.editingID = payload.editingID
        tableState.draftMeal = payload.draftMeal
        tableState.onToggleExpanded = payload.onToggleExpanded
        tableState.onEdit = payload.onEdit
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
            for section in payload.sections {
                snapshot.appendSections([section.id])
                let headerID = Self.dayHeaderRowID(for: section.id)
                snapshot.appendItems([headerID], toSection: section.id)
                rowKinds[headerID] = .dayHeader(section.id)
                for entry in section.entries {
                    let entryID = Self.entryRowID(for: entry.id)
                    snapshot.appendItems([entryID], toSection: section.id)
                    rowKinds[entryID] = .entry(entry.id)
                }
            }
            rowKindByID = rowKinds
            debugLog("applySnapshot dataChanged sections=\(payload.sections.count) rows=\(payload.sections.flatMap { $0.entries }.count)")
            dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                guard let self else { return }
                self.updatePinnedHeaderState()
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
        updatePinnedHeaderState()
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
        let expandedID: UUID?
        let editingID: UUID?
        let draftMeal: String
        let onDelete: (UUID) -> Void
        let onToggleExpanded: (UUID) -> Void
        let onEdit: (UUID) -> Void
        let onCancelEdit: () -> Void
        let onUpdate: (UUID, String) -> Void
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let rowID = dataSource.itemIdentifier(for: indexPath) else { return 140 }
        switch rowKindByID[rowID] {
        case .dayHeader:
            return 120
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
        #if DEBUG
        let size = cell.contentView.bounds.size
        print("[LogsTableViewController] willDisplay row=\(indexPath) size=\(size)")
        #endif
        if let rowID = dataSource.itemIdentifier(for: indexPath), case let .entry(id)? = rowKindByID[rowID] {
            heightCache[id] = cell.contentView.bounds.height
        }

        if let rowID = dataSource.itemIdentifier(for: indexPath), case .dayHeader = rowKindByID[rowID] {
            cell.alpha = 1
            cell.transform = .identity
            cell.contentView.alpha = 1
            cell.layer.removeAllAnimations()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePinnedHeaderState()
        #if DEBUG
        let offset = scrollView.contentOffset
        let inset = scrollView.adjustedContentInset
        print("[LogsTableViewController] scroll contentOffset=\(offset) inset=\(inset) dragging=\(scrollView.isDragging) decel=\(scrollView.isDecelerating)")
        #endif
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

    private static func dayHeaderRowID(for day: Date) -> String {
        "day|\(day.timeIntervalSinceReferenceDate)"
    }

    private static func entryRowID(for id: UUID) -> String {
        "entry|\(id.uuidString)"
    }

    private func updatePinnedHeaderState() {
        guard !sections.isEmpty, tableView.bounds.width > 0 else {
            pinnedHeaderContainer.isHidden = true
            return
        }

        let pinY = tableView.contentOffset.y + tableView.adjustedContentInset.top
        var currentSectionIndex: Int?

        for sectionIndex in sections.indices {
            guard sectionIndex < tableView.numberOfSections, tableView.numberOfRows(inSection: sectionIndex) > 0 else {
                continue
            }
            let headerIndexPath = IndexPath(row: 0, section: sectionIndex)
            let rect = tableView.rectForRow(at: headerIndexPath)
            if rect.maxY > pinY {
                currentSectionIndex = sectionIndex
                break
            }
        }

        guard let sectionIndex = currentSectionIndex else {
            pinnedHeaderContainer.isHidden = true
            return
        }

        let section = sections[sectionIndex]
        setPinnedHeaderContent(section: section)

        let measuredHeight = pinnedHeaderHost?.sizeThatFits(
            in: CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        ).height ?? 0
        let headerHeight = max(1, ceil(measuredHeight))
        if pinnedHeaderHeightConstraint?.constant != headerHeight {
            pinnedHeaderHeightConstraint?.constant = headerHeight
            pinnedHeaderContainer.layoutIfNeeded()
        }

        var pushOffset: CGFloat = 0
        if sectionIndex + 1 < sections.count,
           sectionIndex + 1 < tableView.numberOfSections,
           tableView.numberOfRows(inSection: sectionIndex + 1) > 0
        {
            let nextRect = tableView.rectForRow(at: IndexPath(row: 0, section: sectionIndex + 1))
            let overlap = (pinY + headerHeight) - nextRect.minY
            if overlap > 0 {
                pushOffset = min(overlap, headerHeight)
            }
        }

        pinnedHeaderContainer.transform = CGAffineTransform(translationX: 0, y: -pushOffset)
        pinnedHeaderContainer.isHidden = false
        view.bringSubviewToFront(pinnedHeaderContainer)
        updateHeaderRowVisibility(pinnedSectionIndex: sectionIndex, pinY: pinY)
    }

    private func setPinnedHeaderContent(section: DaySection) {
        guard let pinnedHeaderHost else { return }
        // Update root view each pass so totals/title stay in sync with edits/deletes.
        pinnedHeaderHost.rootView = DayTotalsHeaderView(title: section.title, totals: section.totals)
        pinnedHeaderDayID = section.id
    }

    private func updateHeaderRowVisibility(pinnedSectionIndex: Int, pinY: CGFloat) {
        for cell in tableView.visibleCells {
            guard
                let indexPath = tableView.indexPath(for: cell),
                let rowID = dataSource.itemIdentifier(for: indexPath),
                case .dayHeader = rowKindByID[rowID]
            else { continue }

            if indexPath.section == pinnedSectionIndex {
                let rect = tableView.rectForRow(at: indexPath)
                let isUnderPinnedHeader = rect.minY <= pinY + 0.5
                cell.contentView.alpha = isUnderPinnedHeader ? 0 : 1
            } else {
                cell.contentView.alpha = 1
            }
        }
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
        #if DEBUG
        print("[HostingLogCell] configure id=\(id)")
        #endif
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
            #if DEBUG
            let isExpanded = tableState?.expandedID == rowIDBox.id
            let isHeightAnimating = tableState?.animatingIDs.contains(rowIDBox.id) ?? false
            let ts = String(format: "%.3f", CACurrentMediaTime())
            print("[HostingLogCell] t=\(ts) precomputed id=\(rowIDBox.id) expanded=\(isExpanded) anim=\(isHeightAnimating) h=\(cached)")
            #endif
            return CGSize(width: targetWidth, height: pixelRound(cached))
        }
        let stableH = max(host.view.bounds.height, contentView.bounds.height, 10)
        host.view.bounds = CGRect(x: 0, y: 0, width: targetWidth, height: stableH)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fittingSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        let size = host.sizeThatFits(in: fittingSize)
        let alt = host.view.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        #if DEBUG
        fittingCallCount += 1
        let widthDelta = abs(targetWidth - lastTargetWidth)
        lastTargetWidth = targetWidth
        let safe = superview?.safeAreaInsets ?? .zero
        let passID = tableState?.layoutPassID ?? -1
        let isExpanded = tableState?.expandedID == rowIDBox.id
        let isHeightAnimating = tableState?.animatingIDs.contains(rowIDBox.id) ?? false
        let ts = String(format: "%.3f", CACurrentMediaTime())
        print("[HostingLogCell] t=\(ts) pass=\(passID) call=\(fittingCallCount) id=\(rowIDBox.id) expanded=\(isExpanded) anim=\(isHeightAnimating) targetSize=\(targetSize) contentW=\(contentView.bounds.width) tableW=\(tableWidth) safe=\(safe) targetW=\(targetWidth) Δw=\(widthDelta) size=\(size) alt=\(alt)")
        #endif
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    CalorieTierBarView(
                        calories: log.estimate.dietary_energy_kcal,
                        height: 72
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            CaloriePillView(calories: log.estimate.dietary_energy_kcal)
                            Text(log.meal)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer()
                            Button(action: onEdit) {
                                Label("Edit", systemImage: "pencil")
                                    .labelStyle(.iconOnly)
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isHeightAnimating)
                        }
                        Text(log.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        MacroBarView(
                            protein: log.estimate.protein_g,
                            carbs: log.estimate.carbs_g,
                            fat: log.estimate.fat_total_g
                        )

                        HStack {
                            Spacer()
                            Button(action: onToggleExpanded) {
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
                            .disabled(isHeightAnimating)
                        }

                        if isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Edit meal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("Meal description", text: Binding(
                                        get: { draftMeal },
                                        set: { onDraftChange($0) }
                                    ), axis: .vertical)
                                    .textInputAutocapitalization(.sentences)
                                    .lineLimit(2, reservesSpace: true)
                                    Button(action: onUpdate) {
                                        Text("Update")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(draftMeal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                Button("Close", action: onCancelEdit)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(12)

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
