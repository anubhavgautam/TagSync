// Renders Assets/quintessence.svg into a macOS-style 1024px app icon PNG.
// Usage: swift scripts/make-icon.swift Assets/quintessence.svg out.png
import AppKit

let args = CommandLine.arguments
guard let art = NSImage(contentsOfFile: args[1]) else { fatalError("cannot load \(args[1])") }
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle tile per Apple's icon grid: 824pt body inset 100pt, ~185pt corner radius.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// Subtle top-to-bottom sheen (site --bg-card → --bg-page).
NSGradient(starting: NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1),
           ending: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.937, alpha: 1))!.draw(in: path, angle: -90)

// Fit the silhouette inside the tile with padding.
let box = tile.insetBy(dx: 90, dy: 110)
let a = art.size
let scale = min(box.width / a.width, box.height / a.height)
let w = a.width * scale, h = a.height * scale
art.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2 - 10, width: w, height: h))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
