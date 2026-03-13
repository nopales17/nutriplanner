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
    private var collapseProbeTargetID: UUID?
    private var collapseProbeSession: Int = 0
    private var animationTraceSequence: Int = 0

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
        if isCollapsing, let oldExpandedID {
            collapseProbeTargetID = oldExpandedID
            collapseProbeSession += 1
            tableState.collapseProbeTargetID = oldExpandedID
            tableState.collapseProbeSession = collapseProbeSession
            traceAnimation(
                "probe.collapse.arm",
                "session=\(collapseProbeSession) target=\(oldExpandedID.uuidString) oldExpanded=\(formattedID(oldExpandedID)) newExpanded=\(formattedID(payload.expandedID))"
            )
        }

        let previousSectionIDs = previousSections.map(\.id)
        let newSectionIDs = payload.sections.map(\.id)
        let previousRowIDs = previousSections.flatMap { $0.entries.map(\.id) }
        let newRowIDs = payload.sections.flatMap { $0.entries.map(\.id) }
        let dataChanged = previousSectionIDs != newSectionIDs || previousRowIDs != newRowIDs

        debugLog("dataChanged=\(dataChanged) expandedChanged=\(expandedChanged) editingChanged=\(editingChanged)")
        traceAnimation(
            "state.applyUpdate",
            "oldExpanded=\(formattedID(oldExpandedID)) oldEditing=\(formattedID(oldEditingID)) newExpanded=\(formattedID(payload.expandedID)) newEditing=\(formattedID(payload.editingID)) dataChanged=\(dataChanged) expandedChanged=\(expandedChanged) editingChanged=\(editingChanged)"
        )

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
                self.traceAnimation(
                    "snapshot.applied",
                    "sections=\(payload.sections.count) rows=\(totalRows) shouldAnimate=\(shouldAnimateSnapshot) affected=\(affectedIDs.map { $0.uuidString })"
                )
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
        traceAnimation(
            "animation.schedule",
            "incoming=\(affectedIDs.map { $0.uuidString }) pending=\(pendingAffectedIDs.map { $0.uuidString }) isAnimating=\(isAnimatingHeight)"
        )
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
        let animationStart = ProcessInfo.processInfo.systemUptime
        let collapseProbeIsActive = isCollapsingAnimation
            && collapseProbeTargetID.map { affectedIDs.contains($0) } == true
        if collapseProbeIsActive, let target = collapseProbeTargetID {
            tableState.collapseProbeActive = true
            tableState.collapseProbeTargetID = target
            tableState.collapseProbeSession = collapseProbeSession
            traceAnimation(
                "probe.collapse.begin",
                "session=\(collapseProbeSession) target=\(target.uuidString) affected=\(affectedIDs.map { $0.uuidString })"
            )
        } else {
            tableState.collapseProbeActive = false
        }
        traceAnimation(
            "animation.start",
            "affected=\(affectedIDs.map { $0.uuidString }) expanded=\(formattedID(expandedID)) editing=\(formattedID(editingID)) targetMap=\(affectedIDs.map { "\($0.uuidString)->\(String(describing: indexPathForItem(id: $0)))" }) anchor=\(describe(anchor))"
        )
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
            let batchStart = ProcessInfo.processInfo.systemUptime
            self.traceAnimation(
                "animation.batch.begin",
                "affected=\(affectedIDs.map { $0.uuidString }) bottomAnchored=\(bottomAnchored) offset=\(self.tableView.contentOffset)"
            )
            self.tableView.performBatchUpdates(nil)
            let batchEnd = ProcessInfo.processInfo.systemUptime
            self.traceAnimation(
                "animation.batch.end",
                "elapsed=\(String(format: "%.6f", batchEnd - batchStart)) contentSize=\(self.tableView.contentSize)"
            )
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
            if self.tableState.collapseProbeActive {
                self.traceAnimation(
                    "probe.collapse.end",
                    "session=\(self.collapseProbeSession) target=\(self.formattedID(self.collapseProbeTargetID)) elapsed=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime - animationStart))"
                )
            }
            self.tableState.collapseProbeActive = false
            self.tableState.collapseProbeTargetID = nil
            self.collapseProbeTargetID = nil
            if !self.pendingAffectedIDs.isEmpty {
                self.debugLog("queued animation detected, restarting")
                self.scheduleHeightAnimation(affectedIDs: [])
            } else {
                self.finishHeightAnimation()
            }
            self.logTableState("afterHeightAnimation", expandedID: self.expandedID)
            let elapsed = ProcessInfo.processInfo.systemUptime - animationStart
            self.traceAnimation(
                "animation.complete",
                "elapsed=\(String(format: "%.6f", elapsed)) affected=\(affectedIDs.map { $0.uuidString }) expanded=\(self.formattedID(self.expandedID)) expandedIndex=\(String(describing: self.expandedID.flatMap { self.indexPathForItem(id: $0) }))"
            )
        }
        animator.startAnimation()
    }

    private func finishHeightAnimation() {
        heightAnimator = nil
        isAnimatingHeight = false
        tableState.collapseProbeActive = false
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

    private func traceAnimation(_ event: String, _ message: String) {
        #if DEBUG
        animationTraceSequence += 1
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        let line = "t=\(uptime) seq=\(animationTraceSequence) event=\(event) \(message)"
        print("[LogAnimationTrace] \(line)")
        BreadcrumbStore.shared.add(line, category: "log-animation")
        #endif
    }

    private func formattedID(_ id: UUID?) -> String {
        id?.uuidString ?? "nil"
    }

    private func describe(_ anchor: ScrollAnchor?) -> String {
        guard let anchor else { return "none" }
        switch anchor.kind {
        case .bottomGap(let gap):
            return "bottomGap(\(String(format: "%.2f", gap)))"
        case .rowTop(let id, let delta):
            return "rowTop(id=\(id.uuidString),delta=\(String(format: "%.2f", delta)))"
        }
    }

    private func visibleIndexToItemMappings() -> [String] {
        let visible = tableView.indexPathsForVisibleRows ?? []
        return visible.compactMap { indexPath in
            guard let rowID = dataSource.itemIdentifier(for: indexPath), case let .entry(id)? = rowKindByID[rowID] else {
                return "\(indexPath.section):\(indexPath.row)<->unknown"
            }
            return "\(indexPath.section):\(indexPath.row)<->\(id.uuidString)"
        }
    }

    private func pointerString(_ object: AnyObject) -> String {
        String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func logTableState(_ label: String, expandedID: UUID?) {
        #if DEBUG
        let offset = tableView.contentOffset
        let inset = tableView.adjustedContentInset
        let size = tableView.contentSize
        let visible = tableView.indexPathsForVisibleRows ?? []
        let visibleMappings = visibleIndexToItemMappings()
        let editingIndexPath = editingID.flatMap { dataSource.indexPath(for: Self.entryRowID(for: $0)) }
        let expandedIndexPath = expandedID.flatMap { dataSource.indexPath(for: Self.entryRowID(for: $0)) }
        let expandedRect = expandedIndexPath.map { tableView.rectForRow(at: $0) }
        print("[LogsTableViewController] \(label) offset=\(offset) inset=\(inset) contentSize=\(size)")
        print("[LogsTableViewController] \(label) visible=\(visible) expandedIndex=\(String(describing: expandedIndexPath)) expandedRect=\(String(describing: expandedRect)) dragging=\(tableView.isDragging) decel=\(tableView.isDecelerating)")
        traceAnimation(
            "table.\(label)",
            "expanded=\(formattedID(expandedID)) editing=\(formattedID(editingID)) expandedIndex=\(String(describing: expandedIndexPath)) editingIndex=\(String(describing: editingIndexPath)) visibleMap=\(visibleMappings)"
        )
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
            traceAnimation(
                "cell.willDisplay",
                "index=\(indexPath.section):\(indexPath.row) itemID=\(id.uuidString) cell=\(pointerString(cell)) reuseID=\(cell.reuseIdentifier ?? "nil") height=\(cell.contentView.bounds.height)"
            )
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        traceAnimation(
            "cell.didEndDisplay",
            "index=\(indexPath.section):\(indexPath.row) cell=\(pointerString(cell)) reuseID=\(cell.reuseIdentifier ?? "nil")"
        )
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
    @Published var collapseProbeTargetID: UUID? = nil
    @Published var collapseProbeActive: Bool = false
    @Published var collapseProbeSession: Int = 0
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
    @State private var probeCardFrame: CGRect = .zero
    @State private var probeDetailVisibleHeight: CGFloat = 0
    @State private var probeSample: Int = 0
    @State private var probeLastSignature: String = ""
    @State private var probeDetailRenderSample: Int = 0
    @State private var probeDetailRenderLastSignature: String = ""
    @State private var probeDetailOpacitySample: Int = 0
    @State private var probeDetailOpacityLastSignature: String = ""
    @State private var probeRowToken: String = UUID().uuidString

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
            let isExpanded = tableState.expandedID == log.id
            let isEditing = tableState.editingID == log.id
            let isHeightAnimating = tableState.animatingIDs.contains(log.id)
            let renderIdentity = "box=\(pointerString(idBox)) logID=\(log.id.uuidString) pass=\(tableState.layoutPassID) expanded=\(isExpanded) editing=\(isEditing) animating=\(isHeightAnimating)"
            LogRowCardView(
                log: log,
                isExpanded: isExpanded,
                isEditing: isEditing,
                isHeightAnimating: isHeightAnimating,
                draftMeal: tableState.draftMeal,
                onDraftChange: { tableState.draftMeal = $0 },
                onToggleExpanded: { tableState.onToggleExpanded(log.id) },
                onEdit: { tableState.onEdit(log.id) },
                onToggleFavorite: { tableState.onToggleFavorite(log.id) },
                onCancelEdit: { tableState.onCancelEdit() },
                onUpdate: { tableState.onUpdate(log.id, tableState.draftMeal) },
                onCardFrameChange: { frame in
                    probeCardFrame = frame
                    traceCollapseBorderSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailHeightChange: { height in
                    probeDetailVisibleHeight = height
                    traceCollapseBorderSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailRevealAnimatableSample: { animatableRevealProgress, detailOpacity, frameHeightParam, intrinsicDetailHeight, visibleDetailHeight in
                    traceCollapseDetailRenderSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating,
                        animatableRevealProgress: animatableRevealProgress,
                        detailOpacity: detailOpacity,
                        frameHeightParam: frameHeightParam,
                        intrinsicDetailHeight: intrinsicDetailHeight,
                        visibleDetailHeight: visibleDetailHeight
                    )
                },
                onDetailOpacityAnimatableSample: { interpolatedOpacity, targetOpacity, frameHeightParam, intrinsicDetailHeight, visibleDetailHeight in
                    traceCollapseDetailOpacitySample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating,
                        interpolatedOpacity: interpolatedOpacity,
                        targetOpacity: targetOpacity,
                        frameHeightParam: frameHeightParam,
                        intrinsicDetailHeight: intrinsicDetailHeight,
                        visibleDetailHeight: visibleDetailHeight
                    )
                }
            )
            .onAppear {
                traceHostedRow("swiftui.row.appear", renderIdentity)
            }
            .onDisappear {
                traceHostedRow("swiftui.row.disappear", renderIdentity)
            }
            .onChange(of: isExpanded) { _, newValue in
                traceHostedRow("swiftui.row.expandedChanged", "\(renderIdentity) newExpanded=\(newValue)")
            }
            .onChange(of: isEditing) { _, newValue in
                traceHostedRow("swiftui.row.editingChanged", "\(renderIdentity) newEditing=\(newValue)")
            }
            .onChange(of: isHeightAnimating) { _, newValue in
                traceHostedRow("swiftui.row.animatingChanged", "\(renderIdentity) newAnimating=\(newValue)")
            }
            .onChange(of: tableState.collapseProbeSession) { _, _ in
                probeSample = 0
                probeLastSignature = ""
                probeDetailRenderSample = 0
                probeDetailRenderLastSignature = ""
                probeDetailOpacitySample = 0
                probeDetailOpacityLastSignature = ""
            }
            .onChange(of: tableState.collapseProbeActive) { _, isActive in
                if !isActive {
                    probeLastSignature = ""
                    probeDetailRenderLastSignature = ""
                    probeDetailOpacityLastSignature = ""
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .frame(height: 80)
        }
    }

    private func traceHostedRow(_ event: String, _ message: String) {
        #if DEBUG
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        let line = "t=\(uptime) event=\(event) \(message)"
        print("[LogAnimationTrace] \(line)")
        BreadcrumbStore.shared.add(line, category: "log-animation")
        #endif
    }

    private func pointerString(_ object: AnyObject) -> String {
        String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func traceCollapseBorderSample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isEditing: Bool,
        isHeightAnimating: Bool
    ) {
        guard tableState.collapseProbeActive else { return }
        guard tableState.collapseProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        let cardMinY = formatted(probeCardFrame.minY)
        let cardMaxY = formatted(probeCardFrame.maxY)
        let cardHeight = formatted(probeCardFrame.height)
        let detailHeight = formatted(probeDetailVisibleHeight)
        let signature = "\(cardMinY)|\(cardMaxY)|\(cardHeight)|\(detailHeight)|\(isExpanded)|\(isEditing)|\(tableState.layoutPassID)"
        guard signature != probeLastSignature else { return }
        probeLastSignature = signature
        probeSample += 1
        traceHostedRow(
            "swiftui.row.borderProbe.sample",
            "\(renderIdentity) probeSession=\(tableState.collapseProbeSession) probeSample=\(probeSample) rowToken=\(probeRowToken) cardMinY=\(cardMinY) cardMaxY=\(cardMaxY) cardHeight=\(cardHeight) detailVisibleHeight=\(detailHeight) targetID=\(logID.uuidString)"
        )
    }

    private func traceCollapseDetailRenderSample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isEditing: Bool,
        isHeightAnimating: Bool,
        animatableRevealProgress: CGFloat,
        detailOpacity: CGFloat,
        frameHeightParam: CGFloat?,
        intrinsicDetailHeight: CGFloat,
        visibleDetailHeight: CGFloat
    ) {
        guard tableState.collapseProbeActive else { return }
        guard tableState.collapseProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        let revealProgress = formatted(animatableRevealProgress)
        let opacity = formatted(detailOpacity)
        let frameHeight = frameHeightParam.map(formatted) ?? "nil"
        let intrinsicHeight = formatted(intrinsicDetailHeight)
        let visibleHeight = formatted(visibleDetailHeight)
        let signature = "\(revealProgress)|\(opacity)|\(frameHeight)|\(intrinsicHeight)|\(visibleHeight)|\(isExpanded)|\(isEditing)|\(tableState.layoutPassID)"
        guard signature != probeDetailRenderLastSignature else { return }
        probeDetailRenderLastSignature = signature
        probeDetailRenderSample += 1
        traceHostedRow(
            "swiftui.row.detailRenderProbe.sample",
            "\(renderIdentity) probeSession=\(tableState.collapseProbeSession) probeSample=\(probeDetailRenderSample) rowToken=\(probeRowToken) revealProgress=\(revealProgress) detailOpacity=\(opacity) detailFrameHeightParam=\(frameHeight) detailIntrinsicHeight=\(intrinsicHeight) detailVisibleHeight=\(visibleHeight) targetID=\(logID.uuidString)"
        )
    }

    private func traceCollapseDetailOpacitySample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isEditing: Bool,
        isHeightAnimating: Bool,
        interpolatedOpacity: CGFloat,
        targetOpacity: CGFloat,
        frameHeightParam: CGFloat?,
        intrinsicDetailHeight: CGFloat,
        visibleDetailHeight: CGFloat
    ) {
        guard tableState.collapseProbeActive else { return }
        guard tableState.collapseProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        let interpolated = formatted(interpolatedOpacity)
        let target = formatted(targetOpacity)
        let frameHeight = frameHeightParam.map(formatted) ?? "nil"
        let intrinsicHeight = formatted(intrinsicDetailHeight)
        let visibleHeight = formatted(visibleDetailHeight)
        let signature = "\(interpolated)|\(target)|\(frameHeight)|\(intrinsicHeight)|\(visibleHeight)|\(isExpanded)|\(isEditing)|\(tableState.layoutPassID)"
        guard signature != probeDetailOpacityLastSignature else { return }
        probeDetailOpacityLastSignature = signature
        probeDetailOpacitySample += 1
        traceHostedRow(
            "swiftui.row.detailOpacityProbe.sample",
            "\(renderIdentity) probeSession=\(tableState.collapseProbeSession) probeSample=\(probeDetailOpacitySample) rowToken=\(probeRowToken) interpolatedOpacity=\(interpolated) targetOpacity=\(target) detailFrameHeightParam=\(frameHeight) detailIntrinsicHeight=\(intrinsicHeight) detailVisibleHeight=\(visibleHeight) targetID=\(logID.uuidString)"
        )
    }

    private func formatted(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
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
    private var currentRowID: UUID?

    func configure(id: UUID, tableState: TableState) {
        backgroundColor = .clear
        selectionStyle = .none
        let previousID = currentRowID
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
            traceCell(
                "cell.host.create",
                "cell=\(pointerString(self)) host=\(pointerString(host)) idBox=\(pointerString(rowIDBox))"
            )
        }
        rowIDBox.id = id
        currentRowID = id
        traceCell(
            "cell.configure",
            "cell=\(pointerString(self)) previousID=\(formattedID(previousID)) newID=\(id.uuidString) host=\(pointerString(hostingController)) idBox=\(pointerString(rowIDBox))"
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        traceCell(
            "cell.prepareForReuse",
            "cell=\(pointerString(self)) previousID=\(formattedID(currentRowID)) host=\(pointerString(hostingController))"
        )
        currentRowID = nil
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

    private func traceCell(_ event: String, _ message: String) {
        #if DEBUG
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        let line = "t=\(uptime) event=\(event) \(message)"
        print("[LogAnimationTrace] \(line)")
        BreadcrumbStore.shared.add(line, category: "log-animation")
        #endif
    }

    private func formattedID(_ id: UUID?) -> String {
        id?.uuidString ?? "nil"
    }

    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
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
    let onCardFrameChange: (CGRect) -> Void
    let onDetailHeightChange: (CGFloat) -> Void
    let onDetailRevealAnimatableSample: (CGFloat, CGFloat, CGFloat?, CGFloat, CGFloat) -> Void
    let onDetailOpacityAnimatableSample: (CGFloat, CGFloat, CGFloat?, CGFloat, CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var detailIntrinsicHeight: CGFloat = 0
    @State private var detailVisibleHeight: CGFloat = 0
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
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                detailIntrinsicHeight = proxy.size.height
                            }
                            .onChange(of: proxy.size.height) { _, newHeight in
                                detailIntrinsicHeight = newHeight
                            }
                    }
                )
                .modifier(
                    DetailOpacityAnimatableProbeModifier(
                        opacity: isExpanded ? 1 : 0,
                        onSample: { interpolatedOpacity in
                            onDetailOpacityAnimatableSample(
                                interpolatedOpacity,
                                isExpanded ? 1 : 0,
                                isExpanded ? nil : 0,
                                detailIntrinsicHeight,
                                detailVisibleHeight
                            )
                        }
                    )
                )
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                detailVisibleHeight = proxy.size.height
                                onDetailHeightChange(proxy.size.height)
                            }
                            .onChange(of: proxy.size.height) { _, newHeight in
                                detailVisibleHeight = newHeight
                                onDetailHeightChange(newHeight)
                            }
                    }
                )
                .clipped()
                .accessibilityHidden(!isExpanded)
                .modifier(
                    DetailRevealAnimatableProbeModifier(
                        revealProgress: isExpanded ? 1 : 0,
                        onSample: { interpolatedRevealProgress in
                            onDetailRevealAnimatableSample(
                                interpolatedRevealProgress,
                                isExpanded ? 1 : 0,
                                isExpanded ? nil : 0,
                                detailIntrinsicHeight,
                                detailVisibleHeight
                            )
                        }
                    )
                )
                .animation(.easeInOut(duration: 0.25), value: isExpanded)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(corners: .allCorners))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onCardFrameChange(proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                        onCardFrameChange(newFrame)
                    }
            }
        )
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

private struct DetailRevealAnimatableProbeModifier: AnimatableModifier {
    var revealProgress: CGFloat
    let onSample: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { revealProgress }
        set {
            revealProgress = newValue
            let sample = onSample
            DispatchQueue.main.async {
                sample(newValue)
            }
        }
    }

    func body(content: Content) -> some View {
        content
    }
}

private struct DetailOpacityAnimatableProbeModifier: AnimatableModifier {
    var opacity: CGFloat
    let onSample: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { opacity }
        set {
            opacity = newValue
            let sample = onSample
            DispatchQueue.main.async {
                sample(newValue)
            }
        }
    }

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}
