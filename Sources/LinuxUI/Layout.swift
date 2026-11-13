import DynamicUI

/// One layout pass over the store's tree (`Plan.md` §5.2): SwiftUI's
/// protocol, where a parent proposes a size, the child answers with its
/// own, and the parent places it.
///
/// `size` measures, memoized for the pass; `place` builds the `LayoutBox`
/// tree that drawing and hit testing walk. Modifiers wrap their node in
/// order, so a node is measured and placed level by level, its content at
/// level 0.
final class Layout {

    let store: RenderStore

    let engine: TextEngine

    /// Sheets and alerts that are presented, found while placing.
    var presentations: [(node: RenderNode, environment: ViewEnvironment)] = []

    /// Searchable nodes whose field is in a navigation bar.
    var hoistedSearches: Set<RenderNode.ID> = []

    /// The part of the window that shows, for lazy containers: the
    /// innermost scroll view's viewport, in window points.
    var visible: Rect

    private var cache: [Key: Size] = [:]

    private struct Key: Hashable {
        let id: RenderNode.ID
        let width: Double?
        let height: Double?
    }

    init(store: RenderStore, window: Rect) {
        self.store = store
        self.engine = store.textEngine
        self.visible = window
    }

    // MARK: Measuring

    /// The size `node` takes when offered `proposal`. `environment` is its
    /// parent's.
    func size(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let key = Key(id: node.id, width: proposal.width, height: proposal.height)
        if let size = cache[key] {
            return size
        }
        let environment = environment.applying(node.modifiers)
        let size = self.size(node, level: node.modifiers.count, proposal, environment)
        cache[key] = size
        return size
    }

    private func size(_ node: RenderNode, level: Int, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        guard level > 0 else {
            return contentSize(node, proposal, environment)
        }
        let modifier = node.modifiers[level - 1]
        switch modifier.kind {
        case "padding":
            let insets = Self.insets(modifier)
            let inner = size(node, level: level - 1, proposal.inset(by: insets), environment)
            return Size(width: inner.width + insets.horizontal, height: inner.height + insets.vertical)
        case "frame":
            return Self.frameSize(modifier, proposal) { size(node, level: level - 1, $0, environment) }
        default:
            return size(node, level: level - 1, proposal, environment)
        }
    }

    // MARK: Placing

    /// Places `node` in `rect`, which its parent sized for it.
    func place(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment) -> LayoutBox {
        let environment = environment.applying(node.modifiers)
        let box = LayoutBox(id: node.id, type: node.type, frame: rect)
        box.disabled = environment.disabled
        place(node, level: node.modifiers.count, in: rect, environment, box)
        return box
    }

    private func place(_ node: RenderNode, level: Int, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        guard level > 0 else {
            box.contentFrame = rect
            placeContent(node, in: rect, environment, box)
            return
        }
        let modifier = node.modifiers[level - 1]
        let args = modifier.args
        var inner = rect
        switch modifier.kind {
        case "padding":
            inner = rect.inset(by: Self.insets(modifier))
        case "frame":
            let child = size(node, level: level - 1, ProposedSize(rect.size), environment)
            inner = rect.place(
                Size(width: min(child.width, rect.width), height: min(child.height, rect.height)),
                Alignment(
                    horizontal: HorizontalAlignment(args["horizontal"]?.string),
                    vertical: VerticalAlignment(args["vertical"]?.string)
                )
            )
        case "offset":
            inner = rect.offsetBy(dx: args["x"]?.double ?? 0, dy: args["y"]?.double ?? 0)
            if level == node.modifiers.count {
                box.frame = inner
            }
        case "background":
            if let color = environment.palette.color(args["color"]) {
                box.decorations.append(.background(color, rect))
            }
        case "border":
            if let color = environment.palette.color(args["color"]) {
                box.decorations.append(.border(color, width: args["width"]?.double ?? 1, rect))
            }
        case "shadow":
            let color = environment.palette.color(args["color"]) ?? Color.black.opacity(0.33)
            let shadow = rect.offsetBy(dx: args["x"]?.double ?? 0, dy: args["y"]?.double ?? 0)
            box.decorations.append(.shadow(color, radius: args["radius"]?.double ?? 0, shadow))
        case "opacity":
            box.decorations.append(.opacity(args["value"]?.double ?? 1))
        case "cornerRadius":
            box.decorations.append(.cornerRadius(args["radius"]?.double ?? 0, rect))
        case "onTapGesture":
            if box.role == nil {
                box.role = .tap(node.id)
                box.hitRect = rect
            }
        default:
            break
        }
        place(node, level: level - 1, in: inner, environment, box)
    }

    // MARK: Content

    private func contentSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        switch node.type {
        case "Text":
            return textSize(node.props["text"]?.string ?? "", proposal, environment)
        case "Image":
            return imageSize(node, proposal, environment)
        case "Label":
            return labelSize(node, proposal, environment)
        case "Spacer":
            let minimum = node.props["minLength"]?.double ?? Metrics.spacerMinLength
            var size = Size.zero
            size[environment.stackAxis] = max(proposal[environment.stackAxis] ?? minimum, minimum)
            return size
        case "Divider":
            var size = Size.zero
            let along = environment.stackAxis.cross
            size[along] = proposal[along] ?? 0
            size[environment.stackAxis] = 1
            return size
        case "Color":
            return proposal.replacingUnspecified(with: Size(width: 10, height: 10))
        case "VStack", "HStack", "LazyVStack", "LazyHStack", "ZStack":
            if node.count != nil {
                return lazyStackSize(node, proposal, environment)
            }
            return stackSize(node, proposal, environment)
        case "ScrollView":
            return scrollViewSize(node, proposal, environment)
        case "Grid":
            return gridSize(node, proposal, environment)
        case "LazyVGrid", "LazyHGrid":
            return lazyGridSize(node, proposal, environment)
        case "Sheet", "Alert", "Searchable":
            // They stand in for their first child (`RenderIR.md`).
            guard let first = node.children.first else { return .zero }
            return size(first, proposal, environment)
        default:
            if let size = controlSize(node, proposal, environment) {
                return size
            }
            if let size = listSize(node, proposal, environment) {
                return size
            }
            if let size = navigationSize(node, proposal, environment) {
                return size
            }
            // A type this player doesn't know: an empty placeholder.
            return .zero
        }
    }

    private func placeContent(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        switch node.type {
        case "Text":
            let text = node.props["text"]?.string ?? ""
            box.ops.append(.text(text, environment.font, environment.foregroundColor, rect, environment.textAlignment, wrap: true))
        case "Image":
            placeImage(node, in: rect, environment, box)
        case "Label":
            placeLabel(node, in: rect, environment, box)
        case "Divider":
            box.ops.append(.fill(rect, environment.palette.separator, radius: 0))
        case "Color":
            if let color = environment.palette.color(node.props["color"]) {
                box.ops.append(.fill(rect, color, radius: 0))
            }
        case "VStack", "HStack", "LazyVStack", "LazyHStack", "ZStack":
            if node.count != nil {
                placeLazyStack(node, in: rect, environment, box)
            } else {
                placeStack(node, in: rect, environment, box)
            }
        case "ScrollView":
            placeScrollView(node, in: rect, environment, box)
        case "Grid":
            placeGrid(node, in: rect, environment, box)
        case "LazyVGrid", "LazyHGrid":
            placeLazyGrid(node, in: rect, environment, box)
        case "Sheet", "Alert":
            if let first = node.children.first {
                box.children.append(place(first, in: rect, environment))
            }
            if node.props["isPresented"]?.bool == true {
                presentations.append((node, environment))
            }
        case "Searchable":
            placeSearchable(node, in: rect, environment, box)
        default:
            if placeControl(node, in: rect, environment, box) { return }
            if placeList(node, in: rect, environment, box) { return }
            if placeNavigation(node, in: rect, environment, box) { return }
        }
    }

    // MARK: Text and images

    func textSize(_ text: String, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let size = engine.measure(text, font: environment.font, maxWidth: width, lineLimit: environment.lineLimit)
        return Size(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    private func imageSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        if node.props["resizable"]?.bool == true {
            return proposal.replacingUnspecified(with: Size(width: 24, height: 24))
        }
        let glyph = Symbols.glyph(node.props["systemName"]?.string)
        let line = engine.lineHeight(environment.font)
        return Size(width: max(engine.width(glyph, font: environment.font).rounded(.up), line * 0.8), height: line)
    }

    private func placeImage(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        if node.props["systemName"] != nil || node.props["resizable"]?.bool != true {
            let glyph = Symbols.glyph(node.props["systemName"]?.string)
            box.ops.append(.text(glyph, environment.font, environment.foregroundColor, rect, .center, wrap: false))
        } else {
            // Bundle images come later (SDL3_image): a placeholder.
            box.ops.append(.fill(rect, environment.palette.control, radius: 4))
        }
    }

    private func labelParts(_ node: RenderNode, _ environment: ViewEnvironment) -> (icon: String?, title: String) {
        (node.props["systemImage"]?.string.map { Symbols.glyph($0) }, node.props["title"]?.string ?? "")
    }

    private func labelSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let (icon, title) = labelParts(node, environment)
        let iconWidth = icon.map { engine.width($0, font: environment.font).rounded(.up) + 6 } ?? 0
        let text = textSize(title, ProposedSize(width: proposal.width.map { max($0 - iconWidth, 0) }, height: proposal.height), environment)
        return Size(width: text.width + iconWidth, height: max(text.height, engine.lineHeight(environment.font)))
    }

    private func placeLabel(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let (icon, title) = labelParts(node, environment)
        var x = rect.minX
        if let icon {
            let width = engine.width(icon, font: environment.font).rounded(.up)
            let line = engine.lineHeight(environment.font)
            box.ops.append(.text(icon, environment.font, environment.foreground ?? environment.tintColor,
                                 Rect(x: x, y: rect.minY, width: width, height: line), .center, wrap: false))
            x += width + 6
        }
        box.ops.append(.text(title, environment.font, environment.foregroundColor,
                             Rect(x: x, y: rect.minY, width: max(rect.maxX - x, 0), height: rect.height), .leading, wrap: true))
    }

    // MARK: Stacks

    func stackAxis(_ node: RenderNode) -> Axis? {
        switch node.type {
        case "VStack", "LazyVStack": .vertical
        case "HStack", "LazyHStack": .horizontal
        default: nil
        }
    }

    func spacing(_ node: RenderNode) -> Double {
        node.props["spacing"]?.double ?? Metrics.stackSpacing
    }

    private func stackSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        guard let axis = stackAxis(node) else {
            // ZStack: as large as its largest child.
            var result = Size.zero
            for child in node.children {
                let size = size(child, proposal, environment)
                result = Size(width: max(result.width, size.width), height: max(result.height, size.height))
            }
            return result
        }
        return arrange(node.children, axis: axis, spacing: spacing(node), proposal, environment).size
    }

    /// Divides `proposal` among `children` along `axis` as SwiftUI's stacks
    /// do: least flexible first, each offered an equal share of what's left.
    func arrange(
        _ children: [RenderNode],
        axis: Axis,
        spacing: Double,
        _ proposal: ProposedSize,
        _ environment: ViewEnvironment
    ) -> (size: Size, sizes: [Size]) {
        var environment = environment
        environment.stackAxis = axis
        let count = children.count
        guard count > 0 else { return (.zero, []) }
        let totalSpacing = spacing * Double(count - 1)
        var sizes = [Size](repeating: .zero, count: count)
        func offer(_ length: Double?) -> ProposedSize {
            var offer = proposal
            offer[axis] = length
            return offer
        }
        if let available = proposal[axis], available.isFinite {
            var flexibility = [Double](repeating: 0, count: count)
            for (index, child) in children.enumerated() {
                let least = size(child, offer(0), environment)[axis]
                let most = size(child, offer(.infinity), environment)[axis]
                flexibility[index] = most - least
            }
            let order = children.indices.sorted { (flexibility[$0], $0) < (flexibility[$1], $1) }
            var remaining = max(available - totalSpacing, 0)
            var left = Double(count)
            for index in order {
                let share = max(remaining / left, 0)
                let size = self.size(children[index], offer(share), environment)
                sizes[index] = Size(width: size.width.finite, height: size.height.finite)
                remaining -= sizes[index][axis]
                left -= 1
            }
        } else {
            for (index, child) in children.enumerated() {
                sizes[index] = size(child, offer(proposal[axis]), environment)
            }
        }
        var result = Size.zero
        result[axis] = sizes.reduce(totalSpacing) { $0 + $1[axis] }
        result[axis.cross] = sizes.map { $0[axis.cross] }.max() ?? 0
        return (result, sizes)
    }

    private func placeStack(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        guard let axis = stackAxis(node) else {
            let alignment = Alignment(
                horizontal: HorizontalAlignment(node.props["horizontal"]?.string),
                vertical: VerticalAlignment(node.props["vertical"]?.string)
            )
            for child in node.children {
                let size = size(child, ProposedSize(rect.size), environment)
                box.children.append(place(child, in: rect.place(clamp(size, to: rect.size), alignment), environment))
            }
            return
        }
        placeSequence(node.children, axis: axis, spacing: spacing(node), alignment: node.props["alignment"]?.string,
                      in: rect, environment, box)
    }

    /// Places `children` one after another along `axis`, aligned on the
    /// cross axis.
    func placeSequence(
        _ children: [RenderNode],
        axis: Axis,
        spacing: Double,
        alignment: String?,
        in rect: Rect,
        _ environment: ViewEnvironment,
        _ box: LayoutBox
    ) {
        let (_, sizes) = arrange(children, axis: axis, spacing: spacing, ProposedSize(rect.size), environment)
        var stackEnvironment = environment
        stackEnvironment.stackAxis = axis
        var position = axis == .vertical ? rect.minY : rect.minX
        for (child, size) in zip(children, sizes) {
            let cross = min(size[axis.cross], rect.size[axis.cross])
            let childRect: Rect
            if axis == .vertical {
                let x: Double
                switch HorizontalAlignment(alignment) {
                case .leading: x = rect.minX
                case .center: x = rect.minX + (rect.width - cross) / 2
                case .trailing: x = rect.maxX - cross
                }
                childRect = Rect(x: x, y: position, width: cross, height: size.height)
                position += size.height + spacing
            } else {
                let y: Double
                switch VerticalAlignment(alignment) {
                case .top: y = rect.minY
                case .center: y = rect.minY + (rect.height - cross) / 2
                case .bottom: y = rect.maxY - cross
                }
                childRect = Rect(x: position, y: y, width: size.width, height: cross)
                position += size.width + spacing
            }
            box.children.append(place(child, in: childRect, stackEnvironment))
        }
    }

    func clamp(_ size: Size, to bounds: Size) -> Size {
        Size(width: min(size.width.finite, bounds.width), height: min(size.height.finite, bounds.height))
    }

    // MARK: Scroll views

    private func scrollAxes(_ node: RenderNode) -> (horizontal: Bool, vertical: Bool) {
        switch node.props["axes"]?.string {
        case "horizontal": (true, false)
        case "both": (true, true)
        default: (false, true)
        }
    }

    private func scrollContentProposal(_ node: RenderNode, _ proposal: ProposedSize) -> ProposedSize {
        let axes = scrollAxes(node)
        return ProposedSize(width: axes.horizontal ? nil : proposal.width, height: axes.vertical ? nil : proposal.height)
    }

    private func scrollViewSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let content = node.children.isEmpty ? .zero : contentStack(node, scrollContentProposal(node, proposal), environment)
        return Size(width: proposal.width ?? content.width, height: proposal.height ?? content.height)
    }

    /// A scroll view's children as a stack along its axis.
    private func contentStack(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let axis: Axis = scrollAxes(node).vertical ? .vertical : .horizontal
        return arrange(node.children, axis: axis, spacing: Metrics.stackSpacing, proposal, environment).size
    }

    private func placeScrollView(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let axes = scrollAxes(node)
        let axis: Axis = axes.vertical ? .vertical : .horizontal
        let proposal = scrollContentProposal(node, ProposedSize(rect.size))
        let content = contentStack(node, proposal, environment)
        let contentSize = Size(width: max(content.width, axes.horizontal ? 0 : rect.width),
                               height: max(content.height, axes.vertical ? 0 : rect.height))
        let offset = store.scrollOffset(node.id, content: contentSize, viewport: rect.size)
        let contentRect = Rect(x: rect.minX - offset.x, y: rect.minY - offset.y,
                               width: contentSize.width, height: contentSize.height)
        let outer = visible
        visible = visible.intersection(rect)
        placeSequence(node.children, axis: axis, spacing: Metrics.stackSpacing, alignment: nil,
                      in: contentRect, environment, box)
        visible = outer
        box.clip = rect
        box.role = .scroll(node.id, content: contentSize, viewport: rect)
        if node.props["showsIndicators"]?.bool != false {
            addScrollIndicator(content: contentSize, viewport: rect, offset: offset, environment, box)
        }
    }

    func addScrollIndicator(content: Size, viewport: Rect, offset: Point, _ environment: ViewEnvironment, _ box: LayoutBox) {
        guard content.height > viewport.height + 0.5, store.isScrolling(box.id) else { return }
        let ratio = viewport.height / content.height
        let length = max(viewport.height * ratio, 24)
        let progress = offset.y / max(content.height - viewport.height, 1)
        let y = viewport.minY + (viewport.height - length) * progress
        box.overlayOps.append(.fill(Rect(x: viewport.maxX - Metrics.indicatorWidth - 2, y: y,
                                         width: Metrics.indicatorWidth, height: length),
                                    environment.palette.primary.opacity(0.35), radius: Metrics.indicatorWidth / 2))
    }

    // MARK: Modifiers

    static func insets(_ modifier: ModifierNode) -> EdgeInsets {
        EdgeInsets(
            top: modifier.args["top"]?.double ?? 0,
            leading: modifier.args["leading"]?.double ?? 0,
            bottom: modifier.args["bottom"]?.double ?? 0,
            trailing: modifier.args["trailing"]?.double ?? 0
        )
    }

    /// SwiftUI's frames: a fixed length proposes and takes that length; a
    /// flexible one clamps the proposal (or its ideal) to its bounds, using
    /// the child's size for a bound it doesn't set.
    static func frameSize(_ modifier: ModifierNode, _ proposal: ProposedSize, child: (ProposedSize) -> Size) -> Size {
        let args = modifier.args
        func resolve(_ axis: Axis) -> (proposal: Double?, fixed: Double?, min: Double?, ideal: Double?, max: Double?) {
            let names = axis == .horizontal
                ? ("width", "minWidth", "idealWidth", "maxWidth")
                : ("height", "minHeight", "idealHeight", "maxHeight")
            let fixed = args[names.0]?.double
            let minimum = args[names.1]?.double, ideal = args[names.2]?.double, maximum = args[names.3]?.double
            var offered = proposal[axis]
            if let fixed {
                offered = fixed
            } else if minimum != nil || ideal != nil || maximum != nil {
                offered = (offered ?? ideal).map { clamp($0, minimum, maximum) }
            }
            return (offered, fixed, minimum, ideal, maximum)
        }
        let horizontal = resolve(.horizontal), vertical = resolve(.vertical)
        let inner = child(ProposedSize(width: horizontal.proposal, height: vertical.proposal))
        func length(_ axis: Axis, _ resolved: (proposal: Double?, fixed: Double?, min: Double?, ideal: Double?, max: Double?)) -> Double {
            if let fixed = resolved.fixed {
                return fixed
            }
            guard resolved.min != nil || resolved.max != nil || resolved.ideal != nil else {
                return inner[axis]
            }
            let offered = proposal[axis] ?? resolved.ideal ?? inner[axis]
            return clamp(offered, resolved.min ?? inner[axis], resolved.max ?? inner[axis])
        }
        return Size(width: length(.horizontal, horizontal), height: length(.vertical, vertical))
    }

    /// `value` within the bounds; the lower bound wins if they cross.
    static func clamp(_ value: Double, _ lower: Double?, _ upper: Double?) -> Double {
        var value = value
        if let upper { value = min(value, upper) }
        if let lower { value = max(value, lower) }
        return value
    }
}
