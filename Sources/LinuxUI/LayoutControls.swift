import DynamicUI
import Foundation

/// Controls (`Plan.md` §5.4): buttons, toggles, text fields, sliders,
/// steppers, progress, pickers, menus, links and disclosure groups.
extension Layout {

    // MARK: Measuring

    func controlSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size? {
        let props = node.props
        switch node.type {
        case "Button", "Menu", "Link":
            let label = node.type == "Menu" ? menuLabelSize(node, proposal, environment) : labelSize(node.children, proposal, environment)
            if environment.inListRow || environment.plainButtons || node.type == "Link" {
                return label
            }
            let padding = Metrics.buttonPadding
            return Size(width: label.width + padding.horizontal,
                        height: max(label.height + padding.vertical, Metrics.controlHeight))
        case "NavigationLink":
            let label = labelSize(node.children, proposal, environment)
            guard environment.inListRow else { return label }
            let chevron = engine.width("›", font: environment.font) + 8
            return Size(width: proposal.width.map { $0.isFinite ? $0 : label.width + chevron } ?? label.width + chevron,
                        height: label.height)
        case "Toggle":
            let label = labelSize(node.children, trailing(proposal, Metrics.switchSize.width + 12), environment)
            let natural = label.width + 12 + Metrics.switchSize.width
            return Size(width: proposal.width ?? natural, height: max(label.height, Metrics.switchSize.height))
        case "TextField":
            let height = environment.inListRow ? engine.lineHeight(environment.font) : Metrics.controlHeight
            return Size(width: proposal.width ?? 180, height: height)
        case "Slider":
            return Size(width: proposal.width ?? 180, height: Metrics.sliderHeight)
        case "Stepper":
            let label = labelSize(node.children, trailing(proposal, 84), environment)
            return Size(width: proposal.width ?? label.width + 84, height: max(label.height, 28))
        case "ProgressView":
            let title = props["title"]?.string.map { textSize($0, proposal, environment) }
            if props["value"] == nil {
                let spinner = Size(width: 22, height: 22)
                guard let title else { return spinner }
                return Size(width: max(spinner.width, title.width), height: spinner.height + 6 + title.height)
            }
            return Size(width: proposal.width ?? 180, height: 6 + (title.map { $0.height + 6 } ?? 0))
        case "Picker":
            return pickerSize(node, proposal, environment)
        case "DatePicker":
            return datePickerSize(node, proposal, environment)
        case "DisclosureGroup":
            return disclosureSize(node, proposal, environment)
        default:
            return nil
        }
    }

    private func trailing(_ proposal: ProposedSize, _ width: Double) -> ProposedSize {
        ProposedSize(width: proposal.width.map { max($0 - width, 0) }, height: proposal.height)
    }

    /// A control's label views, side by side.
    func labelSize(_ children: [RenderNode], _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        arrange(children, axis: .horizontal, spacing: 6, proposal, environment).size
    }

    private func menuLabelSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let title = menuTitle(node)
        return textSize(title, proposal, environment)
    }

    func menuTitle(_ node: RenderNode) -> String {
        let icon = node.props["systemImage"]?.string.map { Symbols.glyph($0) }
        let title = node.props["title"]?.string ?? ""
        return [icon, title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Placing

    func placeControl(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) -> Bool {
        let palette = environment.palette
        let props = node.props
        switch node.type {
        case "Button", "Menu":
            let destructive = props["role"]?.string == "destructive"
            var label = environment
            label.foreground = environment.foreground ?? (destructive ? palette.destructive : environment.tintColor)
            label.plainButtons = true
            let pressed = store.isPressed(node.id)
            if environment.inListRow {
                // The row highlights (`placeRow`).
            } else if !environment.plainButtons {
                box.ops.append(.fill(rect, pressed ? palette.controlPressed : palette.control, radius: Metrics.controlRadius))
            } else if pressed {
                label.foreground = label.foreground?.opacity(0.5)
            }
            let content = environment.inListRow || environment.plainButtons ? rect : rect.inset(by: Metrics.buttonPadding)
            if node.type == "Menu" {
                let title = menuTitle(node)
                box.ops.append(.text(title, label.font, label.foregroundColor, content, .center, wrap: false))
                box.role = .menu(menuItems(node.children))
            } else {
                placeLabel(node.children, in: content, label, box, alignment: environment.inListRow ? .leading : .center)
                box.role = .tap(node.id)
            }
            return true
        case "Link":
            var label = environment
            label.foreground = environment.foreground ?? environment.tintColor
            if store.isPressed(node.id) {
                label.foreground = label.foreground?.opacity(0.5)
            }
            placeLabel(node.children, in: rect, label, box, alignment: .leading)
            box.role = .link(props["url"]?.string ?? "")
            return true
        case "NavigationLink":
            var label = environment
            if environment.inListRow {
                let chevronWidth = engine.width("›", font: environment.font).rounded(.up)
                box.ops.append(.text("›", environment.font, palette.secondary,
                                     Rect(x: rect.maxX - chevronWidth, y: rect.minY, width: chevronWidth, height: rect.height),
                                     .trailing, wrap: false))
                placeLabel(node.children, in: Rect(x: rect.minX, y: rect.minY, width: max(rect.width - chevronWidth - 8, 0),
                                                   height: rect.height), label, box, alignment: .leading)
            } else {
                label.foreground = environment.foreground ?? environment.tintColor
                if store.isPressed(node.id) {
                    label.foreground = label.foreground?.opacity(0.5)
                }
                placeLabel(node.children, in: rect, label, box, alignment: .center)
            }
            box.role = .tap(node.id)
            return true
        case "Toggle":
            let isOn = props["isOn"]?.bool ?? false
            let switchRect = Rect(x: rect.maxX - Metrics.switchSize.width, y: rect.midY - Metrics.switchSize.height / 2,
                                  width: Metrics.switchSize.width, height: Metrics.switchSize.height)
            placeLabel(node.children, in: Rect(x: rect.minX, y: rect.minY, width: max(switchRect.minX - 12 - rect.minX, 0),
                                               height: rect.height), environment, box, alignment: .leading)
            let track = isOn ? environment.tintColor : palette.controlPressed
            box.ops.append(.fill(switchRect, track, radius: switchRect.height / 2))
            let knob = switchRect.height - 4
            let knobX = isOn ? switchRect.maxX - 2 - knob : switchRect.minX + 2
            box.ops.append(.circle(Point(x: knobX + knob / 2, y: switchRect.midY), radius: knob / 2, .white))
            box.role = .toggle(node.id, isOn: isOn)
            box.hitRect = rect
            return true
        case "TextField":
            placeTextField(node, in: rect, environment, box)
            return true
        case "Slider":
            let minimum = props["min"]?.double ?? 0, maximum = props["max"]?.double ?? 1
            let value = store.sliderValue(node.id, ir: props["value"]?.double ?? minimum)
            let fraction = maximum > minimum ? min(max((value - minimum) / (maximum - minimum), 0), 1) : 0
            let track = Rect(x: rect.minX + Metrics.knob / 2, y: rect.midY - 2, width: max(rect.width - Metrics.knob, 0), height: 4)
            box.ops.append(.fill(track, palette.controlPressed, radius: 2))
            box.ops.append(.fill(Rect(x: track.minX, y: track.minY, width: track.width * fraction, height: 4),
                                 environment.tintColor, radius: 2))
            let center = Point(x: track.minX + track.width * fraction, y: rect.midY)
            box.ops.append(.circle(Point(x: center.x, y: center.y + 1), radius: Metrics.knob / 2 + 0.5, Color.black.opacity(0.2)))
            box.ops.append(.circle(center, radius: Metrics.knob / 2, .white))
            box.role = .slider(node.id, value: value, min: minimum, max: maximum, step: props["step"]?.double, track: track)
            return true
        case "Stepper":
            let value = props["value"]?.int ?? 0
            let minimum = props["min"]?.int ?? .min, maximum = props["max"]?.int ?? .max
            let step = props["step"]?.int ?? 1
            let buttons = Rect(x: rect.maxX - 76, y: rect.midY - 14, width: 76, height: 28)
            placeLabel(node.children, in: Rect(x: rect.minX, y: rect.minY, width: max(buttons.minX - 8 - rect.minX, 0),
                                               height: rect.height), environment, box, alignment: .leading)
            box.ops.append(.fill(buttons, palette.control, radius: Metrics.controlRadius))
            box.ops.append(.fill(Rect(x: buttons.midX - 0.5, y: buttons.minY + 6, width: 1, height: buttons.height - 12),
                                 palette.separator, radius: 0))
            for (index, glyph) in ["−", "+"].enumerated() {
                let half = Rect(x: buttons.minX + Double(index) * buttons.width / 2, y: buttons.minY,
                                width: buttons.width / 2, height: buttons.height)
                let target = index == 0 ? value - step : value + step
                let enabled = index == 0 ? value > minimum : value < maximum
                let part = LayoutBox(id: node.id, type: index == 0 ? "Stepper.decrement" : "Stepper.increment", frame: half)
                if store.isPressed(node.id, part.type) {
                    part.ops.append(.fill(half, palette.controlPressed, radius: Metrics.controlRadius))
                }
                part.ops.append(.text(glyph, environment.font, enabled ? environment.foregroundColor : palette.secondary.opacity(0.5),
                                      half, .center, wrap: false))
                part.disabled = !enabled || environment.disabled
                part.role = .stepper(node.id, value: min(max(target, minimum), maximum), min: minimum, max: maximum, step: step)
                box.children.append(part)
            }
            return true
        case "ProgressView":
            var top = rect.minY
            if props["value"] == nil {
                let spinner = Rect(x: rect.midX - 11, y: rect.minY, width: 22, height: 22)
                for index in 0..<8 {
                    let angle = Double(index) / 8 * 2 * Double.pi
                    box.ops.append(.circle(Point(x: spinner.midX + 8 * cos(angle), y: spinner.midY + 8 * sin(angle)),
                                           radius: 2.2, palette.secondary.opacity(0.25 + 0.75 * Double(index) / 8)))
                }
                if let title = props["title"]?.string {
                    box.ops.append(.text(title, environment.font, palette.secondary,
                                         Rect(x: rect.minX, y: spinner.maxY + 6, width: rect.width, height: rect.maxY - spinner.maxY - 6),
                                         .center, wrap: true))
                }
                return true
            }
            if let title = props["title"]?.string {
                let size = textSize(title, ProposedSize(width: rect.width, height: nil), environment)
                box.ops.append(.text(title, environment.font, environment.foregroundColor,
                                     Rect(x: rect.minX, y: top, width: rect.width, height: size.height), .leading, wrap: true))
                top += size.height + 6
            }
            let total = props["total"]?.double ?? 1
            let fraction = total > 0 ? min(max((props["value"]?.double ?? 0) / total, 0), 1) : 0
            let bar = Rect(x: rect.minX, y: top, width: rect.width, height: 6)
            box.ops.append(.fill(bar, palette.controlPressed, radius: 3))
            box.ops.append(.fill(Rect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: 6), environment.tintColor, radius: 3))
            return true
        case "Picker":
            placePicker(node, in: rect, environment, box)
            return true
        case "DatePicker":
            placeDatePicker(node, in: rect, environment, box)
            return true
        case "DisclosureGroup":
            placeDisclosure(node, in: rect, environment, box)
            return true
        default:
            return false
        }
    }

    /// Places a control's label views side by side, vertically centered.
    func placeLabel(_ children: [RenderNode], in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox,
                    alignment: HorizontalAlignment) {
        let (size, sizes) = arrange(children, axis: .horizontal, spacing: 6, ProposedSize(rect.size), environment)
        var x: Double
        switch alignment {
        case .leading: x = rect.minX
        case .center: x = rect.minX + max(rect.width - size.width, 0) / 2
        case .trailing: x = rect.maxX - size.width
        }
        var labelEnvironment = environment
        labelEnvironment.stackAxis = .horizontal
        for (child, childSize) in zip(children, sizes) {
            let height = min(childSize.height, rect.height)
            let childRect = Rect(x: x, y: rect.midY - height / 2, width: min(childSize.width, rect.maxX - x), height: height)
            box.children.append(place(child, in: childRect, labelEnvironment))
            x += childSize.width + 6
        }
    }

    // MARK: Text fields

    private func placeTextField(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        let editor = store.editor(node.id, ir: node.props["text"]?.string ?? "")
        let focused = store.focused == node.id
        let chrome = !environment.inListRow
        if chrome {
            box.ops.append(.fill(rect, palette.control, radius: Metrics.controlRadius))
            if focused {
                box.ops.append(.stroke(rect, environment.tintColor.opacity(0.6), width: 2, radius: Metrics.controlRadius))
            }
        }
        let inner = chrome ? rect.insetBy(dx: 10, dy: 0) : rect
        let secure = node.props["secure"]?.bool == true
        let shown = secure ? String(repeating: "•", count: editor.text.count) : editor.text
        let font = environment.font
        let caretX = engine.width(String(shown.prefix(editor.cursor)), font: font)
        let shift = max(caretX - inner.width + 2, 0)
        box.ops.append(.clip(inner))
        if shown.isEmpty {
            box.ops.append(.text(node.props["placeholder"]?.string ?? "", font, palette.secondary, inner, .leading, wrap: false))
        } else {
            let textRect = Rect(x: inner.minX - shift, y: inner.minY, width: inner.width + shift, height: inner.height)
            box.ops.append(.text(shown, font, environment.foregroundColor, textRect, .leading, wrap: false))
        }
        if focused, store.caretVisible {
            let line = engine.lineHeight(font)
            let x = inner.minX + caretX - shift
            box.ops.append(.fill(Rect(x: x, y: inner.midY - line / 2, width: 1.5, height: line), environment.tintColor, radius: 0))
        }
        box.ops.append(.unclip)
        box.role = .textField(node.id)
        store.textFieldFrames[node.id] = (inner, shift)
    }

    // MARK: Pickers

    private func pickerStyle(_ node: RenderNode) -> String {
        node.props["style"]?.string ?? "menu"
    }

    private func pickerSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let title = node.props["title"]?.string ?? ""
        switch pickerStyle(node) {
        case "segmented":
            let widths = node.children.map { textSize(nodeTitle($0), .unspecified, environment).width + 24 }
            let natural = (widths.max() ?? 0) * Double(node.children.count)
            return Size(width: proposal.width.map { $0.isFinite ? $0 : natural } ?? natural, height: 30)
        case "inline":
            let row = max(engine.lineHeight(environment.font) + 16, Metrics.rowMinHeight)
            return Size(width: proposal.width ?? 200, height: row * Double(node.children.count))
        default:
            let selected = node.props["selection"]?.int.flatMap { node.children.indices.contains($0) ? nodeTitle(node.children[$0]) : nil } ?? ""
            let button = textSize(selected + " ⌄", .unspecified, environment).width + Metrics.buttonPadding.horizontal
            let label = title.isEmpty ? 0 : textSize(title, .unspecified, environment).width + 12
            return Size(width: proposal.width ?? label + button, height: environment.inListRow ? engine.lineHeight(environment.font) : Metrics.controlHeight)
        }
    }

    private func placePicker(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        let selection = node.props["selection"]?.int
        let titles = node.children.map(nodeTitle)
        switch pickerStyle(node) {
        case "segmented":
            box.ops.append(.fill(rect, palette.control, radius: Metrics.controlRadius))
            let width = rect.width / Double(max(titles.count, 1))
            for (index, title) in titles.enumerated() {
                let segment = Rect(x: rect.minX + Double(index) * width, y: rect.minY, width: width, height: rect.height)
                let part = LayoutBox(id: node.id, type: "Picker.segment", frame: segment)
                if index == selection {
                    part.ops.append(.fill(segment.insetBy(dx: 2, dy: 2), palette.card, radius: Metrics.controlRadius - 2))
                } else if index > 0, index - 1 != selection {
                    part.ops.append(.fill(Rect(x: segment.minX, y: segment.minY + 7, width: 1, height: segment.height - 14),
                                          palette.separator, radius: 0))
                }
                var font = environment.font
                if index == selection { font.weight = max(font.weight, 600) }
                part.ops.append(.text(title, font, environment.foregroundColor, segment, .center, wrap: false))
                part.role = .select(node.id, index: index)
                box.children.append(part)
            }
        case "inline":
            let row = rect.height / Double(max(titles.count, 1))
            for (index, title) in titles.enumerated() {
                let frame = Rect(x: rect.minX, y: rect.minY + Double(index) * row, width: rect.width, height: row)
                let part = LayoutBox(id: node.id, type: "Picker.row", frame: frame)
                if index > 0 {
                    part.ops.append(.fill(Rect(x: frame.minX, y: frame.minY, width: frame.width, height: 1), palette.separator, radius: 0))
                }
                part.ops.append(.text(title, environment.font, environment.foregroundColor, frame.insetBy(dx: 4, dy: 0), .leading, wrap: false))
                if index == selection {
                    part.ops.append(.text("✓", environment.font, environment.tintColor, frame.insetBy(dx: 4, dy: 0), .trailing, wrap: false))
                }
                part.role = .select(node.id, index: index)
                box.children.append(part)
            }
        default:
            let title = node.props["title"]?.string ?? ""
            let selected = selection.flatMap { titles.indices.contains($0) ? titles[$0] : nil } ?? ""
            let buttonText = selected + " ⌄"
            let buttonWidth = min(engine.width(buttonText, font: environment.font).rounded(.up) + Metrics.buttonPadding.horizontal, rect.width)
            let button = Rect(x: rect.maxX - buttonWidth, y: rect.minY, width: buttonWidth, height: rect.height)
            if !title.isEmpty {
                box.ops.append(.text(title, environment.font, environment.foregroundColor,
                                     Rect(x: rect.minX, y: rect.minY, width: max(button.minX - rect.minX - 8, 0), height: rect.height),
                                     .leading, wrap: false))
            }
            if !environment.inListRow {
                box.ops.append(.fill(button, store.isPressed(node.id) ? palette.controlPressed : palette.control, radius: Metrics.controlRadius))
            }
            box.ops.append(.text(buttonText, environment.font, environment.inListRow ? palette.secondary : environment.tintColor,
                                 button, .center, wrap: false))
            box.role = .menu(titles.enumerated().map { index, title in
                PopupItem(title: title, checked: index == selection, action: .select(node.id, index: index))
            })
            box.hitRect = environment.inListRow ? rect : button
        }
    }

    // MARK: Disclosure groups

    private func disclosureHeader(_ node: RenderNode, _ environment: ViewEnvironment) -> Double {
        max(engine.lineHeight(environment.font) + 12, 32)
    }

    private func disclosureSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let header = disclosureHeader(node, environment)
        let label = node.children.first.map { size($0, trailing(proposal, 24), environment) } ?? .zero
        var result = Size(width: label.width + 24, height: header)
        if node.props["isExpanded"]?.bool == true, node.children.count > 1 {
            let content = arrange(Array(node.children.dropFirst()), axis: .vertical, spacing: Metrics.stackSpacing,
                                  trailing(proposal, 20), environment).size
            result.width = max(result.width, content.width + 20)
            result.height += content.height + 4
        }
        if let width = proposal.width, width.isFinite { result.width = width }
        return result
    }

    private func placeDisclosure(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let expanded = node.props["isExpanded"]?.bool == true
        let headerHeight = disclosureHeader(node, environment)
        let header = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        let part = LayoutBox(id: node.id, type: "DisclosureGroup.header", frame: header)
        if store.isPressed(node.id, part.type) {
            part.ops.append(.fill(header, environment.palette.highlight, radius: 6))
        }
        part.ops.append(.text(expanded ? "▾" : "▸", environment.font, environment.tintColor,
                              Rect(x: header.minX, y: header.minY, width: 18, height: header.height), .center, wrap: false))
        if let label = node.children.first {
            let size = self.size(label, ProposedSize(width: header.width - 24, height: header.height), environment)
            part.children.append(place(label, in: Rect(x: header.minX + 24, y: header.midY - size.height / 2,
                                                       width: min(size.width, header.width - 24), height: size.height), environment))
        }
        part.role = .disclosure(node.id, isExpanded: expanded)
        box.children.append(part)
        if expanded, node.children.count > 1 {
            let content = Rect(x: rect.minX + 20, y: header.maxY + 4, width: max(rect.width - 20, 0), height: max(rect.maxY - header.maxY - 4, 0))
            placeSequence(Array(node.children.dropFirst()), axis: .vertical, spacing: Metrics.stackSpacing, alignment: "leading",
                          in: content, environment, box)
        }
    }

    // MARK: Menus

    /// A `Menu`'s or row's items as popup rows: buttons, dividers, sections
    /// (a separator and a header), and nested menus (indented).
    func menuItems(_ nodes: [RenderNode], indent: Int = 0) -> [PopupItem] {
        var items: [PopupItem] = []
        for node in nodes {
            switch node.type {
            case "Button":
                let icon = firstGlyph(node)
                items.append(PopupItem(
                    title: nodeTitle(node), glyph: icon,
                    destructive: node.props["role"]?.string == "destructive",
                    enabled: !node.modifiers.contains { $0.kind == "disabled" && $0.args["value"]?.bool != false },
                    indent: indent, action: .tap(node.id)
                ))
            case "Divider":
                items.append(.divider)
            case "Section":
                if !items.isEmpty { items.append(.divider) }
                if let header = node.props["header"]?.string {
                    items.append(PopupItem(title: header, header: true, indent: indent))
                }
                items += menuItems(node.children, indent: indent)
            case "Menu":
                items.append(PopupItem(title: menuTitle(node), header: true, indent: indent))
                items += menuItems(node.children, indent: indent + 1)
            case "Picker":
                let selection = node.props["selection"]?.int
                if let title = node.props["title"]?.string, !title.isEmpty {
                    items.append(PopupItem(title: title, header: true, indent: indent))
                }
                for (index, option) in node.children.enumerated() {
                    items.append(PopupItem(title: nodeTitle(option), checked: index == selection, indent: indent,
                                           action: .select(node.id, index: index)))
                }
            case "Toggle":
                items.append(PopupItem(title: nodeTitle(node), checked: node.props["isOn"]?.bool == true, indent: indent,
                                       action: .tap(node.id)))
            default:
                items += menuItems(node.children, indent: indent)
            }
        }
        return items
    }

    /// The text a node shows, for menus, pickers and back buttons.
    func nodeTitle(_ node: RenderNode) -> String {
        if let text = node.props["text"]?.string ?? node.props["title"]?.string {
            return text
        }
        for child in node.children {
            let title = nodeTitle(child)
            if !title.isEmpty { return title }
        }
        return ""
    }

    private func firstGlyph(_ node: RenderNode) -> String? {
        if let name = node.props["systemImage"]?.string ?? (node.type == "Image" ? node.props["systemName"]?.string : nil) {
            return Symbols.glyph(name)
        }
        for child in node.children {
            if let glyph = firstGlyph(child) { return glyph }
        }
        return nil
    }
}
