import SwiftUI
import UIKit
import Combine

private struct HostOwnerLayerSnapshot {
    let hostPointer: String
    let hostFrameInTable: CGRect
    let hostClipsToBounds: Bool
    let hostMasksToBounds: Bool
    let hostCompositingFilterActive: Bool
    let hostAllowsGroupOpacity: Bool
    let hostAlpha: CGFloat
    let hostHidden: Bool
    let swiftUIRootPointer: String?
    let swiftUIRootFrameInTable: CGRect
    let swiftUIRootClipsToBounds: Bool
    let swiftUIRootMasksToBounds: Bool
    let swiftUIRootCompositingFilterActive: Bool
    let swiftUIRootAllowsGroupOpacity: Bool
    let swiftUIRootAlpha: CGFloat
    let swiftUIRootHidden: Bool
}

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
    private var topEdgeProbeTargetID: UUID?
    private var topEdgeProbeSession: Int = 0
    private var topEdgeProbeDirection: String = "none"
    private var animationTraceSequence: Int = 0
    private var phaseTransitionSequence: Int = 0
    private var rowLastEditSequence: [UUID: Int] = [:]
    private var rowLastEditTransitionMessage: [UUID: String] = [:]
    private var rowExpandCollapseRunCount: [UUID: Int] = [:]
    private var rowLastExpandCollapseSequence: [UUID: Int] = [:]
    private var rowLastExpandCollapseDirection: [UUID: String] = [:]
    private var rowLastSequenceContextMessage: [UUID: String] = [:]
    private var siblingProbeSession: Int = 0
    private var siblingProbeDisplayLink: CADisplayLink?
    private var siblingProbeState: SiblingProbeState?
    private let siblingProbeEpsilon: CGFloat = 0.5
    private var ownerStackProbeSession: Int = 0
    private var ownerStackProbeSample: Int = 0
    private var ownerStackProbeLastSignature: String = ""
    private let ownerStackProbeMaxSamples: Int = 16

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
        phaseTransitionSequence += 1
        let transitionSequence = phaseTransitionSequence

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
        tableState.phaseProbeTargetID = nil
        tableState.phaseProbeTransitionSequence = transitionSequence
        tableState.phaseProbeDirection = "none"
        tableState.phaseProbeRunOrdinal = 0
        tableState.phaseProbePreviousDirection = "none"
        tableState.phaseProbePreviousTransitionSequence = -1
        tableState.phaseProbePriorEditSequence = -1
        tableState.phaseProbeHasPriorEdit = false
        tableState.phaseProbeEditDelta = -1
        tableState.phaseProbeEditActiveForTarget = false
        tableState.ownerStackProbeActive = false
        tableState.ownerStackProbeTargetID = nil
        tableState.ownerStackProbeDirection = "none"

        let expandedChanged = oldExpandedID != payload.expandedID
        let editingChanged = oldEditingID != payload.editingID
        if editingChanged {
            if let newEditingID = payload.editingID {
                rowLastEditSequence[newEditingID] = transitionSequence
            }
            let editTransitionMessage =
                "transitionSeq=\(transitionSequence) oldEditing=\(formattedID(oldEditingID)) newEditing=\(formattedID(payload.editingID)) oldExpanded=\(formattedID(oldExpandedID)) newExpanded=\(formattedID(payload.expandedID))"
            let replayTargets = Set([oldEditingID, payload.editingID, oldExpandedID, payload.expandedID].compactMap { $0 })
            for targetID in replayTargets {
                rowLastEditTransitionMessage[targetID] = editTransitionMessage
            }
            traceAnimation(
                "probe.sequence.editTransition",
                editTransitionMessage
            )
        }
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
        if expandedChanged {
            let direction: String
            switch (oldExpandedID, payload.expandedID) {
            case (.some, nil):
                direction = "collapse"
            case (nil, .some):
                direction = "expand"
            case (.some, .some):
                direction = "switch"
            case (nil, nil):
                direction = "none"
            }
            let targetID = payload.expandedID ?? oldExpandedID
            topEdgeProbeDirection = direction
            topEdgeProbeTargetID = targetID
            if let targetID {
                let previousRunCount = rowExpandCollapseRunCount[targetID] ?? 0
                let runOrdinal = previousRunCount + 1
                let previousDirection = rowLastExpandCollapseDirection[targetID] ?? "none"
                let previousTransition = rowLastExpandCollapseSequence[targetID] ?? -1
                let priorEditSequence = rowLastEditSequence[targetID] ?? -1
                let hasPriorEdit = priorEditSequence >= 0
                let editDelta = hasPriorEdit ? (transitionSequence - priorEditSequence) : -1
                let editActiveForTarget = payload.editingID == targetID || oldEditingID == targetID
                rowExpandCollapseRunCount[targetID] = runOrdinal
                rowLastExpandCollapseDirection[targetID] = direction
                rowLastExpandCollapseSequence[targetID] = transitionSequence
                tableState.phaseProbeTargetID = targetID
                tableState.phaseProbeTransitionSequence = transitionSequence
                tableState.phaseProbeDirection = direction
                tableState.phaseProbeRunOrdinal = runOrdinal
                tableState.phaseProbePreviousDirection = previousDirection
                tableState.phaseProbePreviousTransitionSequence = previousTransition
                tableState.phaseProbePriorEditSequence = priorEditSequence
                tableState.phaseProbeHasPriorEdit = hasPriorEdit
                tableState.phaseProbeEditDelta = editDelta
                tableState.phaseProbeEditActiveForTarget = editActiveForTarget
                let sequenceContextMessage =
                    "transitionSeq=\(transitionSequence) target=\(targetID.uuidString) direction=\(direction) runOrdinal=\(runOrdinal) previousDirection=\(previousDirection) previousTransitionSeq=\(previousTransition) priorEditSeq=\(priorEditSequence) hasPriorEdit=\(hasPriorEdit) editDelta=\(editDelta) editActiveForTarget=\(editActiveForTarget)"
                rowLastSequenceContextMessage[targetID] = sequenceContextMessage
                traceAnimation(
                    "probe.sequence.context",
                    sequenceContextMessage
                )
                topEdgeProbeSession += 1
                tableState.topEdgeProbeTargetID = targetID
                tableState.topEdgeProbeSession = topEdgeProbeSession
                tableState.topEdgeProbeDirection = direction
                traceAnimation(
                    "probe.topEdge.arm",
                    "session=\(topEdgeProbeSession) direction=\(direction) target=\(targetID.uuidString) oldExpanded=\(formattedID(oldExpandedID)) newExpanded=\(formattedID(payload.expandedID))"
                )
            }
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
        let topEdgeProbeIsActive = topEdgeProbeTargetID.map { affectedIDs.contains($0) } == true
        if topEdgeProbeIsActive, let target = topEdgeProbeTargetID {
            tableState.topEdgeProbeActive = true
            tableState.topEdgeProbeTargetID = target
            tableState.topEdgeProbeSession = topEdgeProbeSession
            tableState.topEdgeProbeDirection = topEdgeProbeDirection
            traceAnimation(
                "probe.topEdge.begin",
                "session=\(topEdgeProbeSession) direction=\(topEdgeProbeDirection) target=\(target.uuidString) affected=\(affectedIDs.map { $0.uuidString })"
            )
        } else {
            tableState.topEdgeProbeActive = false
        }
        let ownerStackProbeIsActive = topEdgeProbeIsActive && topEdgeProbeDirection == "collapse"
        if ownerStackProbeIsActive, let target = topEdgeProbeTargetID {
            ownerStackProbeSession += 1
            ownerStackProbeSample = 0
            ownerStackProbeLastSignature = ""
            tableState.ownerStackProbeActive = true
            tableState.ownerStackProbeTargetID = target
            tableState.ownerStackProbeSession = ownerStackProbeSession
            tableState.ownerStackProbeDirection = topEdgeProbeDirection
            traceAnimation(
                "probe.ownerStack.begin",
                "session=\(ownerStackProbeSession) direction=\(topEdgeProbeDirection) target=\(target.uuidString) affected=\(affectedIDs.map { $0.uuidString })"
            )
            sampleOwnerStackIfNeeded(trigger: "begin")
        } else {
            tableState.ownerStackProbeActive = false
            tableState.ownerStackProbeTargetID = nil
            tableState.ownerStackProbeDirection = "none"
        }
        if collapseProbeIsActive, let target = collapseProbeTargetID {
            beginSiblingProbeIfNeeded(
                targetID: target,
                direction: topEdgeProbeDirection,
                animationStart: animationStart
            )
        } else {
            stopSiblingProbeDisplayLink()
            siblingProbeState = nil
            tableState.siblingProbeActive = false
            tableState.siblingProbeTargetID = nil
            tableState.siblingProbeNextID = nil
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
            if self.tableState.topEdgeProbeActive {
                self.traceAnimation(
                    "probe.topEdge.end",
                    "session=\(self.topEdgeProbeSession) direction=\(self.topEdgeProbeDirection) target=\(self.formattedID(self.topEdgeProbeTargetID)) elapsed=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime - animationStart))"
                )
            }
            if self.tableState.ownerStackProbeActive {
                self.sampleOwnerStackIfNeeded(trigger: "end")
                self.traceAnimation(
                    "probe.ownerStack.end",
                    "session=\(self.ownerStackProbeSession) direction=\(self.tableState.ownerStackProbeDirection) target=\(self.formattedID(self.tableState.ownerStackProbeTargetID)) samples=\(self.ownerStackProbeSample) elapsed=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime - animationStart))"
                )
            }
            self.emitSequenceReplayIfNeeded(for: self.collapseProbeTargetID)
            self.finishSiblingProbe(animationEnd: ProcessInfo.processInfo.systemUptime)
            self.tableState.collapseProbeActive = false
            self.tableState.collapseProbeTargetID = nil
            self.collapseProbeTargetID = nil
            self.tableState.topEdgeProbeActive = false
            self.tableState.topEdgeProbeTargetID = nil
            self.topEdgeProbeTargetID = nil
            self.topEdgeProbeDirection = "none"
            self.tableState.ownerStackProbeActive = false
            self.tableState.ownerStackProbeTargetID = nil
            self.tableState.ownerStackProbeDirection = "none"
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
        tableState.topEdgeProbeActive = false
        stopSiblingProbeDisplayLink()
        siblingProbeState = nil
        tableState.siblingProbeActive = false
        tableState.siblingProbeTargetID = nil
        tableState.siblingProbeNextID = nil
        tableState.ownerStackProbeActive = false
        tableState.ownerStackProbeTargetID = nil
        tableState.ownerStackProbeDirection = "none"
        debugLog("finishHeightAnimation")
    }

    private struct ScrollAnchor {
        enum Kind {
            case bottomGap(CGFloat)
            case rowTop(UUID, CGFloat)
        }
        let kind: Kind
    }

    private struct RowFrameProbeSample {
        let indexPath: IndexPath
        let minY: CGFloat
        let maxY: CGFloat
        let height: CGFloat
        let zPosition: CGFloat
        let siblingIndex: Int
        let isVisible: Bool
    }

    private struct SiblingProbeState {
        let session: Int
        let direction: String
        let transitionSequence: Int
        let targetID: UUID
        let nextID: UUID
        let targetRunOrdinal: Int
        let hasPriorEditForTarget: Bool
        let animationStartUptime: TimeInterval
        let baselineTargetMinY: CGFloat
        let baselineTargetHeight: CGFloat
        let baselineNextMinY: CGFloat
        let baselineGap: CGFloat
        let baselineStackRelation: String
        var lastTargetMinY: CGFloat
        var lastTargetHeight: CGFloat
        var lastNextMinY: CGFloat
        var lastStackRelation: String
        var sampleCount: Int
        var stackRelationChangeCount: Int
        var lastTargetOuterChangeUptime: TimeInterval?
        var firstNextTopMoveUptime: TimeInterval?
        var minGap: CGFloat
        var maxOverlap: CGFloat
    }

    private func nextEntryID(after id: UUID) -> UUID? {
        let flatIDs = sections.flatMap { $0.entries.map(\.id) }
        guard let index = flatIDs.firstIndex(of: id), index + 1 < flatIDs.count else { return nil }
        return flatIDs[index + 1]
    }

    private func rowFrameProbeSample(for id: UUID) -> RowFrameProbeSample? {
        guard let indexPath = indexPathForItem(id: id) else { return nil }
        let rowRect = tableView.rectForRow(at: indexPath)
        let cell = tableView.cellForRow(at: indexPath)
        let zPosition = cell?.layer.zPosition ?? 0
        let siblingIndex = cell?.superview?.subviews.firstIndex(where: { $0 === cell }) ?? -1
        return RowFrameProbeSample(
            indexPath: indexPath,
            minY: rowRect.minY,
            maxY: rowRect.maxY,
            height: rowRect.height,
            zPosition: zPosition,
            siblingIndex: siblingIndex,
            isVisible: cell != nil
        )
    }

    private func stackingRelation(
        targetZ: CGFloat,
        nextZ: CGFloat,
        targetSiblingIndex: Int,
        nextSiblingIndex: Int
    ) -> String {
        if targetZ > nextZ { return "target_above_next_by_z" }
        if targetZ < nextZ { return "next_above_target_by_z" }
        if targetSiblingIndex >= 0, nextSiblingIndex >= 0 {
            if targetSiblingIndex > nextSiblingIndex { return "target_above_next_by_order" }
            if targetSiblingIndex < nextSiblingIndex { return "next_above_target_by_order" }
        }
        return "same_layer_order_or_unknown"
    }

    private func beginSiblingProbeIfNeeded(targetID: UUID, direction: String, animationStart: TimeInterval) {
        guard direction == "collapse" else { return }
        guard let nextID = nextEntryID(after: targetID) else {
            traceAnimation(
                "probe.sibling.skip",
                "target=\(targetID.uuidString) direction=\(direction) reason=no_immediate_next_row"
            )
            return
        }
        guard
            let targetSample = rowFrameProbeSample(for: targetID),
            let nextSample = rowFrameProbeSample(for: nextID)
        else {
            traceAnimation(
                "probe.sibling.skip",
                "target=\(targetID.uuidString) next=\(nextID.uuidString) direction=\(direction) reason=row_sample_unavailable"
            )
            return
        }

        siblingProbeSession += 1
        let session = siblingProbeSession
        let baselineGap = nextSample.minY - targetSample.maxY
        let baselineStackRelation = stackingRelation(
            targetZ: targetSample.zPosition,
            nextZ: nextSample.zPosition,
            targetSiblingIndex: targetSample.siblingIndex,
            nextSiblingIndex: nextSample.siblingIndex
        )
        let state = SiblingProbeState(
            session: session,
            direction: direction,
            transitionSequence: tableState.phaseProbeTransitionSequence,
            targetID: targetID,
            nextID: nextID,
            targetRunOrdinal: tableState.phaseProbeRunOrdinal,
            hasPriorEditForTarget: tableState.phaseProbeHasPriorEdit,
            animationStartUptime: animationStart,
            baselineTargetMinY: targetSample.minY,
            baselineTargetHeight: targetSample.height,
            baselineNextMinY: nextSample.minY,
            baselineGap: baselineGap,
            baselineStackRelation: baselineStackRelation,
            lastTargetMinY: targetSample.minY,
            lastTargetHeight: targetSample.height,
            lastNextMinY: nextSample.minY,
            lastStackRelation: baselineStackRelation,
            sampleCount: 0,
            stackRelationChangeCount: 0,
            lastTargetOuterChangeUptime: nil,
            firstNextTopMoveUptime: nil,
            minGap: baselineGap,
            maxOverlap: max(0, -baselineGap)
        )
        siblingProbeState = state
        tableState.siblingProbeActive = true
        tableState.siblingProbeTargetID = targetID
        tableState.siblingProbeNextID = nextID
        tableState.siblingProbeSession = session
        traceAnimation(
            "probe.sibling.begin",
            "session=\(session) direction=\(direction) transitionSeq=\(state.transitionSequence) target=\(targetID.uuidString) next=\(nextID.uuidString) targetIndex=\(targetSample.indexPath.section):\(targetSample.indexPath.row) nextIndex=\(nextSample.indexPath.section):\(nextSample.indexPath.row) targetRunOrdinal=\(state.targetRunOrdinal) hasPriorEditForTarget=\(state.hasPriorEditForTarget) baselineTargetMinY=\(String(format: "%.3f", targetSample.minY)) baselineTargetHeight=\(String(format: "%.3f", targetSample.height)) baselineNextMinY=\(String(format: "%.3f", nextSample.minY)) baselineGapY=\(String(format: "%.3f", baselineGap)) baselineTargetZ=\(String(format: "%.3f", targetSample.zPosition)) baselineNextZ=\(String(format: "%.3f", nextSample.zPosition)) baselineTargetOrder=\(targetSample.siblingIndex) baselineNextOrder=\(nextSample.siblingIndex) baselineStackRelation=\(baselineStackRelation) targetVisible=\(targetSample.isVisible) nextVisible=\(nextSample.isVisible)"
        )
        startSiblingProbeDisplayLink()
    }

    private func startSiblingProbeDisplayLink() {
        siblingProbeDisplayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(sampleSiblingProbe))
        link.add(to: .main, forMode: .common)
        siblingProbeDisplayLink = link
    }

    private func stopSiblingProbeDisplayLink() {
        siblingProbeDisplayLink?.invalidate()
        siblingProbeDisplayLink = nil
    }

    @objc private func sampleSiblingProbe() {
        guard var state = siblingProbeState else { return }
        guard
            let targetSample = rowFrameProbeSample(for: state.targetID),
            let nextSample = rowFrameProbeSample(for: state.nextID)
        else {
            return
        }
        state.sampleCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let targetOuterChanged =
            abs(targetSample.minY - state.lastTargetMinY) > siblingProbeEpsilon
            || abs(targetSample.height - state.lastTargetHeight) > siblingProbeEpsilon
        if targetOuterChanged {
            state.lastTargetOuterChangeUptime = now
        }
        let nextMovedFromBaseline =
            abs(nextSample.minY - state.baselineNextMinY) > siblingProbeEpsilon
        if nextMovedFromBaseline, state.firstNextTopMoveUptime == nil {
            state.firstNextTopMoveUptime = now
        }
        let gap = nextSample.minY - targetSample.maxY
        state.minGap = min(state.minGap, gap)
        state.maxOverlap = max(state.maxOverlap, max(0, -gap))
        let stackRelation = stackingRelation(
            targetZ: targetSample.zPosition,
            nextZ: nextSample.zPosition,
            targetSiblingIndex: targetSample.siblingIndex,
            nextSiblingIndex: nextSample.siblingIndex
        )
        if stackRelation != state.lastStackRelation {
            state.stackRelationChangeCount += 1
            state.lastStackRelation = stackRelation
        }

        state.lastTargetMinY = targetSample.minY
        state.lastTargetHeight = targetSample.height
        state.lastNextMinY = nextSample.minY
        siblingProbeState = state
        sampleOwnerStackIfNeeded(trigger: "displayLink")
    }

    private func finishSiblingProbe(animationEnd: TimeInterval) {
        stopSiblingProbeDisplayLink()
        guard let state = siblingProbeState else {
            tableState.siblingProbeActive = false
            tableState.siblingProbeTargetID = nil
            tableState.siblingProbeNextID = nil
            return
        }
        let settleUptime = state.lastTargetOuterChangeUptime ?? animationEnd
        let nextMoveUptime = state.firstNextTopMoveUptime
        let motionRelation: String
        let nextMoveToSettleDeltaMs: String
        if let nextMoveUptime {
            let deltaMs = (nextMoveUptime - settleUptime) * 1000
            nextMoveToSettleDeltaMs = String(format: "%.3f", deltaMs)
            if abs(deltaMs) <= 12 {
                motionRelation = "with"
            } else if deltaMs < 0 {
                motionRelation = "before"
            } else {
                motionRelation = "after"
            }
        } else {
            motionRelation = "no_next_move_detected"
            nextMoveToSettleDeltaMs = "nil"
        }
        let targetShift = state.lastTargetMinY - state.baselineTargetMinY
        let targetHeightShift = state.lastTargetHeight - state.baselineTargetHeight
        let nextShift = state.lastNextMinY - state.baselineNextMinY
        traceAnimation(
            "probe.sibling.end",
            "session=\(state.session) direction=\(state.direction) transitionSeq=\(state.transitionSequence) samples=\(state.sampleCount) target=\(state.targetID.uuidString) next=\(state.nextID.uuidString) targetRunOrdinal=\(state.targetRunOrdinal) hasPriorEditForTarget=\(state.hasPriorEditForTarget) nextTopMoveRelativeToTargetOuterSettle=\(motionRelation) nextMoveToSettleDeltaMs=\(nextMoveToSettleDeltaMs) settleOffsetMs=\(String(format: "%.3f", (settleUptime - state.animationStartUptime) * 1000)) nextFirstMoveOffsetMs=\(nextMoveUptime.map { String(format: "%.3f", ($0 - state.animationStartUptime) * 1000) } ?? "nil") targetMinYShiftFromStart=\(String(format: "%.3f", targetShift)) targetHeightShiftFromStart=\(String(format: "%.3f", targetHeightShift)) nextMinYShiftFromStart=\(String(format: "%.3f", nextShift)) baselineGapY=\(String(format: "%.3f", state.baselineGap)) minGapY=\(String(format: "%.3f", state.minGap)) maxOverlapY=\(String(format: "%.3f", state.maxOverlap)) baselineStackRelation=\(state.baselineStackRelation) finalStackRelation=\(state.lastStackRelation) stackRelationChangeCount=\(state.stackRelationChangeCount)"
        )
        siblingProbeState = nil
        tableState.siblingProbeActive = false
        tableState.siblingProbeTargetID = nil
        tableState.siblingProbeNextID = nil
    }

    private func sampleOwnerStackIfNeeded(trigger: String) {
        guard tableState.ownerStackProbeActive else { return }
        guard let targetID = tableState.ownerStackProbeTargetID else { return }
        if trigger == "displayLink", ownerStackProbeSample >= ownerStackProbeMaxSamples {
            return
        }

        guard let targetIndexPath = indexPathForItem(id: targetID) else { return }
        let targetRowRect = tableView.rectForRow(at: targetIndexPath)
        let targetCell = tableView.cellForRow(at: targetIndexPath)
        let targetCellFrameInTable = targetCell.map { $0.convert($0.bounds, to: tableView) } ?? .zero
        let targetContentFrameInTable = targetCell.map { $0.contentView.convert($0.contentView.bounds, to: tableView) } ?? .zero
        let targetCellVisible = targetCell != nil
        let targetCellClips = targetCell?.clipsToBounds ?? false
        let targetCellMasks = targetCell?.layer.masksToBounds ?? false
        let targetCellAlpha = targetCell?.alpha ?? 0
        let targetCellHidden = targetCell?.isHidden ?? true
        let targetContentClips = targetCell?.contentView.clipsToBounds ?? false
        let targetContentMasks = targetCell?.contentView.layer.masksToBounds ?? false
        let targetContentAlpha = targetCell?.contentView.alpha ?? 0
        let targetContentHidden = targetCell?.contentView.isHidden ?? true
        let targetCellZ = targetCell?.layer.zPosition ?? 0
        let targetCellOrder = targetCell.flatMap { cell in
            cell.superview?.subviews.firstIndex(where: { $0 === cell })
        } ?? -1
        let hostSnapshot = (targetCell as? HostingLogCell)?.ownerLayerSnapshot(in: tableView)

        let nextID = nextEntryID(after: targetID)
        let nextSample = nextID.flatMap { rowFrameProbeSample(for: $0) }
        let nextIndexPath = nextID.flatMap { indexPathForItem(id: $0) }
        let nextCell = nextIndexPath.flatMap { tableView.cellForRow(at: $0) }
        let nextCellFrameInTable = nextCell.map { $0.convert($0.bounds, to: tableView) } ?? .zero
        let nextCellVisible = nextCell != nil
        let nextCellZ = nextCell?.layer.zPosition ?? 0
        let nextCellOrder = nextCell.flatMap { cell in
            cell.superview?.subviews.firstIndex(where: { $0 === cell })
        } ?? -1
        let nextRowMinY = nextSample?.minY ?? .zero
        let nextRowHeight = nextSample?.height ?? .zero
        let rowGap = nextSample.map { $0.minY - targetRowRect.maxY } ?? 0
        let cellGap = nextCellVisible && targetCellVisible ? (nextCellFrameInTable.minY - targetCellFrameInTable.maxY) : 0
        let cellOverlap = nextCellVisible && targetCellVisible ? max(0, targetCellFrameInTable.maxY - nextCellFrameInTable.minY) : 0
        let stackRelation = nextSample.map {
            stackingRelation(
                targetZ: targetCellZ,
                nextZ: $0.zPosition,
                targetSiblingIndex: targetCellOrder,
                nextSiblingIndex: $0.siblingIndex
            )
        } ?? "unknown"

        let signature = [
            formatted(targetRowRect.minY),
            formatted(targetRowRect.maxY),
            formatted(targetRowRect.height),
            formatted(targetCellFrameInTable.minY),
            formatted(targetCellFrameInTable.height),
            formatted(targetContentFrameInTable.minY),
            formatted(targetContentFrameInTable.height),
            formatted(hostSnapshot?.hostFrameInTable.minY ?? 0),
            formatted(hostSnapshot?.hostFrameInTable.height ?? 0),
            formatted(hostSnapshot?.swiftUIRootFrameInTable.minY ?? 0),
            formatted(hostSnapshot?.swiftUIRootFrameInTable.height ?? 0),
            formatted(nextRowMinY),
            formatted(nextRowHeight),
            formatted(rowGap),
            formatted(cellGap),
            formatted(cellOverlap),
            stackRelation,
            String(targetCellVisible),
            String(nextCellVisible),
            String(tableState.layoutPassID),
            trigger
        ].joined(separator: "|")
        guard signature != ownerStackProbeLastSignature else { return }
        ownerStackProbeLastSignature = signature
        ownerStackProbeSample += 1

        traceAnimation(
            "probe.ownerStack.sample",
            "session=\(tableState.ownerStackProbeSession) probeSample=\(ownerStackProbeSample) probeSampleLimit=\(ownerStackProbeMaxSamples) trigger=\(trigger) direction=\(tableState.ownerStackProbeDirection) target=\(targetID.uuidString) targetIndex=\(targetIndexPath.section):\(targetIndexPath.row) rowRectMinY=\(formatted(targetRowRect.minY)) rowRectMaxY=\(formatted(targetRowRect.maxY)) rowRectHeight=\(formatted(targetRowRect.height)) tableClipsToBounds=\(tableView.clipsToBounds) tableMasksToBounds=\(tableView.layer.masksToBounds) targetCellVisible=\(targetCellVisible) targetCellMinY=\(formatted(targetCellFrameInTable.minY)) targetCellMaxY=\(formatted(targetCellFrameInTable.maxY)) targetCellHeight=\(formatted(targetCellFrameInTable.height)) targetCellClipsToBounds=\(targetCellClips) targetCellMasksToBounds=\(targetCellMasks) targetCellAlpha=\(formatted(targetCellAlpha)) targetCellHidden=\(targetCellHidden) targetCellZ=\(formatted(targetCellZ)) targetCellOrder=\(targetCellOrder) targetContentMinY=\(formatted(targetContentFrameInTable.minY)) targetContentMaxY=\(formatted(targetContentFrameInTable.maxY)) targetContentHeight=\(formatted(targetContentFrameInTable.height)) targetContentClipsToBounds=\(targetContentClips) targetContentMasksToBounds=\(targetContentMasks) targetContentAlpha=\(formatted(targetContentAlpha)) targetContentHidden=\(targetContentHidden) hostViewPtr=\(hostSnapshot?.hostPointer ?? "nil") hostViewMinY=\(formatted(hostSnapshot?.hostFrameInTable.minY ?? 0)) hostViewMaxY=\(formatted(hostSnapshot?.hostFrameInTable.maxY ?? 0)) hostViewHeight=\(formatted(hostSnapshot?.hostFrameInTable.height ?? 0)) hostViewClipsToBounds=\(hostSnapshot?.hostClipsToBounds ?? false) hostViewMasksToBounds=\(hostSnapshot?.hostMasksToBounds ?? false) hostViewCompositingFilterActive=\(hostSnapshot?.hostCompositingFilterActive ?? false) hostViewAllowsGroupOpacity=\(hostSnapshot?.hostAllowsGroupOpacity ?? false) hostViewAlpha=\(formatted(hostSnapshot?.hostAlpha ?? 0)) hostViewHidden=\(hostSnapshot?.hostHidden ?? true) swiftUIRootPtr=\(hostSnapshot?.swiftUIRootPointer ?? "nil") swiftUIRootMinY=\(formatted(hostSnapshot?.swiftUIRootFrameInTable.minY ?? 0)) swiftUIRootMaxY=\(formatted(hostSnapshot?.swiftUIRootFrameInTable.maxY ?? 0)) swiftUIRootHeight=\(formatted(hostSnapshot?.swiftUIRootFrameInTable.height ?? 0)) swiftUIRootClipsToBounds=\(hostSnapshot?.swiftUIRootClipsToBounds ?? false) swiftUIRootMasksToBounds=\(hostSnapshot?.swiftUIRootMasksToBounds ?? false) swiftUIRootCompositingFilterActive=\(hostSnapshot?.swiftUIRootCompositingFilterActive ?? false) swiftUIRootAllowsGroupOpacity=\(hostSnapshot?.swiftUIRootAllowsGroupOpacity ?? false) swiftUIRootAlpha=\(formatted(hostSnapshot?.swiftUIRootAlpha ?? 0)) swiftUIRootHidden=\(hostSnapshot?.swiftUIRootHidden ?? true) nextID=\(nextID?.uuidString ?? "nil") nextCellVisible=\(nextCellVisible) nextRowMinY=\(formatted(nextRowMinY)) nextRowHeight=\(formatted(nextRowHeight)) nextCellMinY=\(formatted(nextCellFrameInTable.minY)) nextCellMaxY=\(formatted(nextCellFrameInTable.maxY)) nextCellHeight=\(formatted(nextCellFrameInTable.height)) nextCellZ=\(formatted(nextCellZ)) nextCellOrder=\(nextCellOrder) rowGapY=\(formatted(rowGap)) cellGapY=\(formatted(cellGap)) cellOverlapY=\(formatted(cellOverlap)) stackRelation=\(stackRelation)"
        )
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

    private func emitSequenceReplayIfNeeded(for targetID: UUID?) {
        guard let targetID else { return }
        if let editTransitionMessage = rowLastEditTransitionMessage[targetID] {
            traceAnimation("probe.sequence.editTransition", "\(editTransitionMessage) replay=tail")
        }
        if let sequenceContextMessage = rowLastSequenceContextMessage[targetID] {
            traceAnimation("probe.sequence.context", "\(sequenceContextMessage) replay=tail")
        }
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

    private func formatted(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
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
    @Published var topEdgeProbeTargetID: UUID? = nil
    @Published var topEdgeProbeActive: Bool = false
    @Published var topEdgeProbeSession: Int = 0
    @Published var topEdgeProbeDirection: String = "none"
    @Published var phaseProbeTargetID: UUID? = nil
    @Published var phaseProbeTransitionSequence: Int = -1
    @Published var phaseProbeDirection: String = "none"
    @Published var phaseProbeRunOrdinal: Int = 0
    @Published var phaseProbePreviousDirection: String = "none"
    @Published var phaseProbePreviousTransitionSequence: Int = -1
    @Published var phaseProbePriorEditSequence: Int = -1
    @Published var phaseProbeHasPriorEdit: Bool = false
    @Published var phaseProbeEditDelta: Int = -1
    @Published var phaseProbeEditActiveForTarget: Bool = false
    @Published var siblingProbeActive: Bool = false
    @Published var siblingProbeTargetID: UUID? = nil
    @Published var siblingProbeNextID: UUID? = nil
    @Published var siblingProbeSession: Int = 0
    @Published var ownerStackProbeActive: Bool = false
    @Published var ownerStackProbeTargetID: UUID? = nil
    @Published var ownerStackProbeSession: Int = 0
    @Published var ownerStackProbeDirection: String = "none"
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
    @State private var probeCardBorderFrame: CGRect = .zero
    @State private var probeCardVisibleTopEdgeFrame: CGRect = .zero
    @State private var probeCardTopContainerFrame: CGRect = .zero
    @State private var probeRowContainerFrame: CGRect = .zero
    @State private var probeDetailRegionFrame: CGRect = .zero
    @State private var probeDetailClipContainerFrame: CGRect = .zero
    @State private var probeBoundaryFirstChildFrame: CGRect = .zero
    @State private var probeBelowBoundaryChildFrame: CGRect = .zero
    @State private var probeDetailVisibleHeight: CGFloat = 0
    @State private var probeSample: Int = 0
    @State private var probeLastSignature: String = ""
    @State private var probeDetailOpacitySample: Int = 0
    @State private var probeDetailOpacityLastSignature: String = ""
    @State private var probeDetailPhaseSample: Int = 0
    @State private var probeDetailPhaseLastSignature: String = ""
    @State private var probeGeometryScopeSample: Int = 0
    @State private var probeGeometryScopeLastSignature: String = ""
    @State private var probeGeometryTrigger: String = "initial"
    @State private var probeGeometryTriggerInheritedAnimationDuration: CGFloat = 0
    @State private var probeGeometryTriggerAnimationsEnabled: Bool = true
    @State private var probeRowToken: String = UUID().uuidString
    @State private var probeTopEdgeSample: Int = 0
    @State private var probeTopEdgeLastSignature: String = ""
    @State private var probeTopEdgeBaselineRowMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineCardOuterMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineCardBorderMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineCardVisibleTopEdgeMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineCardTopContainerMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineDetailClipContainerMinY: CGFloat? = nil
    @State private var probeTopEdgeBaselineCardOuterHeight: CGFloat? = nil
    @State private var probeTopEdgeBaselineDetailVisibleHeight: CGFloat? = nil
    @State private var probeTopEdgeReplayTargetID: UUID? = nil
    @State private var probeTopEdgeBeginReplayMessage: String? = nil
    @State private var probeTopEdgeEarlySampleMessages: [String] = []
    @State private var localStateReplayTargetID: UUID? = nil
    @State private var localStateReplayMessages: [String] = []
    private let detailProbeSampleStride: Int = 8
    private let detailProbeTerminalThreshold: CGFloat = 0.02
    private let topEdgeProbeMaxSamples: Int = 4
    private let topEdgeProbeReplaySampleCount: Int = 1
    private let geometryScopeProbeMaxSamples: Int = 4
    private let localStateReplayMaxSamples: Int = 4
    private let topEdgeStableEpsilon: CGFloat = 0.5
    private var probeGeometryCoordinateSpaceName: String {
        "log-row-probe-\(probeRowToken)"
    }

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
            let shouldPinHostedCardTop = isHeightAnimating && !isExpanded
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
                    updateGeometryTrigger("cardOuterFrame")
                    probeCardFrame = frame
                    traceCollapseBorderSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onCardBorderFrameChange: { frame in
                    updateGeometryTrigger("cardBorderFrame")
                    probeCardBorderFrame = frame
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onCardVisibleTopEdgeFrameChange: { frame in
                    updateGeometryTrigger("cardVisibleTopEdgeFrame")
                    probeCardVisibleTopEdgeFrame = frame
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onCardTopContainerFrameChange: { frame in
                    updateGeometryTrigger("cardTopContainerFrame")
                    probeCardTopContainerFrame = frame
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailRegionFrameChange: { frame in
                    updateGeometryTrigger("detailRegionFrame")
                    probeDetailRegionFrame = frame
                    traceGeometryScopeSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailClipContainerFrameChange: { frame in
                    updateGeometryTrigger("detailClipContainerFrame")
                    probeDetailClipContainerFrame = frame
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onBoundaryFirstChildFrameChange: { frame in
                    updateGeometryTrigger("boundaryFirstChildFrame")
                    probeBoundaryFirstChildFrame = frame
                    traceGeometryScopeSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onBelowBoundaryChildFrameChange: { frame in
                    updateGeometryTrigger("belowBoundaryChildFrame")
                    probeBelowBoundaryChildFrame = frame
                    traceGeometryScopeSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailHeightChange: { height in
                    updateGeometryTrigger("detailVisibleHeight")
                    probeDetailVisibleHeight = height
                    traceCollapseBorderSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                    traceGeometryScopeSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating
                    )
                    traceTopEdgeAnchorSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isHeightAnimating: isHeightAnimating
                    )
                },
                onDetailOpacityAnimatableSample: { rawOpacity, renderedOpacity, targetOpacity, visibilityGateOpen, frameHeightParam, intrinsicDetailHeight, visibleDetailHeight, transactionDisablesAnimations, inheritedAnimationDuration, inheritedAnimationsEnabled in
                    traceDetailPhaseSample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isHeightAnimating: isHeightAnimating,
                        detailFrameHeightParam: frameHeightParam,
                        detailVisibilityGateOpen: visibilityGateOpen,
                        detailTargetOpacity: targetOpacity
                    )
                    traceCollapseDetailOpacitySample(
                        logID: log.id,
                        renderIdentity: renderIdentity,
                        isExpanded: isExpanded,
                        isEditing: isEditing,
                        isHeightAnimating: isHeightAnimating,
                        rawOpacity: rawOpacity,
                        renderedOpacity: renderedOpacity,
                        targetOpacity: targetOpacity,
                        visibilityGateOpen: visibilityGateOpen,
                        frameHeightParam: frameHeightParam,
                        intrinsicDetailHeight: intrinsicDetailHeight,
                        visibleDetailHeight: visibleDetailHeight,
                        transactionDisablesAnimations: transactionDisablesAnimations,
                        inheritedAnimationDuration: inheritedAnimationDuration,
                        inheritedAnimationsEnabled: inheritedAnimationsEnabled
                    )
                },
                onLocalStateSnapshot: { reason, detailPresenceValue, intrinsicHeight, visibleHeight in
                    let phaseTargeted = tableState.phaseProbeTargetID == log.id
                    let collapseTargeted = tableState.collapseProbeTargetID == log.id
                    let editingTargeted = tableState.editingID == log.id
                    let expandedTargeted = tableState.expandedID == log.id
                    let shouldLogLocalState =
                        phaseTargeted
                        || collapseTargeted
                        || editingTargeted
                        || expandedTargeted
                        || reason.hasPrefix("isExpandedChanged")
                        || reason.hasPrefix("isEditingChanged")
                    guard shouldLogLocalState else { return }
                    let detailPresence = detailPresenceValue.map(formatted) ?? "nil"
                    let sampleMessage =
                        "\(renderIdentity) rowToken=\(probeRowToken) reason=\(reason) detailPresenceState=\(detailPresence) detailIntrinsicHeight=\(formatted(intrinsicHeight)) detailVisibleHeight=\(formatted(visibleHeight)) phaseTransitionSeq=\(tableState.phaseProbeTransitionSequence) phaseDirection=\(tableState.phaseProbeDirection) phaseRunOrdinal=\(tableState.phaseProbeRunOrdinal) phasePreviousDirection=\(tableState.phaseProbePreviousDirection) phasePriorEditSeq=\(tableState.phaseProbePriorEditSequence) phaseHasPriorEdit=\(tableState.phaseProbeHasPriorEdit) phaseEditDelta=\(tableState.phaseProbeEditDelta) phaseEditActiveForTarget=\(tableState.phaseProbeEditActiveForTarget) phaseTargeted=\(phaseTargeted)"
                    captureLocalStateReplayIfNeeded(
                        logID: log.id,
                        sampleMessage: sampleMessage,
                        stronglyTargeted: phaseTargeted || collapseTargeted || editingTargeted || expandedTargeted
                    )
                    traceHostedRow(
                        "swiftui.row.localStateProbe.sample",
                        sampleMessage
                    )
                },
                geometryCoordinateSpaceName: probeGeometryCoordinateSpaceName
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: shouldPinHostedCardTop ? .infinity : nil,
                alignment: .topLeading
            )
            .coordinateSpace(name: probeGeometryCoordinateSpaceName)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateGeometryTrigger("rowContainerFrame")
                            probeRowContainerFrame = proxy.frame(in: .named(probeGeometryCoordinateSpaceName))
                            traceGeometryScopeSample(
                                logID: log.id,
                                renderIdentity: renderIdentity,
                                isExpanded: isExpanded,
                                isEditing: isEditing,
                                isHeightAnimating: isHeightAnimating
                            )
                            traceTopEdgeAnchorSample(
                                logID: log.id,
                                renderIdentity: renderIdentity,
                                isHeightAnimating: isHeightAnimating
                            )
                        }
                        .onChange(of: proxy.frame(in: .named(probeGeometryCoordinateSpaceName))) { _, newFrame in
                            updateGeometryTrigger("rowContainerFrame")
                            probeRowContainerFrame = newFrame
                            traceGeometryScopeSample(
                                logID: log.id,
                                renderIdentity: renderIdentity,
                                isExpanded: isExpanded,
                                isEditing: isEditing,
                                isHeightAnimating: isHeightAnimating
                            )
                            traceTopEdgeAnchorSample(
                                logID: log.id,
                                renderIdentity: renderIdentity,
                                isHeightAnimating: isHeightAnimating
                            )
                        }
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
                if newValue {
                    probeGeometryScopeSample = 0
                    probeGeometryScopeLastSignature = ""
                } else {
                    probeGeometryScopeLastSignature = ""
                }
            }
            .onChange(of: tableState.collapseProbeSession) { _, _ in
                probeSample = 0
                probeLastSignature = ""
                probeDetailOpacitySample = 0
                probeDetailOpacityLastSignature = ""
                probeDetailPhaseSample = 0
                probeDetailPhaseLastSignature = ""
                probeGeometryScopeSample = 0
                probeGeometryScopeLastSignature = ""
                localStateReplayTargetID = nil
                localStateReplayMessages = []
            }
            .onChange(of: tableState.topEdgeProbeSession) { _, _ in
                probeTopEdgeSample = 0
                probeTopEdgeLastSignature = ""
                probeTopEdgeBaselineRowMinY = nil
                probeTopEdgeBaselineCardOuterMinY = nil
                probeTopEdgeBaselineCardBorderMinY = nil
                probeTopEdgeBaselineCardVisibleTopEdgeMinY = nil
                probeTopEdgeBaselineCardTopContainerMinY = nil
                probeTopEdgeBaselineDetailClipContainerMinY = nil
                probeTopEdgeBaselineCardOuterHeight = nil
                probeTopEdgeBaselineDetailVisibleHeight = nil
                probeTopEdgeReplayTargetID = nil
                probeTopEdgeBeginReplayMessage = nil
                probeTopEdgeEarlySampleMessages = []
            }
            .onChange(of: tableState.collapseProbeActive) { _, isActive in
                if !isActive {
                    probeLastSignature = ""
                    probeDetailOpacityLastSignature = ""
                    probeDetailPhaseLastSignature = ""
                    emitLocalStateReplayIfNeeded(logID: log.id)
                }
            }
            .onChange(of: tableState.topEdgeProbeActive) { _, isActive in
                if isActive {
                    captureTopEdgeBeginReplayMessageIfNeeded(logID: log.id)
                    return
                }
                emitTopEdgeReplayIfNeeded(logID: log.id)
                probeTopEdgeLastSignature = ""
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

    private func updateGeometryTrigger(_ source: String) {
        probeGeometryTrigger = source
        probeGeometryTriggerInheritedAnimationDuration = UIView.inheritedAnimationDuration
        probeGeometryTriggerAnimationsEnabled = UIView.areAnimationsEnabled
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

    private func traceCollapseDetailOpacitySample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isEditing: Bool,
        isHeightAnimating: Bool,
        rawOpacity: CGFloat,
        renderedOpacity: CGFloat,
        targetOpacity: CGFloat,
        visibilityGateOpen: Bool,
        frameHeightParam: CGFloat?,
        intrinsicDetailHeight: CGFloat,
        visibleDetailHeight: CGFloat,
        transactionDisablesAnimations: Bool,
        inheritedAnimationDuration: CGFloat,
        inheritedAnimationsEnabled: Bool
    ) {
        guard tableState.collapseProbeActive else { return }
        guard tableState.collapseProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        let raw = formatted(rawOpacity)
        let rendered = formatted(renderedOpacity)
        let target = formatted(targetOpacity)
        let gateOpen = visibilityGateOpen ? "true" : "false"
        let frameHeight = frameHeightParam.map(formatted) ?? "nil"
        let intrinsicHeight = formatted(intrinsicDetailHeight)
        let visibleHeight = formatted(visibleDetailHeight)
        let txDisablesAnimations = transactionDisablesAnimations ? "true" : "false"
        let inheritedDuration = formatted(inheritedAnimationDuration)
        let inheritedEnabled = inheritedAnimationsEnabled ? "true" : "false"
        let signature = "\(raw)|\(rendered)|\(target)|\(gateOpen)|\(frameHeight)|\(intrinsicHeight)|\(visibleHeight)|\(txDisablesAnimations)|\(inheritedDuration)|\(inheritedEnabled)|\(isExpanded)|\(isEditing)|\(tableState.layoutPassID)"
        guard signature != probeDetailOpacityLastSignature else { return }
        probeDetailOpacityLastSignature = signature
        probeDetailOpacitySample += 1
        let sampleIndex = probeDetailOpacitySample
        guard shouldEmitDetailProbeSample(sampleIndex: sampleIndex, progress: rawOpacity) else { return }
        traceHostedRow(
            "swiftui.row.detailOpacityProbe.sample",
            "\(renderIdentity) probeSession=\(tableState.collapseProbeSession) probeSample=\(sampleIndex) rowToken=\(probeRowToken) rawAnimatableOpacity=\(raw) renderedOpacity=\(rendered) targetOpacity=\(target) visibilityGateOpen=\(gateOpen) detailFrameHeightParam=\(frameHeight) detailIntrinsicHeight=\(intrinsicHeight) detailVisibleHeight=\(visibleHeight) txDisablesAnimations=\(txDisablesAnimations) inheritedAnimationDuration=\(inheritedDuration) inheritedAnimationsEnabled=\(inheritedEnabled) targetID=\(logID.uuidString)"
        )
    }

    private func traceDetailPhaseSample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isHeightAnimating: Bool,
        detailFrameHeightParam: CGFloat?,
        detailVisibilityGateOpen: Bool,
        detailTargetOpacity: CGFloat
    ) {
        guard isHeightAnimating else { return }
        let collapseProbeActive = tableState.collapseProbeActive
        let collapseProbeTargeted = collapseProbeActive && tableState.collapseProbeTargetID == logID
        let transitionDirection = detailTransitionDirection(
            isExpanded: isExpanded,
            isHeightAnimating: isHeightAnimating,
            collapseProbeTargeted: collapseProbeTargeted
        )
        let detailPhase = detailPhaseLabel(
            isExpanded: isExpanded,
            isHeightAnimating: isHeightAnimating,
            detailFrameHeightParam: detailFrameHeightParam,
            detailVisibilityGateOpen: detailVisibilityGateOpen,
            detailTargetOpacity: detailTargetOpacity
        )
        let frameHeight = detailFrameHeightParam.map(formatted) ?? "nil"
        let gateOpen = detailVisibilityGateOpen ? "true" : "false"
        let targetOpacity = formatted(detailTargetOpacity)
        let signature = "\(isExpanded)|\(isHeightAnimating)|\(frameHeight)|\(gateOpen)|\(targetOpacity)|\(transitionDirection)|\(detailPhase)|\(collapseProbeActive)|\(collapseProbeTargeted)|\(tableState.layoutPassID)"
        guard signature != probeDetailPhaseLastSignature else { return }
        probeDetailPhaseLastSignature = signature
        probeDetailPhaseSample += 1
        traceHostedRow(
            "swiftui.row.detailPhaseProbe.sample",
            "\(renderIdentity) probeSample=\(probeDetailPhaseSample) rowToken=\(probeRowToken) transitionDirection=\(transitionDirection) detailPhase=\(detailPhase) isExpanded=\(isExpanded) isHeightAnimating=\(isHeightAnimating) detailFrameHeightParam=\(frameHeight) detailVisibilityGateOpen=\(gateOpen) detailTargetOpacity=\(targetOpacity) collapseProbeActive=\(collapseProbeActive) collapseProbeTargeted=\(collapseProbeTargeted) \(phaseProbeContext(logID: logID)) \(siblingProbeContext(logID: logID)) targetID=\(logID.uuidString)"
        )
    }

    private func detailTransitionDirection(
        isExpanded: Bool,
        isHeightAnimating: Bool,
        collapseProbeTargeted: Bool
    ) -> String {
        if !isHeightAnimating { return "none" }
        if collapseProbeTargeted { return "collapse" }
        return isExpanded ? "expand" : "indeterminate_nonexpanded"
    }

    private func detailPhaseLabel(
        isExpanded: Bool,
        isHeightAnimating: Bool,
        detailFrameHeightParam: CGFloat?,
        detailVisibilityGateOpen: Bool,
        detailTargetOpacity: CGFloat
    ) -> String {
        if !isHeightAnimating {
            return isExpanded ? "settled_expanded" : "settled_collapsed"
        }
        let frameHeightValue = detailFrameHeightParam ?? 0
        let frameHeightLooksVisible = detailFrameHeightParam == nil || frameHeightValue > 0
        if detailVisibilityGateOpen && detailTargetOpacity > 0 && frameHeightLooksVisible {
            return "animating_open_gate_target_visible"
        }
        if detailVisibilityGateOpen && detailTargetOpacity == 0 {
            return "animating_open_gate_target_hidden"
        }
        if !detailVisibilityGateOpen && detailTargetOpacity == 0 {
            return "animating_closed_gate_target_hidden"
        }
        return "animating_mixed"
    }

    private func traceGeometryScopeSample(
        logID: UUID,
        renderIdentity: String,
        isExpanded: Bool,
        isEditing: Bool,
        isHeightAnimating: Bool
    ) {
        guard tableState.collapseProbeActive else { return }
        guard tableState.collapseProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        guard probeGeometryScopeSample < geometryScopeProbeMaxSamples else { return }
        let rowMinY = formatted(probeRowContainerFrame.minY)
        let rowMaxY = formatted(probeRowContainerFrame.maxY)
        let rowHeight = formatted(probeRowContainerFrame.height)
        let cardOuterMinY = formatted(probeCardFrame.minY)
        let cardOuterMaxY = formatted(probeCardFrame.maxY)
        let cardOuterHeight = formatted(probeCardFrame.height)
        let detailRegionMinY = formatted(probeDetailRegionFrame.minY)
        let detailRegionMaxY = formatted(probeDetailRegionFrame.maxY)
        let detailRegionHeight = formatted(probeDetailRegionFrame.height)
        let firstChildMinY = formatted(probeBoundaryFirstChildFrame.minY)
        let firstChildMaxY = formatted(probeBoundaryFirstChildFrame.maxY)
        let firstChildHeight = formatted(probeBoundaryFirstChildFrame.height)
        let belowChildMinY = formatted(probeBelowBoundaryChildFrame.minY)
        let belowChildMaxY = formatted(probeBelowBoundaryChildFrame.maxY)
        let belowChildHeight = formatted(probeBelowBoundaryChildFrame.height)
        let belowDelta = formatted(probeBelowBoundaryChildFrame.minY - probeDetailRegionFrame.minY)
        let firstChildToDetailDelta = formatted(probeBoundaryFirstChildFrame.minY - probeDetailRegionFrame.minY)
        let belowChildToFirstChildDelta = formatted(probeBelowBoundaryChildFrame.minY - probeBoundaryFirstChildFrame.minY)
        let detailVisibleHeight = formatted(probeDetailVisibleHeight)
        let triggerAnimationDuration = formatted(probeGeometryTriggerInheritedAnimationDuration)
        let triggerAnimationsEnabled = probeGeometryTriggerAnimationsEnabled ? "true" : "false"

        let signature = "\(rowMinY)|\(rowMaxY)|\(rowHeight)|\(cardOuterMinY)|\(cardOuterMaxY)|\(cardOuterHeight)|\(detailRegionMinY)|\(detailRegionMaxY)|\(detailRegionHeight)|\(firstChildMinY)|\(firstChildMaxY)|\(firstChildHeight)|\(belowChildMinY)|\(belowChildMaxY)|\(belowChildHeight)|\(belowDelta)|\(firstChildToDetailDelta)|\(belowChildToFirstChildDelta)|\(detailVisibleHeight)|\(isExpanded)|\(isEditing)|\(tableState.layoutPassID)|\(probeGeometryTrigger)|\(triggerAnimationDuration)|\(triggerAnimationsEnabled)"
        guard signature != probeGeometryScopeLastSignature else { return }
        probeGeometryScopeLastSignature = signature
        probeGeometryScopeSample += 1

        traceHostedRow(
            "swiftui.row.geometryScopeProbe.sample",
            "\(renderIdentity) probeSession=\(tableState.collapseProbeSession) probeSample=\(probeGeometryScopeSample) rowToken=\(probeRowToken) coordinateSpace=rowLocal trigger=\(probeGeometryTrigger) triggerInheritedAnimationDuration=\(triggerAnimationDuration) triggerAnimationsEnabled=\(triggerAnimationsEnabled) rowMinY=\(rowMinY) rowMaxY=\(rowMaxY) rowHeight=\(rowHeight) cardOuterMinY=\(cardOuterMinY) cardOuterMaxY=\(cardOuterMaxY) cardOuterHeight=\(cardOuterHeight) detailRegionMinY=\(detailRegionMinY) detailRegionMaxY=\(detailRegionMaxY) detailRegionHeight=\(detailRegionHeight) boundaryFirstChildMinY=\(firstChildMinY) boundaryFirstChildMaxY=\(firstChildMaxY) boundaryFirstChildHeight=\(firstChildHeight) belowBoundaryChildMinY=\(belowChildMinY) belowBoundaryChildMaxY=\(belowChildMaxY) belowBoundaryChildHeight=\(belowChildHeight) belowBoundaryDeltaY=\(belowDelta) firstChildToDetailDeltaY=\(firstChildToDetailDelta) belowChildToFirstChildDeltaY=\(belowChildToFirstChildDelta) boundaryTopPadding=12.000 boundaryContentSpacing=8.000 boundaryFirstChildHorizontalPadding=12.000 detailVisibleHeight=\(detailVisibleHeight) targetID=\(logID.uuidString)"
        )
    }

    private func traceTopEdgeAnchorSample(
        logID: UUID,
        renderIdentity: String,
        isHeightAnimating: Bool
    ) {
        guard tableState.topEdgeProbeActive else { return }
        guard tableState.topEdgeProbeTargetID == logID else { return }
        guard isHeightAnimating else { return }
        guard probeTopEdgeSample < topEdgeProbeMaxSamples else { return }
        guard probeCardFrame.height > 0 else { return }
        guard probeCardVisibleTopEdgeFrame.height > 0 else { return }

        let rowMinYValue = probeRowContainerFrame.minY
        let cardOuterMinYValue = probeCardFrame.minY
        let cardBorderMinYValue = probeCardBorderFrame.minY
        let cardVisibleTopEdgeMinYValue = probeCardVisibleTopEdgeFrame.minY
        let cardTopContainerMinYValue = probeCardTopContainerFrame.minY
        let detailClipContainerMinYValue = probeDetailClipContainerFrame.minY
        let cardOuterHeightValue = probeCardFrame.height
        let detailVisibleHeightValue = probeDetailVisibleHeight

        if probeTopEdgeBaselineRowMinY == nil {
            probeTopEdgeBaselineRowMinY = rowMinYValue
            probeTopEdgeBaselineCardOuterMinY = cardOuterMinYValue
            probeTopEdgeBaselineCardBorderMinY = cardBorderMinYValue
            probeTopEdgeBaselineCardVisibleTopEdgeMinY = cardVisibleTopEdgeMinYValue
            probeTopEdgeBaselineCardTopContainerMinY = cardTopContainerMinYValue
            probeTopEdgeBaselineDetailClipContainerMinY = detailClipContainerMinYValue
            probeTopEdgeBaselineCardOuterHeight = cardOuterHeightValue
            probeTopEdgeBaselineDetailVisibleHeight = detailVisibleHeightValue
        }

        let baselineRowMinY = probeTopEdgeBaselineRowMinY ?? rowMinYValue
        let baselineCardOuterMinY = probeTopEdgeBaselineCardOuterMinY ?? cardOuterMinYValue
        let baselineCardBorderMinY = probeTopEdgeBaselineCardBorderMinY ?? cardBorderMinYValue
        let baselineCardVisibleTopEdgeMinY = probeTopEdgeBaselineCardVisibleTopEdgeMinY ?? cardVisibleTopEdgeMinYValue
        let baselineCardTopContainerMinY = probeTopEdgeBaselineCardTopContainerMinY ?? cardTopContainerMinYValue
        let baselineDetailClipContainerMinY = probeTopEdgeBaselineDetailClipContainerMinY ?? detailClipContainerMinYValue
        let baselineCardOuterHeight = probeTopEdgeBaselineCardOuterHeight ?? cardOuterHeightValue
        let baselineDetailVisibleHeight = probeTopEdgeBaselineDetailVisibleHeight ?? detailVisibleHeightValue

        let rowMinYShiftFromStart = rowMinYValue - baselineRowMinY
        let cardOuterMinYShiftFromStart = cardOuterMinYValue - baselineCardOuterMinY
        let cardBorderMinYShiftFromStart = cardBorderMinYValue - baselineCardBorderMinY
        let cardVisibleTopEdgeMinYShiftFromStart = cardVisibleTopEdgeMinYValue - baselineCardVisibleTopEdgeMinY
        let cardTopContainerMinYShiftFromStart = cardTopContainerMinYValue - baselineCardTopContainerMinY
        let detailClipContainerMinYShiftFromStart = detailClipContainerMinYValue - baselineDetailClipContainerMinY
        let cardOuterHeightShiftFromStart = cardOuterHeightValue - baselineCardOuterHeight
        let detailVisibleHeightShiftFromStart = detailVisibleHeightValue - baselineDetailVisibleHeight

        let rowMinY = formatted(rowMinYValue)
        let cardOuterMinY = formatted(cardOuterMinYValue)
        let cardBorderMinY = formatted(cardBorderMinYValue)
        let cardVisibleTopEdgeMinY = formatted(cardVisibleTopEdgeMinYValue)
        let cardTopContainerMinY = formatted(cardTopContainerMinYValue)
        let detailClipContainerMinY = formatted(detailClipContainerMinYValue)
        let cardOuterHeight = formatted(cardOuterHeightValue)
        let detailVisibleHeight = formatted(detailVisibleHeightValue)
        let rowToCardOuterTopDelta = formatted(cardOuterMinYValue - rowMinYValue)
        let outerToBorderTopDelta = formatted(cardBorderMinYValue - cardOuterMinYValue)
        let visibleTopEdgeToOuterTopDelta = formatted(cardVisibleTopEdgeMinYValue - cardOuterMinYValue)
        let visibleTopEdgeToBorderTopDelta = formatted(cardVisibleTopEdgeMinYValue - cardBorderMinYValue)
        let visibleTopEdgeToTopContainerTopDelta = formatted(cardVisibleTopEdgeMinYValue - cardTopContainerMinYValue)
        let detailClipToOuterTopDelta = formatted(detailClipContainerMinYValue - cardOuterMinYValue)
        let detailClipToVisibleTopEdgeDelta = formatted(detailClipContainerMinYValue - cardVisibleTopEdgeMinYValue)
        let outerToTopContainerTopDelta = formatted(cardTopContainerMinYValue - cardOuterMinYValue)
        let rowShift = formatted(rowMinYShiftFromStart)
        let cardOuterShift = formatted(cardOuterMinYShiftFromStart)
        let cardBorderShift = formatted(cardBorderMinYShiftFromStart)
        let cardVisibleTopEdgeShift = formatted(cardVisibleTopEdgeMinYShiftFromStart)
        let cardTopContainerShift = formatted(cardTopContainerMinYShiftFromStart)
        let detailClipContainerShift = formatted(detailClipContainerMinYShiftFromStart)
        let cardOuterHeightShift = formatted(cardOuterHeightShiftFromStart)
        let detailVisibleHeightShift = formatted(detailVisibleHeightShiftFromStart)
        let topEdgeMovedBeforeHeightSettles =
            abs(cardOuterMinYShiftFromStart) > topEdgeStableEpsilon
            && abs(cardOuterHeightShiftFromStart) <= topEdgeStableEpsilon
            ? "true"
            : "false"
        let direction = tableState.topEdgeProbeDirection
        let signature = "\(rowMinY)|\(cardOuterMinY)|\(cardBorderMinY)|\(cardVisibleTopEdgeMinY)|\(cardTopContainerMinY)|\(detailClipContainerMinY)|\(cardOuterHeight)|\(detailVisibleHeight)|\(rowShift)|\(cardOuterShift)|\(cardBorderShift)|\(cardVisibleTopEdgeShift)|\(cardTopContainerShift)|\(detailClipContainerShift)|\(cardOuterHeightShift)|\(detailVisibleHeightShift)|\(direction)|\(probeGeometryTrigger)|\(tableState.layoutPassID)"
        guard signature != probeTopEdgeLastSignature else { return }
        probeTopEdgeLastSignature = signature
        probeTopEdgeSample += 1
        captureTopEdgeBeginReplayMessageIfNeeded(logID: logID)
        let sampleMessage =
            "\(renderIdentity) probeSession=\(tableState.topEdgeProbeSession) probeSample=\(probeTopEdgeSample) probeSampleLimit=\(topEdgeProbeMaxSamples) rowToken=\(probeRowToken) coordinateSpace=rowLocal direction=\(direction) trigger=\(probeGeometryTrigger) rowMinY=\(rowMinY) cardOuterMinY=\(cardOuterMinY) cardBorderMinY=\(cardBorderMinY) cardVisibleTopEdgeMinY=\(cardVisibleTopEdgeMinY) cardTopContainerMinY=\(cardTopContainerMinY) detailClipContainerMinY=\(detailClipContainerMinY) cardOuterHeight=\(cardOuterHeight) detailVisibleHeight=\(detailVisibleHeight) rowToCardOuterTopDeltaY=\(rowToCardOuterTopDelta) outerToBorderTopDeltaY=\(outerToBorderTopDelta) visibleTopEdgeToOuterTopDeltaY=\(visibleTopEdgeToOuterTopDelta) visibleTopEdgeToBorderTopDeltaY=\(visibleTopEdgeToBorderTopDelta) visibleTopEdgeToTopContainerTopDeltaY=\(visibleTopEdgeToTopContainerTopDelta) detailClipToOuterTopDeltaY=\(detailClipToOuterTopDelta) detailClipToVisibleTopEdgeDeltaY=\(detailClipToVisibleTopEdgeDelta) outerToTopContainerTopDeltaY=\(outerToTopContainerTopDelta) rowMinYShiftFromStart=\(rowShift) cardOuterMinYShiftFromStart=\(cardOuterShift) cardBorderMinYShiftFromStart=\(cardBorderShift) cardVisibleTopEdgeMinYShiftFromStart=\(cardVisibleTopEdgeShift) cardTopContainerMinYShiftFromStart=\(cardTopContainerShift) detailClipContainerMinYShiftFromStart=\(detailClipContainerShift) cardOuterHeightShiftFromStart=\(cardOuterHeightShift) detailVisibleHeightShiftFromStart=\(detailVisibleHeightShift) topEdgeMovedBeforeHeightSettles=\(topEdgeMovedBeforeHeightSettles) \(phaseProbeContext(logID: logID)) \(siblingProbeContext(logID: logID)) \(ownerStackProbeContext(logID: logID)) targetID=\(logID.uuidString)"
        if probeTopEdgeEarlySampleMessages.count < topEdgeProbeReplaySampleCount {
            probeTopEdgeEarlySampleMessages.append(sampleMessage)
        }

        traceHostedRow(
            "swiftui.row.topAnchorProbe.sample",
            sampleMessage
        )
    }

    private func captureTopEdgeBeginReplayMessageIfNeeded(logID: UUID) {
        guard tableState.topEdgeProbeTargetID == logID else { return }
        guard probeTopEdgeBeginReplayMessage == nil else { return }
        probeTopEdgeReplayTargetID = logID
        probeTopEdgeBeginReplayMessage =
            "session=\(tableState.topEdgeProbeSession) direction=\(tableState.topEdgeProbeDirection) target=\(logID.uuidString) rowToken=\(probeRowToken)"
    }

    private func emitTopEdgeReplayIfNeeded(logID: UUID) {
        guard probeTopEdgeReplayTargetID == logID else { return }
        guard let beginMessage = probeTopEdgeBeginReplayMessage else { return }
        traceHostedRow("probe.topEdge.begin", "\(beginMessage) replay=tail")
        for sampleMessage in probeTopEdgeEarlySampleMessages.prefix(topEdgeProbeReplaySampleCount) {
            traceHostedRow("swiftui.row.topAnchorProbe.sample", "\(sampleMessage) replay=tail")
        }
        probeTopEdgeReplayTargetID = nil
        probeTopEdgeBeginReplayMessage = nil
        probeTopEdgeEarlySampleMessages = []
    }

    private func captureLocalStateReplayIfNeeded(
        logID: UUID,
        sampleMessage: String,
        stronglyTargeted: Bool
    ) {
        if localStateReplayTargetID == nil {
            guard stronglyTargeted else { return }
            localStateReplayTargetID = logID
        }
        guard localStateReplayTargetID == logID else { return }
        guard localStateReplayMessages.last != sampleMessage else { return }
        localStateReplayMessages.append(sampleMessage)
        if localStateReplayMessages.count > localStateReplayMaxSamples {
            localStateReplayMessages.removeFirst(localStateReplayMessages.count - localStateReplayMaxSamples)
        }
    }

    private func emitLocalStateReplayIfNeeded(logID: UUID) {
        guard localStateReplayTargetID == logID else { return }
        for sampleMessage in localStateReplayMessages {
            traceHostedRow("swiftui.row.localStateProbe.sample", "\(sampleMessage) replay=tail")
        }
        localStateReplayTargetID = nil
        localStateReplayMessages = []
    }

    private func phaseProbeContext(logID: UUID) -> String {
        let targeted = tableState.phaseProbeTargetID == logID
        return "phaseTargeted=\(targeted) phaseTransitionSeq=\(tableState.phaseProbeTransitionSequence) phaseDirection=\(tableState.phaseProbeDirection) phaseRunOrdinal=\(tableState.phaseProbeRunOrdinal) phasePreviousDirection=\(tableState.phaseProbePreviousDirection) phasePreviousTransitionSeq=\(tableState.phaseProbePreviousTransitionSequence) phasePriorEditSeq=\(tableState.phaseProbePriorEditSequence) phaseHasPriorEdit=\(tableState.phaseProbeHasPriorEdit) phaseEditDelta=\(tableState.phaseProbeEditDelta) phaseEditActiveForTarget=\(tableState.phaseProbeEditActiveForTarget)"
    }

    private func siblingProbeContext(logID: UUID) -> String {
        let targetMatch = tableState.siblingProbeTargetID == logID
        return "siblingProbeActive=\(tableState.siblingProbeActive) siblingProbeSession=\(tableState.siblingProbeSession) siblingProbeTargeted=\(targetMatch) siblingProbeTargetID=\(tableState.siblingProbeTargetID?.uuidString ?? "nil") siblingProbeNextID=\(tableState.siblingProbeNextID?.uuidString ?? "nil")"
    }

    private func ownerStackProbeContext(logID: UUID) -> String {
        let targetMatch = tableState.ownerStackProbeTargetID == logID
        return "ownerStackProbeActive=\(tableState.ownerStackProbeActive) ownerStackProbeSession=\(tableState.ownerStackProbeSession) ownerStackProbeDirection=\(tableState.ownerStackProbeDirection) ownerStackProbeTargeted=\(targetMatch) ownerStackProbeTargetID=\(tableState.ownerStackProbeTargetID?.uuidString ?? "nil")"
    }

    private func shouldEmitDetailProbeSample(sampleIndex: Int, progress: CGFloat) -> Bool {
        if sampleIndex <= 2 { return true }
        if sampleIndex % detailProbeSampleStride == 0 { return true }
        if progress <= detailProbeTerminalThreshold { return true }
        return false
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

    func ownerLayerSnapshot(in tableView: UITableView) -> HostOwnerLayerSnapshot? {
        guard let host = hostingController else { return nil }
        let hostView = host.view
        let rootView = hostView.subviews.first
        let hostFrameInTable = hostView.convert(hostView.bounds, to: tableView)
        let rootFrameInTable: CGRect
        if let rootView {
            rootFrameInTable = rootView.convert(rootView.bounds, to: tableView)
        } else {
            rootFrameInTable = .zero
        }
        return HostOwnerLayerSnapshot(
            hostPointer: pointerString(hostView),
            hostFrameInTable: hostFrameInTable,
            hostClipsToBounds: hostView.clipsToBounds,
            hostMasksToBounds: hostView.layer.masksToBounds,
            hostCompositingFilterActive: hostView.layer.compositingFilter != nil,
            hostAllowsGroupOpacity: hostView.layer.allowsGroupOpacity,
            hostAlpha: hostView.alpha,
            hostHidden: hostView.isHidden,
            swiftUIRootPointer: rootView.map { pointerString($0) },
            swiftUIRootFrameInTable: rootFrameInTable,
            swiftUIRootClipsToBounds: rootView?.clipsToBounds ?? false,
            swiftUIRootMasksToBounds: rootView?.layer.masksToBounds ?? false,
            swiftUIRootCompositingFilterActive: rootView?.layer.compositingFilter != nil,
            swiftUIRootAllowsGroupOpacity: rootView?.layer.allowsGroupOpacity ?? false,
            swiftUIRootAlpha: rootView?.alpha ?? 0,
            swiftUIRootHidden: rootView?.isHidden ?? true
        )
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
    let onCardBorderFrameChange: (CGRect) -> Void
    let onCardVisibleTopEdgeFrameChange: (CGRect) -> Void
    let onCardTopContainerFrameChange: (CGRect) -> Void
    let onDetailRegionFrameChange: (CGRect) -> Void
    let onDetailClipContainerFrameChange: (CGRect) -> Void
    let onBoundaryFirstChildFrameChange: (CGRect) -> Void
    let onBelowBoundaryChildFrameChange: (CGRect) -> Void
    let onDetailHeightChange: (CGFloat) -> Void
    let onDetailOpacityAnimatableSample: (CGFloat, CGFloat, CGFloat, Bool, CGFloat?, CGFloat, CGFloat, Bool, CGFloat, Bool) -> Void
    let onLocalStateSnapshot: (String, CGFloat?, CGFloat, CGFloat) -> Void
    let geometryCoordinateSpaceName: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var detailPresence: CGFloat? = nil
    @State private var detailIntrinsicHeight: CGFloat = 0
    @State private var detailVisibleHeight: CGFloat = 0
    private enum MacroTarget {
        static let calories = 2000.0
        static let protein = 50.0
        static let carbs = 275.0
        static let fat = 78.0
    }

    var body: some View {
        let resolvedDetailPresence = min(max(detailPresence ?? (isExpanded ? 1 : 0), 0), 1)
        let collapseClampedDetailPresence = isExpanded ? resolvedDetailPresence : 0
        let detailFrameHeightValue = detailIntrinsicHeight * collapseClampedDetailPresence
        let detailVisibilityGateOpen = collapseClampedDetailPresence > 0.001
        let detailFrameHeight: CGFloat? = collapseClampedDetailPresence >= 0.999 ? nil : detailFrameHeightValue
        let detailTargetOpacity: CGFloat = collapseClampedDetailPresence
        let microContent = VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 12)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                onBoundaryFirstChildFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                            }
                            .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                onBoundaryFirstChildFrameChange(newFrame)
                            }
                    }
                )
            Text("Micronutrients")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MicronutrientGrid(items: log.micronutrientItems)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                onBelowBoundaryChildFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                            }
                            .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                onBelowBoundaryChildFrameChange(newFrame)
                            }
                    }
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)

        VStack(spacing: 0) {
            editableHeader
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                onCardTopContainerFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                            }
                            .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                onCardTopContainerFrameChange(newFrame)
                            }
                    }
                )

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
                .frame(height: detailFrameHeight, alignment: .top)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                onDetailRegionFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                            }
                            .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                onDetailRegionFrameChange(newFrame)
                            }
                    }
                )
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
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                onDetailClipContainerFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                            }
                            .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                onDetailClipContainerFrameChange(newFrame)
                            }
                    }
                )
                .clipped()
                .modifier(
                    DetailOpacityAnimatableProbeModifier(
                        opacity: detailTargetOpacity,
                        isVisibilityGateOpen: detailVisibilityGateOpen,
                        onSample: { rawOpacity, renderedOpacity, visibilityGateOpen in
                            onDetailOpacityAnimatableSample(
                                rawOpacity,
                                renderedOpacity,
                                detailTargetOpacity,
                                visibilityGateOpen,
                                detailFrameHeight,
                                detailIntrinsicHeight,
                                detailVisibleHeight,
                                isHeightAnimating && isExpanded,
                                UIView.inheritedAnimationDuration,
                                UIView.areAnimationsEnabled
                            )
                        }
                    )
                )
                .accessibilityHidden(!detailVisibilityGateOpen)
                .animation(.easeInOut(duration: 0.25), value: collapseClampedDetailPresence)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(corners: .allCorners))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onCardFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                    }
                    .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
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
        .onAppear {
            if detailPresence == nil {
                detailPresence = isExpanded ? 1 : 0
            }
            onLocalStateSnapshot(
                "onAppear",
                detailPresence,
                detailIntrinsicHeight,
                detailVisibleHeight
            )
        }
        .onChange(of: log.id) { _, _ in
            detailPresence = isExpanded ? 1 : 0
            onLocalStateSnapshot(
                "logIDChanged",
                detailPresence,
                detailIntrinsicHeight,
                detailVisibleHeight
            )
        }
        .onChange(of: isExpanded) { _, newValue in
            onLocalStateSnapshot(
                "isExpandedChanged.before.new=\(newValue)",
                detailPresence,
                detailIntrinsicHeight,
                detailVisibleHeight
            )
            if newValue {
                withAnimation(.easeInOut(duration: 0.25)) {
                    detailPresence = 1
                }
            } else {
                detailPresence = 0
                detailVisibleHeight = 0
                onDetailHeightChange(0)
            }
            onLocalStateSnapshot(
                "isExpandedChanged.after.new=\(newValue)",
                detailPresence,
                detailIntrinsicHeight,
                detailVisibleHeight
            )
        }
        .onChange(of: isEditing) { _, newValue in
            onLocalStateSnapshot(
                "isEditingChanged.new=\(newValue)",
                detailPresence,
                detailIntrinsicHeight,
                detailVisibleHeight
            )
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
            .overlay(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onCardBorderFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                        }
                        .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                            onCardBorderFrameChange(newFrame)
                        }
                }
            )
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: 1)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    onCardVisibleTopEdgeFrameChange(proxy.frame(in: .named(geometryCoordinateSpaceName)))
                                }
                                .onChange(of: proxy.frame(in: .named(geometryCoordinateSpaceName))) { _, newFrame in
                                    onCardVisibleTopEdgeFrameChange(newFrame)
                                }
                        }
                    )
            }
    }
}

private struct DetailOpacityAnimatableProbeModifier: AnimatableModifier {
    var opacity: CGFloat
    var isVisibilityGateOpen: Bool
    let onSample: (CGFloat, CGFloat, Bool) -> Void

    var animatableData: CGFloat {
        get { opacity }
        set {
            opacity = newValue
            let rawOpacity = newValue
            let gateOpen = isVisibilityGateOpen
            let renderedOpacity = gateOpen ? rawOpacity : 0
            let sample = onSample
            DispatchQueue.main.async {
                sample(rawOpacity, renderedOpacity, gateOpen)
            }
        }
    }

    func body(content: Content) -> some View {
        content.opacity(isVisibilityGateOpen ? opacity : 0)
    }
}
