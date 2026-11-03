// Draws the app icon (a rising amber line over a prompt cursor, on black, in the terminal's own
// colours) into an .iconset folder for iconutil. Usage: make-icon <folder>.iconset
import AppKit

let amber = NSColor(srgbRed: 1, green: 160 / 255, blue: 40 / 255, alpha: 1)  // the page's --amber, #ffa028
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, pixels) in [
  ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
  ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
] {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let scale = CGFloat(pixels) / 1024
  // Apple's icon grid: an 824-point tile with rounded corners, centred on a 1024-point canvas.
  let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
  NSGradient(
    starting: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.17, alpha: 1),
    ending: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1))!.draw(in: shape, angle: -90)
  // Drawn on a 32-unit grid with y running down, like the page's own coordinates.
  let point = { (x: CGFloat, y: CGFloat) in NSPoint(x: tile.minX + x / 32 * tile.width, y: tile.maxY - y / 32 * tile.height) }
  let line = NSBezierPath()
  line.move(to: point(7, 19))
  let rest: [(CGFloat, CGFloat)] = [(13, 12), (18, 16), (25, 7)]
  rest.forEach { line.line(to: point($0.0, $0.1)) }
  line.lineWidth = 3 / 32 * tile.width
  line.lineCapStyle = .round
  line.lineJoinStyle = .round
  amber.setStroke()
  line.stroke()
  // The cursor sits under the line's start, rows 23 to 26.
  amber.setFill()
  NSBezierPath(rect: NSRect(origin: point(7, 26), size: NSSize(width: 6 / 32 * tile.width, height: 3 / 32 * tile.height))).fill()
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(name).png"))
}
