import DynamicUI
import Foundation

/// The parts of a date a `DatePicker` popover steps through.
enum DateField: CaseIterable, Sendable {
    case year, month, day, hour, minute

    var component: Calendar.Component {
        switch self {
        case .year: .year
        case .month: .month
        case .day: .day
        case .hour: .hour
        case .minute: .minute
        }
    }
}

/// An open `DatePicker` popover: the node, where it opens, and which fields
/// it steps.
struct DatePopover {
    var id: RenderNode.ID
    var anchor: Rect
    var fields: [DateField]
}

/// `DatePicker` (`RenderIR.md`): a title, then a date pill and a time pill,
/// each opening a popover of −/+ rows. Values are seconds since 1970, shown
/// in the store's calendar (the local time zone).
extension Layout {

    struct DatePickerProps {
        var title: String
        var value: Double
        var showsDate: Bool
        var showsTime: Bool
        var minimum: Double?
        var maximum: Double?

        init(_ node: RenderNode) {
            title = node.props["title"]?.string ?? ""
            value = node.props["value"]?.double ?? 0
            let components = (node.props["components"]?.string ?? "date").split(separator: ",").map(String.init)
            showsDate = components.contains("date")
            showsTime = components.contains("hourAndMinute")
            if !showsDate && !showsTime { showsDate = true }
            minimum = node.props["min"]?.double
            maximum = node.props["max"]?.double
        }
    }

    /// The pills' texts: the date and the time, as the locale writes them.
    func datePickerTexts(_ props: DatePickerProps) -> (date: String?, time: String?) {
        let date = Date(timeIntervalSince1970: props.value)
        return (props.showsDate ? store.dateFormatter(date: true).string(from: date) : nil,
                props.showsTime ? store.dateFormatter(date: false).string(from: date) : nil)
    }

    private func pillWidth(_ text: String, _ environment: ViewEnvironment) -> Double {
        engine.width(text, font: environment.font).rounded(.up) + 20
    }

    func datePickerSize(_ node: RenderNode, _ proposal: ProposedSize, _ environment: ViewEnvironment) -> Size {
        let props = DatePickerProps(node)
        let texts = datePickerTexts(props)
        let pills = [texts.date, texts.time].compactMap { $0 }.map { pillWidth($0, environment) + 6 }.reduce(0, +)
        let title = props.title.isEmpty ? 0 : textSize(props.title, .unspecified, environment).width + 12
        let height = environment.inListRow ? max(engine.lineHeight(environment.font), 28) : Metrics.controlHeight
        return Size(width: proposal.width ?? title + pills, height: height)
    }

    func placeDatePicker(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let palette = environment.palette
        let props = DatePickerProps(node)
        let texts = datePickerTexts(props)
        var trailing = rect.maxX
        // Time last, at the trailing edge.
        for (text, fields, type) in [(texts.time, [DateField.hour, .minute], "DatePicker.time"),
                                     (texts.date, [DateField.year, .month, .day], "DatePicker.date")] {
            guard let text else { continue }
            let width = min(pillWidth(text, environment), max(trailing - rect.minX, 0))
            let height = min(rect.height, 28)
            let frame = Rect(x: trailing - width, y: rect.midY - height / 2, width: width, height: height)
            let pill = LayoutBox(id: node.id, type: type, frame: frame)
            let open = store.datePopover.map { $0.id == node.id && $0.fields == fields } ?? false
            pill.ops.append(.fill(frame, open || store.isPressed(node.id, type) ? palette.controlPressed : palette.control,
                                  radius: Metrics.controlRadius))
            pill.ops.append(.text(text, environment.font, open ? environment.tintColor : environment.foregroundColor,
                                  frame, .center, wrap: false))
            pill.role = .datePicker(node.id, fields: fields)
            box.children.append(pill)
            trailing = frame.minX - 6
        }
        if !props.title.isEmpty {
            box.ops.append(.text(props.title, environment.font, environment.foregroundColor,
                                 Rect(x: rect.minX, y: rect.minY, width: max(trailing - rect.minX - 6, 0), height: rect.height),
                                 .leading, wrap: false))
        }
    }

    /// The open popover: a card of −/+ rows under its pill.
    func placeDatePopover(_ popover: DatePopover, _ node: RenderNode, _ environment: ViewEnvironment, window: Rect) -> LayoutBox {
        let palette = environment.palette
        let props = DatePickerProps(node)
        let overlay = LayoutBox(id: node.id, type: "DatePopoverOverlay", frame: window)
        overlay.role = .backdrop(nil)
        let rowHeight = 36.0
        let width = min(240.0, max(window.width - 16, 0))
        let height = Double(popover.fields.count) * rowHeight + 16
        var x = min(popover.anchor.maxX - width, window.maxX - width - 8)
        x = max(x, window.minX + 8)
        var y = popover.anchor.maxY + 4
        if y + height > window.maxY - 8 {
            y = max(popover.anchor.minY - 4 - height, window.minY + 8)
        }
        let card = Rect(x: x, y: y, width: width, height: height)
        let cardBox = LayoutBox(id: node.id, type: "DatePopover", frame: card)
        cardBox.decorations.append(.shadow(Color.black.opacity(0.25), radius: 12, card.offsetBy(dx: 0, dy: 3)))
        cardBox.ops.append(.fill(card, palette.card, radius: Metrics.controlRadius + 2))
        cardBox.ops.append(.stroke(card, palette.separator, width: 1, radius: Metrics.controlRadius + 2))
        cardBox.role = .blocker

        let date = Date(timeIntervalSince1970: props.value)
        for (index, field) in popover.fields.enumerated() {
            let row = Rect(x: card.minX + 8, y: card.minY + 8 + Double(index) * rowHeight, width: card.width - 16, height: rowHeight)
            cardBox.ops.append(.text(store.label(field), environment.font, palette.secondary,
                                     Rect(x: row.minX + 4, y: row.minY, width: 70, height: row.height), .leading, wrap: false))
            cardBox.ops.append(.text(store.text(field, of: date), environment.font, environment.foregroundColor,
                                     Rect(x: row.minX + 74, y: row.minY, width: row.width - 74 - 76, height: row.height),
                                     .center, wrap: false))
            for (step, glyph) in [(-1, "−"), (1, "+")] {
                let button = Rect(x: row.maxX - (step < 0 ? 72 : 36), y: row.minY + 4, width: 34, height: row.height - 8)
                let target = store.stepped(props.value, field, by: step, minimum: props.minimum, maximum: props.maximum)
                let part = LayoutBox(id: node.id, type: "DatePopover.\(field)\(step < 0 ? "-" : "+")", frame: button)
                part.ops.append(.fill(button, store.isPressed(node.id, part.type) ? palette.controlPressed : palette.control,
                                      radius: Metrics.controlRadius))
                part.ops.append(.text(glyph, environment.font, target == props.value ? palette.secondary.opacity(0.5) : environment.tintColor,
                                      button, .center, wrap: false))
                part.disabled = target == props.value
                part.role = .dateStep(node.id, value: target)
                cardBox.children.append(part)
            }
        }
        overlay.children.append(cardBox)
        return overlay
    }
}

extension RenderStore {

    /// Formats the pills: the date at medium length, or the time short.
    func dateFormatter(date: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale.current
        formatter.dateStyle = date ? .medium : .none
        formatter.timeStyle = date ? .none : .short
        return formatter
    }

    func label(_ field: DateField) -> String {
        switch field {
        case .year: "Year"
        case .month: "Month"
        case .day: "Day"
        case .hour: "Hour"
        case .minute: "Minute"
        }
    }

    /// A field's value as the popover shows it.
    func text(_ field: DateField, of date: Date) -> String {
        let value = calendar.component(field.component, from: date)
        switch field {
        case .month:
            let symbols = dateFormatter(date: true).shortMonthSymbols ?? []
            return symbols.indices.contains(value - 1) ? symbols[value - 1] : String(value)
        case .hour, .minute:
            return value < 10 ? "0\(value)" : String(value)
        case .year, .day:
            return String(value)
        }
    }

    /// `value` with `field` stepped by `step`, clamped to the bounds.
    func stepped(_ value: Double, _ field: DateField, by step: Int, minimum: Double?, maximum: Double?) -> Double {
        let date = Date(timeIntervalSince1970: value)
        guard let next = calendar.date(byAdding: field.component, value: step, to: date) else { return value }
        var seconds = next.timeIntervalSince1970
        if let minimum { seconds = max(seconds, minimum) }
        if let maximum { seconds = min(seconds, maximum) }
        return seconds
    }
}
