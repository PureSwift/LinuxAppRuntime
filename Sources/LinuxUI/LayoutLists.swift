import DynamicUI

/// Lists, forms and sections (inset and grouped, as GNOME's boxed lists),
/// lazy stacks, and grids.
extension Layout {

    // MARK: Measuring

    func listSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size? {
        switch node.type {
        case "List", "Form":
            // Greedy, like SwiftUI's.
            return proposal.replacingUnspecified(with: Size(width: 320, height: 320))
        case "Section":
            return sectionSize(node, proposal, environment)
        case "SwipeActions":
            guard let row = node.children.first else { return .zero }
            return size(row, proposal, environment)
        case "GridRow":
            return arrange(node.children, axis: .horizontal, spacing: Metrics.stackSpacing, proposal, environment).size
        default:
            return nil
        }
    }

    private func sectionSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        var result = arrange(node.children, axis: .vertical, spacing: Metrics.stackSpacing, proposal, environment).size
        for key in ["header", "footer"] {
            if let text = node.props[key]?.string {
                let size = textSize(text, proposal, caption(environment))
                result.width = max(result.width, size.width)
                result.height += size.height + 6
            }
        }
        return result
    }

    private func caption(_ environment: ViewEnvironment) -> ViewEnvironment {
        var environment = environment
        environment.font = FontSpec(size: FontSpec.TextStyles.size("footnote"))
        environment.foreground = environment.palette.secondary
        return environment
    }

    // MARK: Placing

    func placeList(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) -> Bool {
        switch node.type {
        case "List", "Form":
            if node.count != nil {
                placeLazyList(node, in: rect, environment, box)
            } else {
                placeGroupedList(node, in: rect, environment, box)
            }
            return true
        case "Section":
            var top = rect.minY
            let captionEnvironment = caption(environment)
            if let header = node.props["header"]?.string {
                let size = textSize(header, ProposedSize(width: rect.width, height: nil), captionEnvironment)
                box.ops.append(.text(header, captionEnvironment.font, captionEnvironment.foregroundColor,
                                     Rect(x: rect.minX, y: top, width: rect.width, height: size.height), .leading, wrap: true))
                top += size.height + 6
            }
            let content = arrange(node.children, axis: .vertical, spacing: Metrics.stackSpacing,
                                  ProposedSize(width: rect.width, height: nil), environment).size
            placeSequence(node.children, axis: .vertical, spacing: Metrics.stackSpacing, alignment: "leading",
                          in: Rect(x: rect.minX, y: top, width: rect.width, height: content.height), environment, box)
            top += content.height + 6
            if let footer = node.props["footer"]?.string {
                box.ops.append(.text(footer, captionEnvironment.font, captionEnvironment.foregroundColor,
                                     Rect(x: rect.minX, y: top, width: rect.width, height: max(rect.maxY - top, 0)), .leading, wrap: true))
            }
            return true
        case "SwipeActions":
            if let row = node.children.first {
                box.children.append(place(row, in: rect, environment))
            }
            box.contextMenu = menuItems(Array(node.children.dropFirst()))
            return true
        case "GridRow":
            placeSequence(node.children, axis: .horizontal, spacing: Metrics.stackSpacing,
                          alignment: node.props["alignment"]?.string, in: rect, environment, box)
            return true
        default:
            return false
        }
    }

    /// A list's rows, grouped: each `Section` is a card with its header and
    /// footer; rows outside sections share a card.
    private struct Group {
        var header: String?
        var footer: String?
        var rows: [RenderNode]
    }

    private func groups(_ node: RenderNode) -> [Group] {
        var groups: [Group] = []
        var loose: [RenderNode] = []
        func flush() {
            if !loose.isEmpty {
                groups.append(Group(rows: loose))
                loose = []
            }
        }
        for child in node.children {
            if child.type == "Section" {
                flush()
                groups.append(Group(header: child.props["header"]?.string, footer: child.props["footer"]?.string,
                                    rows: child.children))
            } else {
                loose.append(child)
            }
        }
        flush()
        return groups
    }

    func rowEnvironment(_ environment: ViewEnvironment) -> ViewEnvironment {
        var row = environment
        row.inListRow = true
        row.stackAxis = .horizontal
        return row
    }

    /// A row's height for `width`.
    func rowHeight(_ row: RenderNode, width: Double, _ environment: ViewEnvironment) -> Double {
        let insets = rowInsets(row)
        let content = size(row, ProposedSize(width: max(width - insets.horizontal, 0), height: nil), rowEnvironment(environment))
        return max(content.height + insets.vertical, Metrics.rowMinHeight)
    }

    /// Controls that draw their own full-height rows take no vertical
    /// insets.
    private func rowInsets(_ row: RenderNode) -> EdgeInsets {
        switch row.type {
        case "Picker" where row.props["style"]?.string == "inline":
            EdgeInsets(top: 0, leading: Metrics.rowInsets.leading, bottom: 0, trailing: Metrics.rowInsets.trailing)
        case "DisclosureGroup":
            EdgeInsets(top: 6, leading: Metrics.rowInsets.leading, bottom: 6, trailing: Metrics.rowInsets.trailing)
        default:
            Metrics.rowInsets
        }
    }

    /// Places one row in `frame`: a wrapper box takes the row's tap, so the
    /// whole row is the target and highlights.
    func placeRow(_ row: RenderNode, in frame: Rect, _ environment: ViewEnvironment, _ box: LayoutBox, separator: Bool) {
        let palette = environment.palette
        let wrapper = LayoutBox(id: row.id, type: "Row", frame: frame)
        if separator {
            wrapper.ops.append(.fill(Rect(x: frame.minX + Metrics.rowInsets.leading, y: frame.minY,
                                          width: frame.width - Metrics.rowInsets.leading, height: 1), palette.separator, radius: 0))
        }
        let insets = rowInsets(row)
        let inner = frame.inset(by: insets)
        let rowEnvironment = rowEnvironment(environment)
        let content = size(row, ProposedSize(inner.size), rowEnvironment)
        let child = place(row, in: Rect(x: inner.minX, y: inner.midY - content.height / 2, width: inner.width,
                                        height: min(content.height, max(inner.height, content.height))), rowEnvironment)
        // A row that is a button, link or picker reacts anywhere in it.
        switch child.role {
        case .tap(let id)?, .select(let id, _)?:
            wrapper.role = child.role
            child.role = nil
            if store.isPressed(id) {
                wrapper.ops.append(.fill(frame, palette.highlight, radius: 0))
            }
        case .menu?, .toggle?, .link?:
            wrapper.role = child.role
            child.role = nil
        default:
            break
        }
        // Swipe actions stay with the row.
        if let menu = child.contextMenu {
            wrapper.contextMenu = menu
            child.contextMenu = nil
        }
        wrapper.children.append(child)
        box.children.append(wrapper)
    }

    private func placeGroupedList(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        box.ops.append(.fill(rect, palette.groupedBackground, radius: 0))
        let inset = Metrics.listInset
        let cardWidth = max(rect.width - inset * 2, 0)
        let captionEnvironment = caption(environment)
        // Heights first, for the scroll extent.
        let groups = groups(node)
        var layoutGroups: [(header: Double, rows: [Double], footer: Double)] = []
        var contentHeight = inset
        for group in groups {
            let header = group.header.map { textSize($0, ProposedSize(width: cardWidth, height: nil), captionEnvironment).height + 6 } ?? 0
            let rows = group.rows.map { rowHeight($0, width: cardWidth, environment) }
            let footer = group.footer.map { textSize($0, ProposedSize(width: cardWidth, height: nil), captionEnvironment).height + 6 } ?? 0
            layoutGroups.append((header, rows, footer))
            contentHeight += header + rows.reduce(0, +) + footer + Metrics.sectionSpacing
        }
        let content = Size(width: rect.width, height: contentHeight)
        let offset = store.scrollOffset(node.id, content: content, viewport: rect.size)
        var y = rect.minY + inset - offset.y
        let outer = visible
        visible = visible.intersection(rect)
        for (group, heights) in zip(groups, layoutGroups) {
            let x = rect.minX + inset
            if let header = group.header {
                box.ops.append(.text(header, captionEnvironment.font, captionEnvironment.foregroundColor,
                                     Rect(x: x + 4, y: y, width: cardWidth - 4, height: heights.header - 6), .leading, wrap: true))
                y += heights.header
            }
            let cardHeight = heights.rows.reduce(0, +)
            let card = Rect(x: x, y: y, width: cardWidth, height: cardHeight)
            let cardBox = LayoutBox(id: node.id, type: "List.card", frame: card)
            cardBox.ops.append(.fill(card, palette.card, radius: Metrics.cardRadius))
            cardBox.clip = card
            for (index, (row, height)) in zip(group.rows, heights.rows).enumerated() {
                let frame = Rect(x: x, y: y, width: cardWidth, height: height)
                if frame.intersects(visible) || index == 0 {
                    placeRow(row, in: frame, environment, cardBox, separator: index > 0)
                }
                y += height
            }
            box.children.append(cardBox)
            if let footer = group.footer {
                box.ops.append(.text(footer, captionEnvironment.font, captionEnvironment.foregroundColor,
                                     Rect(x: x + 4, y: y + 6, width: cardWidth - 4, height: heights.footer - 6), .leading, wrap: true))
                y += heights.footer
            }
            y += Metrics.sectionSpacing
        }
        visible = outer
        box.clip = rect
        box.role = .scroll(node.id, content: content, viewport: rect)
        addScrollIndicator(content: content, viewport: rect, offset: offset, environment, box)
    }

    /// A lazy list: one card, rows as tall as the first, fetched only while
    /// they show.
    private func placeLazyList(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        box.ops.append(.fill(rect, palette.groupedBackground, radius: 0))
        let count = store.rowCount(node)
        let inset = Metrics.listInset
        let cardWidth = max(rect.width - inset * 2, 0)
        let height = store.row(node, index: 0).map { rowHeight($0, width: cardWidth, environment) } ?? Metrics.rowMinHeight
        let content = Size(width: rect.width, height: height * Double(count) + inset * 2)
        let offset = store.scrollOffset(node.id, content: content, viewport: rect.size)
        let card = Rect(x: rect.minX + inset, y: rect.minY + inset - offset.y, width: cardWidth, height: height * Double(count))
        let cardBox = LayoutBox(id: node.id, type: "List.card", frame: card)
        if count > 0 {
            cardBox.ops.append(.fill(card, palette.card, radius: Metrics.cardRadius))
        }
        cardBox.clip = card
        let shown = card.intersection(rect)
        if !shown.isEmpty, height > 0 {
            let first = max(Int((shown.minY - card.minY) / height), 0)
            let last = min(Int((shown.maxY - card.minY) / height), count - 1)
            if first <= last {
                for index in first...last {
                    guard let row = store.row(node, index: index) else { continue }
                    let frame = Rect(x: card.minX, y: card.minY + Double(index) * height, width: cardWidth, height: height)
                    placeRow(row, in: frame, environment, cardBox, separator: index > 0)
                }
            }
        }
        box.children.append(cardBox)
        box.clip = rect
        box.role = .scroll(node.id, content: content, viewport: rect)
        addScrollIndicator(content: content, viewport: rect, offset: offset, environment, box)
    }

    // MARK: Lazy stacks

    func lazyStackSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let axis = stackAxis(node) ?? .vertical
        let count = store.rowCount(node)
        guard count > 0, let first = store.row(node, index: 0) else { return .zero }
        var offer = proposal
        offer[axis] = nil
        let item = size(first, offer, environment)
        var result = Size.zero
        result[axis] = item[axis] * Double(count) + spacing(node) * Double(count - 1)
        result[axis.cross] = proposal[axis.cross].flatMap { $0.isFinite ? $0 : nil } ?? item[axis.cross]
        return result
    }

    func placeLazyStack(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let axis = stackAxis(node) ?? .vertical
        let count = store.rowCount(node)
        guard count > 0, let first = store.row(node, index: 0) else { return }
        var offer = ProposedSize(rect.size)
        offer[axis] = nil
        let extent = size(first, offer, environment)[axis]
        let stride = extent + spacing(node)
        guard stride > 0 else { return }
        let start = axis == .vertical ? rect.minY : rect.minX
        let shown = rect.intersection(visible)
        guard !shown.isEmpty else { return }
        let low = axis == .vertical ? shown.minY : shown.minX
        let high = axis == .vertical ? shown.maxY : shown.maxX
        let firstIndex = max(Int((low - start) / stride), 0)
        let lastIndex = min(Int((high - start) / stride), count - 1)
        guard firstIndex <= lastIndex else { return }
        var itemEnvironment = environment
        itemEnvironment.stackAxis = axis
        for index in firstIndex...lastIndex {
            guard let item = store.row(node, index: index) else { continue }
            let position = start + Double(index) * stride
            let cross = min(size(item, offer, itemEnvironment)[axis.cross], rect.size[axis.cross])
            let frame: Rect
            if axis == .vertical {
                let x: Double
                switch HorizontalAlignment(node.props["alignment"]?.string) {
                case .leading: x = rect.minX
                case .center: x = rect.minX + (rect.width - cross) / 2
                case .trailing: x = rect.maxX - cross
                }
                frame = Rect(x: x, y: position, width: cross, height: extent)
            } else {
                frame = Rect(x: position, y: rect.minY + (rect.height - cross) / 2, width: extent, height: cross)
            }
            box.children.append(place(item, in: frame, itemEnvironment))
        }
    }

    // MARK: Grids

    /// `Grid`: columns as wide as their widest cell, rows as tall as their
    /// tallest; views that aren't `GridRow`s span the grid.
    private func gridTracks(_ node: RenderNode, _ environment: ViewEnvironment) -> (columns: [Double], rows: [Double]) {
        var columns: [Double] = []
        var rows: [Double] = []
        for row in node.children {
            if row.type == "GridRow" {
                var height = 0.0
                for (index, cell) in row.children.enumerated() {
                    let size = size(cell, .unspecified, environment)
                    if index >= columns.count { columns.append(0) }
                    columns[index] = max(columns[index], size.width.finite)
                    height = max(height, size.height.finite)
                }
                rows.append(height)
            } else {
                rows.append(size(row, .unspecified, environment).height.finite)
            }
        }
        return (columns, rows)
    }

    func gridSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let (columns, rows) = gridTracks(node, environment)
        let horizontal = node.props["horizontalSpacing"]?.double ?? Metrics.stackSpacing
        let vertical = node.props["verticalSpacing"]?.double ?? Metrics.stackSpacing
        let width = columns.reduce(0, +) + horizontal * Double(max(columns.count - 1, 0))
        let height = rows.reduce(0, +) + vertical * Double(max(rows.count - 1, 0))
        return Size(width: width, height: height)
    }

    func placeGrid(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let (columns, rows) = gridTracks(node, environment)
        let horizontal = node.props["horizontalSpacing"]?.double ?? Metrics.stackSpacing
        let vertical = node.props["verticalSpacing"]?.double ?? Metrics.stackSpacing
        let alignment = Alignment(
            horizontal: HorizontalAlignment(node.props["horizontal"]?.string),
            vertical: VerticalAlignment(node.props["vertical"]?.string)
        )
        let width = columns.reduce(0, +) + horizontal * Double(max(columns.count - 1, 0))
        var y = rect.minY
        for (row, height) in zip(node.children, rows) {
            if row.type == "GridRow" {
                let rowBox = LayoutBox(id: row.id, type: "GridRow", frame: Rect(x: rect.minX, y: y, width: width, height: height))
                var x = rect.minX
                var cellAlignment = alignment
                if let vertical = row.props["alignment"]?.string {
                    cellAlignment.vertical = VerticalAlignment(vertical)
                }
                for (cell, columnWidth) in zip(row.children, columns) {
                    let cellRect = Rect(x: x, y: y, width: columnWidth, height: height)
                    let size = clamp(size(cell, ProposedSize(cellRect.size), environment), to: cellRect.size)
                    rowBox.children.append(place(cell, in: cellRect.place(size, cellAlignment), environment))
                    x += columnWidth + horizontal
                }
                box.children.append(rowBox)
            } else {
                let spanned = Rect(x: rect.minX, y: y, width: width, height: height)
                let size = clamp(self.size(row, ProposedSize(spanned.size), environment), to: spanned.size)
                box.children.append(place(row, in: spanned.place(size, alignment), environment))
            }
            y += height + vertical
        }
    }

    /// A lazy grid's item: `[size, a, b, spacing, horizontal, vertical]`.
    private struct GridItem {
        var kind: String
        var a: Double
        var b: Double
        var spacing: Double
        var alignment: Alignment

        init(_ value: PropValue) {
            let parts: [PropValue]
            if case .array(let array) = value { parts = array } else { parts = [] }
            func part(_ index: Int) -> PropValue? { parts.indices.contains(index) ? parts[index] : nil }
            kind = part(0)?.string ?? "flexible"
            a = part(1)?.double ?? 0
            b = part(2)?.double ?? .infinity
            spacing = part(3)?.double ?? Metrics.stackSpacing
            alignment = Alignment(horizontal: HorizontalAlignment(part(4)?.string), vertical: VerticalAlignment(part(5)?.string))
        }
    }

    /// Resolves grid items to track lengths along `length`: fixed items
    /// first, the rest share what's left; an adaptive item fits as many
    /// tracks of its minimum as it can.
    private func tracks(_ items: [GridItem], length: Double) -> [(length: Double, spacing: Double, alignment: Alignment)] {
        guard !items.isEmpty else { return [] }
        let fixed = items.filter { $0.kind == "fixed" }.reduce(0) { $0 + $1.a }
        let spacing = items.dropLast().reduce(0) { $0 + $1.spacing }
        let flexibleCount = items.filter { $0.kind != "fixed" }.count
        let share = flexibleCount > 0 ? max(length - fixed - spacing, 0) / Double(flexibleCount) : 0
        var result: [(Double, Double, Alignment)] = []
        for item in items {
            switch item.kind {
            case "fixed":
                result.append((item.a, item.spacing, item.alignment))
            case "adaptive":
                let minimum = max(item.a, 1)
                let count = max(Int((share + item.spacing) / (minimum + item.spacing)), 1)
                let each = min((share - item.spacing * Double(count - 1)) / Double(count), item.b.isFinite ? item.b : .infinity)
                for _ in 0..<count {
                    result.append((max(each, 0), item.spacing, item.alignment))
                }
            default:
                result.append((Self.clamp(share, item.a, item.b.isFinite ? item.b : nil), item.spacing, item.alignment))
            }
        }
        return result
    }

    private func gridAxis(_ node: RenderNode) -> Axis {
        node.type == "LazyHGrid" ? .horizontal : .vertical
    }

    private func gridItems(_ node: RenderNode) -> [GridItem] {
        let key = node.type == "LazyHGrid" ? "rows" : "columns"
        guard case .array(let items)? = node.props[key] else { return [] }
        return items.map(GridItem.init)
    }

    private func gridChildren(_ node: RenderNode) -> [RenderNode] {
        guard node.count != nil else { return node.children }
        return (0..<store.rowCount(node)).compactMap { store.row(node, index: $0) }
    }

    func lazyGridSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let axis = gridAxis(node)
        let cross = axis.cross
        let available = proposal[cross].flatMap { $0.isFinite ? $0 : nil } ?? 320
        let tracks = tracks(gridItems(node), length: available)
        guard !tracks.isEmpty else { return .zero }
        let children = gridChildren(node)
        let lines = (children.count + tracks.count - 1) / tracks.count
        var extent = 0.0
        for line in 0..<lines {
            var lineExtent = 0.0
            for (column, track) in tracks.enumerated() {
                let index = line * tracks.count + column
                guard index < children.count else { break }
                var offer = ProposedSize(width: nil, height: nil)
                offer[cross] = track.length
                lineExtent = max(lineExtent, size(children[index], offer, environment)[axis].finite)
            }
            extent += lineExtent
        }
        extent += spacing(node) * Double(max(lines - 1, 0))
        var result = Size.zero
        result[axis] = extent
        result[cross] = tracks.reduce(0) { $0 + $1.length } + tracks.dropLast().reduce(0) { $0 + $1.spacing }
        return result
    }

    func placeLazyGrid(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let axis = gridAxis(node)
        let cross = axis.cross
        let tracks = tracks(gridItems(node), length: rect.size[cross])
        guard !tracks.isEmpty else { return }
        let children = gridChildren(node)
        var position = axis == .vertical ? rect.minY : rect.minX
        var index = 0
        while index < children.count {
            let line = Array(children[index..<min(index + tracks.count, children.count)])
            var lineExtent = 0.0
            for (child, track) in zip(line, tracks) {
                var offer = ProposedSize(width: nil, height: nil)
                offer[cross] = track.length
                lineExtent = max(lineExtent, size(child, offer, environment)[axis].finite)
            }
            var crossPosition = axis == .vertical ? rect.minX : rect.minY
            for (child, track) in zip(line, tracks) {
                let cell = axis == .vertical
                    ? Rect(x: crossPosition, y: position, width: track.length, height: lineExtent)
                    : Rect(x: position, y: crossPosition, width: lineExtent, height: track.length)
                let size = clamp(self.size(child, ProposedSize(cell.size), environment), to: cell.size)
                box.children.append(place(child, in: cell.place(size, track.alignment), environment))
                crossPosition += track.length + track.spacing
            }
            position += lineExtent + spacing(node)
            index += tracks.count
        }
    }
}
