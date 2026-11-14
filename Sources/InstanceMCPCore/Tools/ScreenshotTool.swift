import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One-shot screen capture via ScreenCaptureKit, returned as an MCP image block so the
/// model sees it directly. Needs the Screen Recording TCC grant for this binary's
/// signature; without it `SCShareableContent` throws and we return a clear error.
public struct ScreenshotTool: Tool {
    public let name = "screenshot"
    public let description = """
        Capture the current screen of this Mac and return it as an image. Use `display` \
        (0-based index, default 0 = main) on multi-monitor setups. `scale` (default 1.0 = one pixel \
        per display point; menu-bar text needs ≥1.0 to be legible) downsamples. `region` {x,y,width,height} \
        in display points crops before scaling — use it to zoom into a dialog or the menu bar cheaply. \
        `format` jpeg (default, `quality` 0–1) or png. All coordinates are display POINTS, the same \
        space `mouse` uses; a crop's pixel (px,py) maps to point (region.x + px/scale, region.y + py/scale).
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "display": ["type": "integer", "description": "Display index, 0 = main.", "default": 0],
            "scale": ["type": "number", "description": "Output pixels per display point. Default 1.0.", "minimum": 0.1, "maximum": 2.0],
            "region": ["type": "object", "description": "Crop rectangle in display points.", "properties": [
                "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
                "required": ["x", "y", "width", "height"]],
            "format": ["type": "string", "enum": ["jpeg", "png"], "default": "jpeg"],
            "quality": ["type": "number", "description": "JPEG quality 0–1. Default 0.7.", "minimum": 0.1, "maximum": 1.0],
        ],
    ]

    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        let index = arguments["display"]?.intValue ?? 0
        let scale = min(max(arguments["scale"]?.doubleValue ?? 1.0, 0.1), 2.0)
        let format = arguments["format"]?.stringValue ?? "jpeg"
        let quality = min(max(arguments["quality"]?.doubleValue ?? 0.7, 0.1), 1.0)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ToolError("ScreenCaptureKit unavailable: \(error.localizedDescription). " +
                            "Grant Screen Recording to OpenAB Computer (oab-computer) in System Settings → Privacy & Security, then restart the agent.")
        }
        // Main display first so index 0 is predictable; shared with mouse and ui_snapshot.
        let ordered = DisplayOrder.sorted(content.displays, mainID: CGMainDisplayID()) { $0.displayID }
        guard index >= 0, index < ordered.count else {
            throw ToolError("display \(index) out of range; \(ordered.count) display(s) available")
        }
        let display = ordered[index]

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        var region = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        if let r = arguments["region"] {
            guard let x = r["x"]?.doubleValue, let y = r["y"]?.doubleValue,
                  let w = r["width"]?.doubleValue, let h = r["height"]?.doubleValue, w > 0, h > 0 else {
                throw JSONRPCError.invalidParams("region needs x, y, width>0, height>0")
            }
            region = CGRect(x: x, y: y, width: w, height: h).intersection(region)
            guard !region.isEmpty else { throw ToolError("region lies outside display \(index)") }
            cfg.sourceRect = region
        }
        // Output size is in pixels: scale = pixels per point.
        cfg.width = max(Int(region.width * scale), 1)
        cfg.height = max(Int(region.height * scale), 1)
        cfg.showsCursor = true
        cfg.captureResolution = .best

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw ToolError("capture failed: \(error.localizedDescription)")
        }

        let (data, mime) = try Self.encode(image, format: format, quality: quality)
        let structured: JSONValue = [
            "display": .number(Double(index)),
            "display_id": .number(Double(display.displayID)),
            "points": ["width": .number(Double(display.width)), "height": .number(Double(display.height))],
            "region": ["x": .number(region.origin.x), "y": .number(region.origin.y), "width": .number(region.width), "height": .number(region.height)],
            "image": ["width": .number(Double(image.width)), "height": .number(Double(image.height)), "bytes": .number(Double(data.count))],
            "scale": .number(scale),
        ]
        let crop = arguments["region"] != nil ? " region \(Int(region.origin.x)),\(Int(region.origin.y)) \(Int(region.width))×\(Int(region.height))pt" : ""
        let caption = "display \(index): \(display.width)×\(display.height) pt\(crop) → \(image.width)×\(image.height) px \(mime) (\(data.count / 1024) KiB), scale \(scale)"
        return ToolResult(content: [.image(data: data, mimeType: mime), .text(caption)], structured: structured)
    }

    static func encode(_ image: CGImage, format: String, quality: Double) throws -> (Data, String) {
        let type: UTType = format == "png" ? .png : .jpeg
        let mime = format == "png" ? "image/png" : "image/jpeg"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw ToolError("image encoder unavailable")
        }
        let props: [CFString: Any] = format == "png" ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("image encode failed") }
        return (out as Data, mime)
    }
}
