import AppKit

// Draws the picture behind the Mac download's window: one long pill holding Nollie and Applications,
// three chevrons between them, and "Drag to install" underneath.
// Usage: dmg-background <out.png> <scale>. The picture is 660 by 420 points.
let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = CGSize(width: 660, height: 420)

guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
// Top-left origin, in points.
ctx.translateBy(x: 0, y: size.height * scale)
ctx.scaleBy(x: scale, y: -scale)

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: white, green: white, blue: white, alpha: alpha) }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// A light page with the faintest sky at the foot.
let page = CGGradient(colorsSpace: space, colors: [rgb(0.975, 0.977, 0.985), rgb(0.925, 0.945, 0.972)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(page, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

// The pill, as clear glass: a soft shadow under it, a milky fill, a bright rim and a highlight along the top.
let pill = CGRect(x: 70, y: 98, width: 520, height: 176)
let track = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: rgb(0.20, 0.32, 0.50, 0.14))
ctx.addPath(track)
ctx.setFillColor(gray(1, 0.72))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(track)
ctx.clip()
let sheen = CGGradient(colorsSpace: space, colors: [gray(1, 0.95), gray(1, 0.35), rgb(0.86, 0.91, 0.97, 0.45)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: pill.minY), end: CGPoint(x: 0, y: pill.maxY), options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
ctx.setStrokeColor(gray(1, 0.95))
ctx.setLineWidth(1.5)
ctx.strokePath()
ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: -0.5, dy: -0.5), cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
ctx.setStrokeColor(rgb(0.30, 0.40, 0.55, 0.10))
ctx.setLineWidth(1)
ctx.strokePath()

// Three chevrons, each a little brighter, the last in Nollie's blue.
let colors = [gray(0, 0.14), gray(0, 0.26), rgb(0.29, 0.60, 0.90)]
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (index, color) in colors.enumerated() {
    let x = 304 + CGFloat(index) * 22, y: CGFloat = 172
    ctx.setStrokeColor(color)
    ctx.move(to: CGPoint(x: x, y: y - 9))
    ctx.addLine(to: CGPoint(x: x + 8, y: y))
    ctx.addLine(to: CGPoint(x: x, y: y + 9))
    ctx.strokePath()
}

let text = NSAttributedString(string: "Drag to install", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(white: 0, alpha: 0.5),
])
let line = CTLineCreateWithAttributedString(text)
let width = CTLineGetTypographicBounds(line, nil, nil, nil)
ctx.saveGState()
ctx.translateBy(x: (size.width - CGFloat(width)) / 2, y: 338)
ctx.scaleBy(x: 1, y: -1)
ctx.textPosition = .zero
CTLineDraw(line, ctx)
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(2) }
try data.write(to: URL(fileURLWithPath: out))
