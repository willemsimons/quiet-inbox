import AppKit
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(red: 0.36, green: 0.52, blue: 0.75, alpha: 1), ending: NSColor(red: 0.06, green: 0.12, blue: 0.26, alpha: 1))!.draw(in: bounds, angle: -65)
let tray = NSBezierPath()
tray.move(to: NSPoint(x: 230, y: 540)); tray.line(to: NSPoint(x: 315, y: 700)); tray.line(to: NSPoint(x: 709, y: 700)); tray.line(to: NSPoint(x: 794, y: 540))
tray.line(to: NSPoint(x: 794, y: 350)); tray.curve(to: NSPoint(x: 744, y: 300), controlPoint1: NSPoint(x: 794, y: 315), controlPoint2: NSPoint(x: 779, y: 300))
tray.line(to: NSPoint(x: 280, y: 300)); tray.curve(to: NSPoint(x: 230, y: 350), controlPoint1: NSPoint(x: 245, y: 300), controlPoint2: NSPoint(x: 230, y: 315)); tray.close()
NSColor(white: 1, alpha: 0.12).setFill(); tray.fill()
NSColor(red: 0.85, green: 0.94, blue: 1, alpha: 1).setStroke(); tray.lineWidth = 25; tray.lineJoinStyle = .round; tray.stroke()
let lip = NSBezierPath()
lip.move(to: NSPoint(x: 235, y: 520)); lip.line(to: NSPoint(x: 395, y: 520)); lip.curve(to: NSPoint(x: 629, y: 520), controlPoint1: NSPoint(x: 400, y: 400), controlPoint2: NSPoint(x: 624, y: 400)); lip.line(to: NSPoint(x: 789, y: 520)); lip.lineWidth = 25; lip.lineCapStyle = .round; lip.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
