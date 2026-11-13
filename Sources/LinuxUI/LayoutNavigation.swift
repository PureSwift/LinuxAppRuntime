import DynamicUI

/// Navigation stacks with their header bars, toolbars and search fields;
/// tab views; and the overlays: sheets, alerts and popup menus.
extension Layout {

    // MARK: Measuring

    func navigationSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size? {
        switch node.type {
        case "NavStack", "TabView":
            return proposal.replacingUnspecified(with: Size(width: 360, height: 480))
        case "NavLevel", "Tab", "ToolbarItem":
            return arrange(contentChildren(node), axis: .vertical, spacing: Metrics.stackSpacing, proposal, environment).size
        default:
            return nil
        }
    }

    /// A level's or tab's views, without its toolbar items.
    func contentChildren(_ node: RenderNode) -> [RenderNode] {
        node.children.filter { $0.type != "ToolbarItem" }
    }

    // MARK: Placing

    func placeNavigation(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) -> Bool {
        switch node.type {
        case "NavStack":
            placeNavStack(node, in: rect, environment, box)
        case "TabView":
            placeTabView(node, in: rect, environment, box)
        case "NavLevel", "Tab", "ToolbarItem":
            placeFilling(contentChildren(node), in: rect, environment, box)
        default:
            return false
        }
        return true
    }

    /// Places views in an area they may not fill: one view centered, as
    /// SwiftUI does, or several stacked and centered.
    func placeFilling(_ children: [RenderNode], in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let (size, _) = arrange(children, axis: .vertical, spacing: Metrics.stackSpacing, ProposedSize(rect.size), environment)
        let area = rect.place(clamp(size, to: rect.size), .center)
        placeSequence(children, axis: .vertical, spacing: Metrics.stackSpacing, alignment: nil, in: area, environment, box)
    }

    private func placeNavStack(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        let levels = node.children.filter { $0.type == "NavLevel" }
        guard let level = levels.last else { return }
        let search = findSearchable(in: level)
        if let search {
            hoistedSearches.insert(search.id)
        }
        let barHeight = Metrics.navBarHeight + (search != nil ? Metrics.searchFieldHeight + 8 : 0)
        let bar = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight)
        let items = level.children.filter { $0.type == "ToolbarItem" }
        let bottomItems = items.filter { $0.props["placement"]?.string == "bottomBar" }
        let bottomHeight = bottomItems.isEmpty ? 0 : Metrics.tabBarHeight
        let content = Rect(x: rect.minX, y: bar.maxY, width: rect.width, height: max(rect.height - barHeight - bottomHeight, 0))

        // Content first: the bar draws over anything that scrolls under it.
        let contentBox = LayoutBox(id: level.id, type: "NavLevel", frame: content)
        contentBox.clip = content
        placeFilling(contentChildren(level), in: content, environment, contentBox)
        box.children.append(contentBox)

        let barBox = LayoutBox(id: node.id, type: "NavBar", frame: bar)
        barBox.ops.append(.fill(bar, palette.bar, radius: 0))
        barBox.ops.append(.fill(Rect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1), palette.separator, radius: 0))
        barBox.role = .blocker
        let row = Rect(x: bar.minX + 8, y: bar.minY, width: max(bar.width - 16, 0), height: Metrics.navBarHeight)
        var leading = row.minX
        var trailingEdge = row.maxX
        var plain = environment
        plain.plainButtons = true

        if levels.count > 1 {
            let previous = levels[levels.count - 2].props["title"]?.string ?? ""
            let title = "‹ " + (previous.isEmpty ? "Back" : previous)
            let width = min(engine.width(title, font: environment.font).rounded(.up) + 16, row.width / 3)
            let back = LayoutBox(id: node.id, type: "NavBar.back", frame: Rect(x: leading, y: row.minY + 7, width: width, height: row.height - 14))
            let pressed = store.isPressed(node.id, back.type)
            back.ops.append(.fill(back.frame, pressed ? palette.controlPressed : palette.control, radius: Metrics.controlRadius))
            back.ops.append(.text(title, environment.font, environment.tintColor, back.frame, .center, wrap: false))
            back.role = .back(node.id, levels: levels.count - 1)
            barBox.children.append(back)
            leading += width + 8
        }
        func placeItem(_ item: RenderNode, trailing: Bool) {
            let size = clamp(self.size(item, ProposedSize(width: nil, height: row.height - 10), plain), to: Size(width: row.width / 3, height: row.height))
            let x = trailing ? trailingEdge - size.width : leading
            let frame = Rect(x: x, y: row.midY - size.height / 2, width: size.width, height: size.height)
            barBox.children.append(place(item, in: frame, plain))
            if trailing { trailingEdge = frame.minX - 12 } else { leading = frame.maxX + 12 }
        }
        var principal: RenderNode?
        for item in items {
            switch item.props["placement"]?.string {
            case "navigation", "cancellationAction": placeItem(item, trailing: false)
            case "principal": principal = item
            case "bottomBar": break
            default: break
            }
        }
        for item in items.reversed() where ["automatic", "primaryAction", "confirmationAction", nil].contains(item.props["placement"]?.string) {
            placeItem(item, trailing: true)
        }
        let titleSpace = max(min(leading - row.minX, row.maxX - trailingEdge), 0)
        let titleRect = Rect(x: row.minX + titleSpace, y: row.minY, width: max(row.width - titleSpace * 2, 0), height: row.height)
        if let principal {
            let size = clamp(self.size(principal, ProposedSize(titleRect.size), plain), to: titleRect.size)
            barBox.children.append(place(principal, in: titleRect.place(size, .center), plain))
        } else if let title = level.props["title"]?.string {
            var font = environment.font
            font.weight = 700
            barBox.ops.append(.text(title, font, environment.foregroundColor, titleRect, .center, wrap: false))
        }
        if let search {
            let field = Rect(x: bar.minX + 12, y: row.maxY, width: max(bar.width - 24, 0), height: Metrics.searchFieldHeight)
            barBox.children.append(searchField(search, in: field, environment))
        }
        box.children.append(barBox)

        if !bottomItems.isEmpty {
            let bottom = Rect(x: rect.minX, y: rect.maxY - bottomHeight, width: rect.width, height: bottomHeight)
            let bottomBox = LayoutBox(id: node.id, type: "BottomBar", frame: bottom)
            bottomBox.ops.append(.fill(bottom, palette.bar, radius: 0))
            bottomBox.ops.append(.fill(Rect(x: bottom.minX, y: bottom.minY, width: bottom.width, height: 1), palette.separator, radius: 0))
            bottomBox.role = .blocker
            placeSequence(bottomItems, axis: .horizontal, spacing: 16, alignment: nil,
                          in: bottom.insetBy(dx: 16, dy: 10), plain, bottomBox)
            box.children.append(bottomBox)
        }
    }

    /// The first `Searchable` in a level, not counting nested stacks and
    /// presentations.
    private func findSearchable(in node: RenderNode) -> RenderNode? {
        for child in node.children where child.type != "NavStack" && child.type != "ToolbarItem" {
            if child.type == "Searchable" {
                return child
            }
            if child.type == "Sheet" || child.type == "Alert" {
                // Only the presenting view; the content has its own bar.
                if let first = child.children.first {
                    if first.type == "Searchable" { return first }
                    if let found = findSearchable(in: first) { return found }
                }
                continue
            }
            if let found = findSearchable(in: child) {
                return found
            }
        }
        return nil
    }

    /// A `Searchable`'s field: a text field whose events go to the node.
    private func searchField(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment) -> LayoutBox {
        let field = RenderNode("TextField", id: node.id, props: [
            "text": node.props["text"] ?? "",
            "placeholder": node.props["prompt"] ?? "Search",
        ])
        let box = LayoutBox(id: node.id, type: "SearchField", frame: rect)
        _ = placeControl(field, in: rect, environment, box)
        // A magnifying glass inside the field's leading edge.
        return box
    }

    func placeSearchable(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        guard let child = node.children.first else { return }
        if hoistedSearches.contains(node.id) {
            box.children.append(place(child, in: rect, environment))
            return
        }
        // No navigation bar: the field goes above the view.
        let field = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: Metrics.searchFieldHeight)
        box.children.append(searchField(node, in: field, environment))
        let below = Rect(x: rect.minX, y: field.maxY + 8, width: rect.width, height: max(rect.height - field.height - 8, 0))
        box.children.append(place(child, in: below, environment))
    }

    private func placeTabView(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        let tabs = node.children.filter { $0.type == "Tab" }
        let selection = node.props["selection"]?.int
        let bar = Rect(x: rect.minX, y: rect.maxY - Metrics.tabBarHeight, width: rect.width, height: Metrics.tabBarHeight)
        let content = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - bar.height, 0))
        if let selection, tabs.indices.contains(selection) {
            let tab = tabs[selection]
            let tabBox = LayoutBox(id: tab.id, type: "Tab", frame: content)
            tabBox.clip = content
            placeFilling(contentChildren(tab), in: content, environment, tabBox)
            box.children.append(tabBox)
        }
        let barBox = LayoutBox(id: node.id, type: "TabBar", frame: bar)
        barBox.ops.append(.fill(bar, palette.bar, radius: 0))
        barBox.ops.append(.fill(Rect(x: bar.minX, y: bar.minY, width: bar.width, height: 1), palette.separator, radius: 0))
        barBox.role = .blocker
        let width = bar.width / Double(max(tabs.count, 1))
        for (index, tab) in tabs.enumerated() {
            let frame = Rect(x: bar.minX + Double(index) * width, y: bar.minY, width: width, height: bar.height)
            let item = LayoutBox(id: node.id, type: "TabBar.item", frame: frame)
            let color = index == selection ? environment.tintColor : palette.secondary
            let glyph = Symbols.glyph(tab.props["systemImage"]?.string)
            var glyphFont = environment.font
            glyphFont.size = 18
            let caption = FontSpec(size: FontSpec.TextStyles.size("caption2"), weight: index == selection ? 600 : 400)
            item.ops.append(.text(glyph, glyphFont, color, Rect(x: frame.minX, y: frame.minY + 6, width: frame.width, height: 24), .center, wrap: false))
            item.ops.append(.text(tab.props["title"]?.string ?? "", caption, color,
                                  Rect(x: frame.minX, y: frame.minY + 31, width: frame.width, height: 16), .center, wrap: false))
            item.role = .select(node.id, index: index)
            barBox.children.append(item)
        }
        box.children.append(barBox)
    }

    // MARK: Presentations

    /// A presented sheet or alert, over the window.
    func placePresentation(_ node: RenderNode, _ environment: ViewEnvironment, window: Rect) -> LayoutBox {
        let palette = environment.palette
        let overlay = LayoutBox(id: node.id, type: node.type == "Sheet" ? "SheetOverlay" : "AlertOverlay", frame: window)
        let fullScreen = node.type == "Sheet" && node.props["style"]?.string == "fullScreenCover"
        if !fullScreen {
            overlay.ops.append(.fill(window, palette.scrim, radius: 0))
        }
        overlay.role = node.type == "Sheet" ? .backdrop(node.id) : .blocker
        let content = Array(node.children.dropFirst())
        if node.type == "Sheet" {
            let card: Rect
            if fullScreen {
                card = window
            } else {
                let width = min(Metrics.sheetMaxWidth, max(window.width - 48, 0))
                let height = max(window.height - 64, 0)
                card = Rect(x: window.midX - width / 2, y: window.maxY - height, width: width, height: height)
            }
            let cardBox = LayoutBox(id: node.id, type: "Sheet.card", frame: card)
            cardBox.ops.append(.fill(card, palette.background, radius: fullScreen ? 0 : Metrics.cardRadius))
            cardBox.clip = card
            cardBox.role = .blocker
            let previous = visible
            visible = card
            placeFilling(content, in: card, environment, cardBox)
            visible = previous
            overlay.children.append(cardBox)
        } else {
            overlay.children.append(alertCard(node, actions: content, environment, window: window))
        }
        return overlay
    }

    private func alertCard(_ node: RenderNode, actions: [RenderNode], _ environment: ViewEnvironment, window: Rect) -> LayoutBox {
        let palette = environment.palette
        let width = min(Metrics.alertWidth, max(window.width - 32, 0))
        let inner = width - 40
        var headline = environment
        headline.font = FontSpec(size: FontSpec.TextStyles.size("headline") + 1, weight: 700)
        var body = environment
        body.font = FontSpec(size: FontSpec.TextStyles.size("callout"))
        body.textAlignment = .center
        headline.textAlignment = .center
        let showTitle = node.props["titleVisibility"]?.string != "hidden"
        let title = showTitle ? node.props["title"]?.string ?? "" : ""
        let message = node.props["message"]?.string
        let titleSize = title.isEmpty ? .zero : textSize(title, ProposedSize(width: inner, height: nil), headline)
        let messageSize = message.map { textSize($0, ProposedSize(width: inner, height: nil), body) } ?? .zero
        let buttons: [(title: String, id: RenderNode.ID?, role: String?)] = actions.isEmpty
            ? [("OK", nil, "cancel")]
            : actions.map { (nodeTitle($0), $0.id, $0.props["role"]?.string) }
        let side = buttons.count == 2
        let buttonHeight = 44.0
        let buttonsHeight = side ? buttonHeight : buttonHeight * Double(buttons.count)
        let textHeight = titleSize.height + (message != nil ? messageSize.height + (title.isEmpty ? 0 : 6) : 0)
        let height = 24 + textHeight + 20 + buttonsHeight
        let card = Rect(x: window.midX - width / 2, y: window.midY - height / 2, width: width, height: height)
        let box = LayoutBox(id: node.id, type: "Alert.card", frame: card)
        box.ops.append(.fill(card, palette.card, radius: Metrics.cardRadius + 2))
        box.role = .blocker
        var y = card.minY + 24
        if !title.isEmpty {
            box.ops.append(.text(title, headline.font, headline.foregroundColor,
                                 Rect(x: card.minX + 20, y: y, width: inner, height: titleSize.height), .center, wrap: true))
            y += titleSize.height + 6
        }
        if let message {
            box.ops.append(.text(message, body.font, body.foregroundColor,
                                 Rect(x: card.minX + 20, y: y, width: inner, height: messageSize.height), .center, wrap: true))
        }
        let top = card.maxY - buttonsHeight
        box.ops.append(.fill(Rect(x: card.minX, y: top, width: width, height: 1), palette.separator, radius: 0))
        for (index, button) in buttons.enumerated() {
            let frame = side
                ? Rect(x: card.minX + Double(index) * width / 2, y: top, width: width / 2, height: buttonHeight)
                : Rect(x: card.minX, y: top + Double(index) * buttonHeight, width: width, height: buttonHeight)
            let part = LayoutBox(id: button.id ?? node.id, type: "Alert.button", frame: frame)
            if store.isPressed(part.id, part.type) {
                part.ops.append(.fill(frame, palette.highlight, radius: 0))
            }
            if index > 0 {
                part.ops.append(side
                    ? .fill(Rect(x: frame.minX, y: frame.minY, width: 1, height: frame.height), palette.separator, radius: 0)
                    : .fill(Rect(x: frame.minX, y: frame.minY, width: frame.width, height: 1), palette.separator, radius: 0))
            }
            var font = FontSpec(size: FontSpec.TextStyles.size("body"))
            if button.role == "cancel" { font.weight = 600 }
            let color = button.role == "destructive" ? palette.destructive : environment.tintColor
            part.ops.append(.text(button.title, font, color, frame, .center, wrap: false))
            part.role = .alertButton(button.id, alert: node.id)
            box.children.append(part)
        }
        return box
    }

    /// An open popup menu at `anchor`.
    func placePopup(_ popup: Popup, _ environment: ViewEnvironment, window: Rect) -> LayoutBox {
        let palette = environment.palette
        let overlay = LayoutBox(id: 0, type: "PopupOverlay", frame: window)
        overlay.role = .backdrop(nil)
        func height(_ item: PopupItem) -> Double {
            item.separator ? 9 : item.header ? 26 : Metrics.menuRowHeight
        }
        let font = FontSpec(size: FontSpec.TextStyles.size("body"))
        let widest = popup.items.map { engine.width($0.title, font: font) + Double($0.indent) * 14 }.max() ?? 0
        let width = min(max(Metrics.menuWidth, popup.anchor.width, widest + 64), max(window.width - 16, 0))
        let total = popup.items.reduce(8) { $0 + height($1) } + 8
        var x = min(popup.anchor.minX, window.maxX - width - 8)
        x = max(x, window.minX + 8)
        var y = popup.anchor.maxY + 4
        if y + total > window.maxY - 8 {
            y = max(popup.anchor.minY - 4 - total, window.minY + 8)
        }
        let card = Rect(x: x, y: y, width: width, height: min(total, window.height - 16))
        let cardBox = LayoutBox(id: 0, type: "Popup", frame: card)
        cardBox.decorations.append(.shadow(Color.black.opacity(0.25), radius: 12, card.offsetBy(dx: 0, dy: 3)))
        cardBox.ops.append(.fill(card, palette.card, radius: Metrics.controlRadius + 2))
        cardBox.ops.append(.stroke(card, palette.separator, width: 1, radius: Metrics.controlRadius + 2))
        cardBox.role = .blocker
        cardBox.clip = card
        var top = card.minY + 8
        for (index, item) in popup.items.enumerated() {
            let frame = Rect(x: card.minX + 6, y: top, width: card.width - 12, height: height(item))
            top += frame.height
            if item.separator {
                cardBox.ops.append(.fill(Rect(x: frame.minX + 4, y: frame.midY, width: frame.width - 8, height: 1), palette.separator, radius: 0))
                continue
            }
            let row = LayoutBox(id: RenderNode.ID(index), type: "Popup.item", frame: frame)
            let indent = Double(item.indent) * 14
            if item.header {
                let caption = FontSpec(size: FontSpec.TextStyles.size("footnote"), weight: 600)
                row.ops.append(.text(item.title, caption, palette.secondary, frame.inset(by: EdgeInsets(leading: 28 + indent)), .leading, wrap: false))
                cardBox.children.append(row)
                continue
            }
            if popup.highlighted == index, item.enabled {
                row.ops.append(.fill(frame, palette.highlight, radius: 6))
            }
            let color = !item.enabled ? palette.secondary.opacity(0.6) : item.destructive ? palette.destructive : palette.primary
            if item.checked {
                row.ops.append(.text("✓", font, environment.tintColor, Rect(x: frame.minX + 6 + indent, y: frame.minY, width: 18, height: frame.height), .center, wrap: false))
            } else if let glyph = item.glyph {
                row.ops.append(.text(glyph, font, color, Rect(x: frame.minX + 6 + indent, y: frame.minY, width: 18, height: frame.height), .center, wrap: false))
            }
            row.ops.append(.text(item.title, font, color, frame.inset(by: EdgeInsets(leading: 30 + indent, trailing: 8)), .leading, wrap: false))
            row.disabled = !item.enabled
            row.role = .popupItem(item)
            cardBox.children.append(row)
        }
        overlay.children.append(cardBox)
        return overlay
    }
}

/// An open popup menu.
struct Popup {
    var anchor: Rect
    var items: [PopupItem]
    /// The row under the pointer.
    var highlighted: Int?
}
