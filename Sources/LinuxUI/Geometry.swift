/// A point, in points from the window's top-left corner.
public struct Point: Equatable, Hashable, Sendable {

    public var x: Double

    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Equatable, Hashable, Sendable {

    public var width: Double

    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    subscript(axis: Axis) -> Double {
        get { axis == .horizontal ? width : height }
        set {
            if axis == .horizontal { width = newValue } else { height = newValue }
        }
    }
}

public struct Rect: Equatable, Hashable, Sendable {

    public var origin: Point

    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { origin.x }

    public var minY: Double { origin.y }

    public var maxX: Double { origin.x + size.width }

    public var maxY: Double { origin.y + size.height }

    public var midX: Double { origin.x + size.width / 2 }

    public var midY: Double { origin.y + size.height / 2 }

    public var width: Double { size.width }

    public var height: Double { size.height }

    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersection(_ other: Rect) -> Rect {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        return Rect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }

    public func intersects(_ other: Rect) -> Bool {
        !intersection(other).isEmpty
    }

    public func inset(by insets: EdgeInsets) -> Rect {
        Rect(
            x: minX + insets.leading,
            y: minY + insets.top,
            width: max(width - insets.leading - insets.trailing, 0),
            height: max(height - insets.top - insets.bottom, 0)
        )
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        inset(by: EdgeInsets(top: dy, leading: dx, bottom: dy, trailing: dx))
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width, height: height)
    }

    /// Where a `size` sits inside this rectangle at `alignment`.
    public func place(_ size: Size, _ alignment: Alignment) -> Rect {
        let x: Double
        switch alignment.horizontal {
        case .leading: x = minX
        case .center: x = minX + (width - size.width) / 2
        case .trailing: x = maxX - size.width
        }
        let y: Double
        switch alignment.vertical {
        case .top: y = minY
        case .center: y = minY + (height - size.height) / 2
        case .bottom: y = maxY - size.height
        }
        return Rect(origin: Point(x: x, y: y), size: size)
    }
}

public struct EdgeInsets: Equatable, Hashable, Sendable {

    public var top: Double

    public var leading: Double

    public var bottom: Double

    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all value: Double) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    public var horizontal: Double { leading + trailing }

    public var vertical: Double { top + bottom }
}

public enum Axis: Sendable {
    case horizontal
    case vertical

    var cross: Axis {
        self == .horizontal ? .vertical : .horizontal
    }
}

public enum HorizontalAlignment: Sendable {
    case leading, center, trailing

    init(_ name: String?) {
        switch name {
        case "leading": self = .leading
        case "trailing": self = .trailing
        default: self = .center
        }
    }
}

public enum VerticalAlignment: Sendable {
    case top, center, bottom

    init(_ name: String?) {
        switch name {
        case "top": self = .top
        case "bottom": self = .bottom
        default: self = .center
        }
    }
}

public struct Alignment: Sendable {

    public var horizontal: HorizontalAlignment

    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment = .center, vertical: VerticalAlignment = .center) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment()

    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)

    public static let leading = Alignment(horizontal: .leading)
}

/// What a parent offers a child (SwiftUI's `ProposedViewSize`): `nil` asks
/// for the child's ideal size along that axis, `.infinity` for its largest.
public struct ProposedSize: Equatable, Sendable {

    public var width: Double?

    public var height: Double?

    public init(width: Double?, height: Double?) {
        self.width = width
        self.height = height
    }

    public init(_ size: Size) {
        self.init(width: size.width, height: size.height)
    }

    public static let unspecified = ProposedSize(width: nil, height: nil)

    subscript(axis: Axis) -> Double? {
        get { axis == .horizontal ? width : height }
        set {
            if axis == .horizontal { width = newValue } else { height = newValue }
        }
    }

    func inset(by insets: EdgeInsets) -> ProposedSize {
        ProposedSize(
            width: width.map { max($0 - insets.horizontal, 0) },
            height: height.map { max($0 - insets.vertical, 0) }
        )
    }

    /// The size this proposal names, with `fallback` for what it leaves
    /// open.
    func replacingUnspecified(with fallback: Size) -> Size {
        Size(width: width ?? fallback.width, height: height ?? fallback.height)
    }
}

extension Double {

    /// A length a view can take: never infinite or negative.
    var finite: Double {
        isFinite ? Swift.max(self, 0) : 0
    }
}
