import AppKit
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let outer = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.20, alpha: 1).setFill(); outer.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.35, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.06, blue: 0.13, alpha: 1))!.draw(in: outer, angle: -70)
let frame = NSBezierPath(roundedRect: NSRect(x: 226, y: 226, width: 572, height: 572), xRadius: 98, yRadius: 98)
frame.lineWidth = 18
NSColor(calibratedRed: 0.30, green: 0.43, blue: 0.62, alpha: 0.65).setStroke(); frame.stroke()
let pins = NSBezierPath(); pins.lineWidth = 18; pins.lineCapStyle = .round
for offset in [330.0, 420, 510, 600, 690] {
    pins.move(to: NSPoint(x: offset, y: 815)); pins.line(to: NSPoint(x: offset, y: 852))
    pins.move(to: NSPoint(x: offset, y: 172)); pins.line(to: NSPoint(x: offset, y: 209))
    pins.move(to: NSPoint(x: 172, y: offset)); pins.line(to: NSPoint(x: 209, y: offset))
    pins.move(to: NSPoint(x: 815, y: offset)); pins.line(to: NSPoint(x: 852, y: offset))
}
NSColor(calibratedRed: 0.40, green: 0.56, blue: 0.77, alpha: 0.7).setStroke(); pins.stroke()
func wave(_ points: [(Double, Double)], color: NSColor, width: Double) {
    let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    for (index, point) in points.enumerated() { if index == 0 { path.move(to: NSPoint(x: point.0, y: point.1)) } else { path.line(to: NSPoint(x: point.0, y: point.1)) } }
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = color.withAlphaComponent(0.45); glow.shadowBlurRadius = 18; glow.shadowOffset = .zero; glow.set()
    color.setStroke(); path.stroke(); NSGraphicsContext.restoreGraphicsState()
}
wave([(278,590),(350,590),(405,672),(464,535),(520,728),(581,562),(627,611),(746,611)], color: NSColor(calibratedRed: 0.25, green: 0.76, blue: 1, alpha: 1), width: 31)
wave([(278,439),(350,439),(420,477),(489,412),(559,483),(634,439),(746,439)], color: NSColor(calibratedRed: 0.73, green: 0.52, blue: 1, alpha: 1), width: 25)
wave([(278,332),(372,332),(435,357),(520,330),(605,370),(681,349),(746,349)], color: NSColor(calibratedRed: 0.27, green: 0.88, blue: 0.68, alpha: 1), width: 23)
NSGraphicsContext.restoreGraphicsState()
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
