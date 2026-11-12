// Draws the ExoKey app icon (the site logo: an amber key with "Ex") and writes Resources/AppIcon.icns.
// swift tools/icon/make_icon.swift
import AppKit

func png(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024
    // macOS grid: 824 pt body, 100 pt margin
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let bg = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
    NSGradient(starting: NSColor(red: 1, green: 0.78, blue: 0.38, alpha: 1),
               ending: NSColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1))!.draw(in: bg, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // inner key cap
    let cap = NSRect(x: 200 * k, y: 250 * k, width: 624 * k, height: 560 * k)
    NSColor(red: 0.1, green: 0.075, blue: 0.024, alpha: 0.16).setFill()
    NSBezierPath(roundedRect: cap, xRadius: 110 * k, yRadius: 110 * k).fill()
    let font = NSFont.systemFont(ofSize: 330 * k, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font,
        .foregroundColor: NSColor(red: 0.1, green: 0.075, blue: 0.024, alpha: 1)]
    let t = NSAttributedString(string: "Ex", attributes: attrs)
    let ts = t.size()
    t.draw(at: NSPoint(x: cap.midX - ts.width / 2, y: cap.midY - ts.height / 2 + 6 * k))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! png(b).write(to: set.appendingPathComponent("icon_\(b)x\(b).png"))
    try! png(b * 2).write(to: set.appendingPathComponent("icon_\(b)x\(b)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
