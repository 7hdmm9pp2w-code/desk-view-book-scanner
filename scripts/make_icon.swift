// Rendert das App-Icon mit CoreGraphics und baut daraus AppIcon.icns.
//   swift scripts/make_icon.swift build/AppIcon.icns
// Motiv: aufgeschlagenes Buch mit Textzeilen unter einem Sucher-Rahmen, auf
// tiefblauem Verlauf. Keine externen Werkzeuge außer iconutil.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.icns")

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle-Grundform wie macOS-Icons (Randabstand 10 %).
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0.10, green: 0.33, blue: 0.72, alpha: 1), CGColor(red: 0.04, green: 0.16, blue: 0.42, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Aufgeschlagenes Buch: zwei helle Seiten mit leichter Wölbung, dunkler Falz.
    let bookW = rect.width * 0.66, bookH = rect.height * 0.46
    let bx = rect.midX - bookW / 2, by = rect.midY - bookH / 2 - rect.height * 0.04
    let pageColor = CGColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
    func page(left: Bool) -> CGPath {
        let p = CGMutablePath()
        let x0 = left ? bx : rect.midX, x1 = left ? rect.midX : bx + bookW
        let outer = left ? x0 : x1, innerX = rect.midX
        let lift = bookH * 0.06
        p.move(to: CGPoint(x: innerX, y: by))
        p.addLine(to: CGPoint(x: outer, y: by + lift))
        p.addLine(to: CGPoint(x: outer, y: by + bookH + lift))
        p.addQuadCurve(to: CGPoint(x: innerX, y: by + bookH), control: CGPoint(x: (outer + innerX) / 2, y: by + bookH + bookH * 0.12))
        p.closeSubpath()
        return p
    }
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    for left in [true, false] {
        ctx.setFillColor(pageColor)
        ctx.addPath(page(left: left)); ctx.fillPath()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Falzschatten
    let spine = CGRect(x: rect.midX - s * 0.012, y: by, width: s * 0.024, height: bookH)
    let spineGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0), CGColor(red: 0, green: 0, blue: 0, alpha: 0.28), CGColor(red: 0, green: 0, blue: 0, alpha: 0.0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.saveGState(); ctx.clip(to: spine)
    ctx.drawLinearGradient(spineGradient, start: CGPoint(x: spine.minX, y: 0), end: CGPoint(x: spine.maxX, y: 0), options: [])
    ctx.restoreGState()
    // Textzeilen
    ctx.setFillColor(CGColor(red: 0.25, green: 0.30, blue: 0.40, alpha: 0.85))
    let lineH = bookH * 0.045
    for left in [true, false] {
        let x0 = (left ? bx : rect.midX) + bookW * 0.07
        let x1 = (left ? rect.midX : bx + bookW) - bookW * 0.07
        var y = by + bookH * 0.80
        var i = 0
        while y > by + bookH * 0.18 {
            let w = (x1 - x0) * (i % 4 == 3 ? 0.62 : 1.0)
            ctx.fill(CGRect(x: x0, y: y, width: w, height: lineH).insetBy(dx: 0, dy: 0))
            y -= lineH * 2.4; i += 1
        }
    }
    // Sucher-Ecken
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.setLineWidth(s * 0.028); ctx.setLineCap(.round)
    let f = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.14)
    let arm = f.width * 0.13
    for (cx, cy, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: cx, y: cy + dy * arm)); ctx.addLine(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
        ctx.strokePath()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(cgImage: render(size: px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try proc.run(); proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "Icon: \(output.path)" : "iconutil fehlgeschlagen")
