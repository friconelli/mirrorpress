// Disegna l'icona di Mirrorpress: due pagine speculari (locale blu, server vino) divise da un asse ambra con le frecce ⇄.
// Uso: swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext
    // Tessera arrotondata con margine trasparente (griglia icone macOS: 824/1024).
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [color(0.13, 0.11, 0.14), color(0.05, 0.05, 0.06)])!.draw(in: tilePath, angle: -90)

    let w = tile.width, x0 = tile.minX, y0 = tile.minY
    let cx = x0 + w / 2
    // Due pagine speculari: il sito in locale (blu) e la sua immagine sul server (vino).
    func page(_ minX: CGFloat, _ fill: NSColor, mirrored: Bool) {
        let pw = w * 0.30, ph = w * 0.50, py = y0 + w * 0.25
        let r = CGRect(x: minX, y: py, width: pw, height: ph)
        let body = NSBezierPath(roundedRect: r, xRadius: w * 0.04, yRadius: w * 0.04)
        NSGradient(colors: [fill.blended(withFraction: 0.22, of: .white)!, fill])!.draw(in: body, angle: -90)
        // Righe di contenuto: allineate verso l'asse, come in uno specchio.
        let widths: [CGFloat] = [0.70, 0.52, 0.62, 0.40]
        for (i, f) in widths.enumerated() {
            let lw = pw * f, lh = w * 0.030
            let ly = r.maxY - w * 0.10 - CGFloat(i) * w * 0.085
            let lx = mirrored ? r.minX + w * 0.04 : r.maxX - w * 0.04 - lw
            color(1, 1, 1, i == 0 ? 0.95 : 0.6).setFill()
            NSBezierPath(roundedRect: CGRect(x: lx, y: ly, width: lw, height: lh), xRadius: lh / 2, yRadius: lh / 2).fill()
        }
    }
    page(cx - w * 0.06 - w * 0.30, color(0.11, 0.50, 0.86), mirrored: false)
    page(cx + w * 0.06, color(0.55, 0.13, 0.30), mirrored: true)
    // Asse dello specchio, ambra e luminoso.
    ctx.setShadow(offset: .zero, blur: w * 0.05, color: color(0.96, 0.65, 0.20, 0.7).cgColor)
    color(0.96, 0.65, 0.20).setFill()
    NSBezierPath(roundedRect: CGRect(x: cx - w * 0.014, y: y0 + w * 0.16, width: w * 0.028, height: w * 0.68), xRadius: w * 0.014, yRadius: w * 0.014).fill()
    // Frecce ⇄ sull'asse.
    func arrow(_ y: CGFloat, right: Bool) {
        let a = NSBezierPath()
        let d: CGFloat = right ? 1 : -1, len = w * 0.07
        a.move(to: CGPoint(x: cx - d * len, y: y))
        a.line(to: CGPoint(x: cx + d * len, y: y))
        a.move(to: CGPoint(x: cx + d * len - d * w * 0.035, y: y + w * 0.035))
        a.line(to: CGPoint(x: cx + d * len, y: y))
        a.line(to: CGPoint(x: cx + d * len - d * w * 0.035, y: y - w * 0.035))
        a.lineWidth = w * 0.026; a.lineCapStyle = .round; a.lineJoinStyle = .round
        color(0.96, 0.65, 0.20).setStroke(); a.stroke()
    }
    arrow(y0 + w * 0.12, right: true)
    arrow(y0 + w * 0.88, right: false)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("Icone in \(out.path)")
