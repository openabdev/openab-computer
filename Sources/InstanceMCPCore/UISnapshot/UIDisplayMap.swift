import Foundation
import CoreGraphics

/// Maps global Accessibility frames onto the display indices and display-relative
/// points that `screenshot` and `mouse` use.
///
/// `AXPosition`/`AXSize` are global CG coordinates (origin at the main display's
/// top-left, y down), the same space as `CGDisplayBounds`. `screenshot` numbers
/// displays by sorting on display id and then putting the main display first, so
/// the order key here is `(isMain ? 0 : 1, id)`.
public struct UIDisplayMap: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        public let id: UInt32
        public let bounds: CGRect
    }

    /// Displays in `screenshot` order: index 0 is the main display.
    public let ordered: [Display]

    public init(displays: [(id: UInt32, bounds: CGRect)], mainID: UInt32) {
        ordered = displays
            .map { Display(id: $0.id, bounds: $0.bounds) }
            .sorted { a, b in
                let ka = a.id == mainID ? 0 : 1, kb = b.id == mainID ? 0 : 1
                return ka != kb ? ka < kb : a.id < b.id
            }
    }

    /// The display a global rect belongs to and the rect relative to that display's
    /// top-left: the display that contains its center, else the one it overlaps
    /// most, else nil (off every screen).
    public func locate(_ rect: CGRect) -> (display: Int, frame: CGRect)? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var pick = ordered.firstIndex { $0.bounds.contains(center) }
        if pick == nil {
            var best: CGFloat = 0
            for (i, d) in ordered.enumerated() {
                let r = d.bounds.intersection(rect)
                let area = r.isNull ? 0 : r.width * r.height
                if area > best { best = area; pick = i }
            }
        }
        guard let i = pick else { return nil }
        return (i, relative(rect, to: i))
    }

    /// `rect` relative to display `index`'s origin (display 0 when out of range).
    public func relative(_ rect: CGRect, to index: Int) -> CGRect {
        let origin = ordered.indices.contains(index) ? ordered[index].bounds.origin : .zero
        return CGRect(x: rect.origin.x - origin.x, y: rect.origin.y - origin.y,
                      width: rect.width, height: rect.height)
    }

    var json: JSONValue {
        .array(ordered.enumerated().map { i, d in
            ["index": .number(Double(i)), "x": .number(d.bounds.origin.x), "y": .number(d.bounds.origin.y),
             "width": .number(d.bounds.width), "height": .number(d.bounds.height)]
        })
    }
}
