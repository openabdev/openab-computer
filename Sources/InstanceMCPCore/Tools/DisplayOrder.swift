import Foundation
import CoreGraphics

/// The one display numbering `screenshot`, `mouse` and `ui_snapshot` share: the main
/// display is index 0, the others follow in ascending display id.
enum DisplayOrder {
    /// `items` in display-index order. `id` extracts each item's display id.
    static func sorted<T>(_ items: [T], mainID: UInt32, id: (T) -> UInt32) -> [T] {
        items.sorted { a, b in
            let ia = id(a), ib = id(b)
            let ka = ia == mainID ? 0 : 1, kb = ib == mainID ? 0 : 1
            return ka != kb ? ka < kb : ia < ib
        }
    }

    /// Active display ids (CoreGraphics; no Screen Recording needed) in index order.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return sorted(Array(ids.prefix(Int(count))), mainID: CGMainDisplayID()) { $0 }
    }
}
