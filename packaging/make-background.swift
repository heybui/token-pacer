// Draws the disk image's backdrop: the dark panel the two icons sit on, and the
// arrow between them.
//
// `swift packaging/make-background.swift` writes `dmg-background.tiff` beside
// this file, one 1x rep and one 2x, which is what Finder needs to draw a
// background sharply on a Retina display and at all on anything else.
//
// A script rather than an exported asset because the geometry is shared with
// `packaging/layout.applescript`: the arrow points at coordinates the layout
// puts icons on, and the two files have to be edited together or not at all.
import AppKit

// The window is 640x440; Finder measures a background in points, so this is the
// 1x size and the 2x rep is drawn at twice the scale from the same code.
let size = CGSize(width: 640, height: 440)

/// Where the layout puts the two icons, in Finder's coordinates — origin top
/// left, and the position is the icon's *centre*.
let appIcon = CGPoint(x: 160, y: 200)
let folderIcon = CGPoint(x: 480, y: 200)

func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha
    )
}

/// Tokens' three, darkened a step for paper: the pill's green is drawn on
/// near-black and washes out on a light ground.
let green = hex(0x27A96F)
let amber = hex(0xD2951F)
let red = hex(0xCF4632)

func draw(into context: CGContext, scale: CGFloat) {
    context.scaleBy(x: scale, y: scale)
    // Finder's y grows downward and Core Graphics' grows upward. Flipping here
    // means every coordinate below can be read straight off the layout script.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)

    // Light, and not the app's own near-black: Finder draws the two icon names
    // in the system's label colour, which on a dark picture in light mode comes
    // out charcoal on charcoal and cannot be read at all.
    context.setFillColor(hex(0xF6F6F7).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0xFFFFFF).cgColor, hex(0xECECEE, alpha: 0).cgColor] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow, startCenter: CGPoint(x: 320, y: 210), startRadius: 0,
            endCenter: CGPoint(x: 320, y: 210), endRadius: 380, options: []
        )
    }

    arrow(in: context)
    caption(in: context)
}

/// The arrow: a shaft that fades in out of nothing, and a head that does not.
///
/// It runs between the two icons rather than under them — 128pt icons are 64pt
/// wide either side of their centre, so the gap is what is left.
func arrow(in context: CGContext) {
    let y = appIcon.y
    let start = appIcon.x + 86
    let end = folderIcon.x - 86
    let headLength: CGFloat = 26

    context.saveGState()
    // The shaft, drawn as a gradient-filled rectangle through a stroked path:
    // a plain stroke cannot fade along its own length.
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: start, y: y))
    shaft.addLine(to: CGPoint(x: end - headLength + 4, y: y))
    context.addPath(shaft)
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    if let fade = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            green.withAlphaComponent(0).cgColor,
            green.withAlphaComponent(0.7).cgColor,
            amber.withAlphaComponent(0.95).cgColor,
        ] as CFArray,
        locations: [0, 0.45, 1]
    ) {
        context.drawLinearGradient(
            fade, start: CGPoint(x: start, y: y), end: CGPoint(x: end, y: y), options: []
        )
    }
    context.restoreGState()

    // The head, solid: an arrow whose point is translucent reads as a smudge.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end, y: y))
    head.addLine(to: CGPoint(x: end - headLength, y: y + 15))
    head.addQuadCurve(
        to: CGPoint(x: end - headLength, y: y - 15), control: CGPoint(x: end - headLength + 9, y: y)
    )
    head.closeSubpath()
    context.addPath(head)
    context.setFillColor(amber.cgColor)
    context.fillPath()

    // Three dots trailing the shaft, the pill's own scale in miniature. They
    // are the one thing here that says which app this image belongs to.
    for (index, colour) in [green, amber, red].enumerated() {
        let dot = CGRect(
            x: start - 34 + CGFloat(index) * 11, y: y - 2.5, width: 5, height: 5
        )
        context.setFillColor(colour.withAlphaComponent(0.42 + Double(index) * 0.08).cgColor)
        context.fillEllipse(in: dot)
    }
}

/// One line under the arrow. The icons say what to drag; this says it is a drag.
func caption(in context: CGContext) {
    let text = "Drag Token Pacer into Applications"
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: hex(0x1C1C1E, alpha: 0.42),
        .paragraphStyle: style,
    ]
    let line = NSAttributedString(string: text, attributes: attributes)

    // `flipped: true` because the context already is: without it the glyphs
    // come out mirrored, which is a thing you only see once.
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    // Under the icons' labels: a 128pt icon reaches 64pt below its centre and
    // its name another 20 under that.
    line.draw(in: CGRect(x: 0, y: appIcon.y + 118, width: size.width, height: 22))
    NSGraphicsContext.restoreGraphicsState()
}

func image(scale: CGFloat) -> NSBitmapImageRep? {
    let pixels = CGSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }

    // The rep is tagged at its point size so `tiffutil -cathidpicheck` can tell
    // the 2x apart from the 1x; without it the two are just different pictures.
    rep.size = size
    draw(into: context, scale: scale)
    return rep
}

let here = URL(filePath: #filePath).deletingLastPathComponent()
for scale in [CGFloat(1), CGFloat(2)] {
    guard let rep = image(scale: scale),
          let png = rep.representation(using: .png, properties: [:])
    else { fatalError("could not render at \(scale)x") }
    let name = scale == 1 ? "dmg-background.png" : "dmg-background@2x.png"
    try png.write(to: here.appending(path: name))
    print("→ packaging/\(name)")
}
