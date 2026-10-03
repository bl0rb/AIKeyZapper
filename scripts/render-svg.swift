// Renders an SVG to a PNG: centred tile of <tile> px on a transparent <canvas> px square (macOS icon grid).
// Usage: swift scripts/render-svg.swift in.svg out.png [canvas=1024] [tile=824]
import AppKit

let args = CommandLine.arguments
let canvas = args.count > 3 ? Int(args[3])! : 1024, tile = args.count > 4 ? Int(args[4])! : 824
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("cannot load \(args[1])") }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let inset = CGFloat(canvas - tile) / 2
image.draw(in: NSRect(x: inset, y: inset, width: CGFloat(tile), height: CGFloat(tile)))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
