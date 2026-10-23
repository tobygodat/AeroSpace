import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        reconcileFloatingLayout()
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        if layout == .scrolling {
            try await layoutScrolling(rect, LayoutContext(self))
            return
        }
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }

    /// Scrolling layout. The root's children are columns on a strip that can be wider than `rect`; `scrollOffset`
    /// is moved just enough to keep the focused column in view. Columns in view are laid out at real coordinates
    /// with `layoutRecursive` (so fullscreen, gaps and columns' own tiles/accordion all behave); columns out of
    /// view are parked at the edge of `rect` with one point visible, since macOS pulls a window back on screen
    /// only when nothing of it is visible. Floating windows are laid out as usual
    @MainActor
    fileprivate func layoutScrolling(_ rect: Rect, _ context: LayoutContext) async throws {
        lastAppliedLayoutPhysicalRect = rect
        lastAppliedLayoutVirtualRect = rect
        let root = rootTilingContainer
        // A lone column is a direct child of the root, so `layout accordion` or `layout vertical` on it lands on
        // the root. The strip stays horizontal tiles, or column weights would stop meaning widths
        root.layout = .tiles
        root.setOrientationOnly(.h)
        root.lastAppliedLayoutPhysicalRect = rect
        root.lastAppliedLayoutVirtualRect = rect

        let gap = context.resolvedGaps.inner.horizontal.toDouble()
        var widths: [CGFloat] = []
        var starts: [CGFloat] = []
        var total: CGFloat = 0
        for column in root.children {
            let weight = column.getWeight(.h)
            // WEIGHT_AUTO into an empty root and a flattened container both leave a weight of 1
            let width = min(weight < rect.width / 10 ? defaultScrollingColumnWidth : weight, rect.width)
            column.setWeight(.h, width)
            let start = starts.isEmpty ? 0 : total + gap
            starts.append(start)
            widths.append(width)
            total = start + width
        }

        if let focused = root.mostRecentChild?.ownIndex {
            var offset = scrollOffset
            if starts[focused] < offset { offset = starts[focused] }
            if starts[focused] + widths[focused] > offset + rect.width { offset = starts[focused] + widths[focused] - rect.width }
            scrollOffset = offset.coerce(in: 0 ... max(0, total - rect.width))
        }

        func park(_ node: TreeNode, at frame: Rect, virtual: Rect) {
            if let window = node as? Window {
                if window.windowId == currentlyManipulatedWithMouseWindowId { return }
                window.isFullscreen = false
                window.setAxFrame(frame.topLeftCorner, frame.size)
            }
            node.lastAppliedLayoutPhysicalRect = frame
            node.lastAppliedLayoutVirtualRect = virtual
            for child in node.children {
                park(child, at: frame, virtual: virtual)
            }
        }
        for (i, column) in root.children.enumerated() {
            let (x, width) = (rect.minX + starts[i] - scrollOffset, widths[i])
            let virtual = Rect(topLeftX: x, topLeftY: rect.minY, width: width, height: rect.height)
            if x < rect.maxX && x + width > rect.minX {
                try await column.layoutRecursive(CGPoint(x: x, y: rect.minY), width: width, height: rect.height - 1, virtual: virtual, context)
            } else {
                let parkedX = x < rect.minX ? rect.minX - width + 1 : rect.maxX - 1
                park(column, at: Rect(topLeftX: parkedX, topLeftY: rect.minY, width: width, height: rect.height - 1), virtual: virtual)
            }
        }
        try await floatingWindowsContainer.layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
