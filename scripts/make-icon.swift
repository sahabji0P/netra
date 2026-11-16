// Draws Netra's app icon and writes PNGs.
//
//   /usr/bin/swift scripts/make-icon.swift <out-dir> [variant]
//
// With no variant it writes the shipped icon at every size an .icns needs,
// as <out-dir>/AppIcon.iconset, plus a 1024 px preview.
// `scripts/make-icon.sh` turns that into packaging/AppIcon.icns.
// The other variants exist to compare directions side by side.
//
// Netra is Sanskrit for eye, and the app is the little thing that keeps an
// eye on your coding agents, so every direction is a character with eyes
// rather than a chart.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fatalError("usage: make-icon.swift <out-dir> [variant]") }
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let shipped = "googly"
let variant = arguments.count > 2 ? arguments[2] : shipped

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

extension CGContext {
    func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
        setFillColor(color)
        fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    func oval(_ rect: CGRect, _ color: CGColor) {
        setFillColor(color)
        fillEllipse(in: rect)
    }

    func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        addPath(path)
        setStrokeColor(color)
        setLineWidth(width)
        setLineCap(.round)
        setLineJoin(.round)
        strokePath()
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path)
        setFillColor(color)
        fillPath()
    }

    func vertical(_ top: UInt32, _ bottom: UInt32, from: CGFloat, to: CGFloat) {
        let gradient = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
        drawLinearGradient(
            gradient, start: CGPoint(x: 512, y: from), end: CGPoint(x: 512, y: to),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// A googly eye: white, a pupil looking toward `look`, and a glint.
    func eye(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, look: CGPoint, pupil: UInt32 = 0x17171A) {
        disc(x, y, r, rgb(0xFFFFFF))
        let px = x + look.x * r * 0.34, py = y + look.y * r * 0.34
        disc(px, py, r * 0.54, rgb(pupil))
        disc(px + r * 0.2, py + r * 0.22, r * 0.17, rgb(0xFFFFFF))
    }

    /// Bits of confetti, the way a limit reset is celebrated.
    func confetti(_ pieces: [(CGFloat, CGFloat, CGFloat, UInt32)]) {
        for (x, y, turn, color) in pieces {
            saveGState()
            translateBy(x: x, y: y)
            rotate(by: turn)
            fill(CGPath(roundedRect: CGRect(x: -22, y: -9, width: 44, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil), rgb(color))
            restoreGState()
        }
    }
}

func arc(_ from: CGPoint, _ to: CGPoint, bend: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: from)
    path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + bend))
    return path
}

/// A small creature popping up from the bottom of the tile, one big eye on
/// whatever your agents are doing.
func peeker(_ c: CGContext) {
    c.vertical(0xFFD65A, 0xFFA82E, from: 924, to: 100)
    c.confetti([(250, 800, 0.5, 0xFF5A7A), (420, 850, -0.4, 0xFFFFFF), (650, 830, 0.9, 0x4C8DFF), (800, 760, -0.7, 0xFFFFFF), (200, 640, -0.9, 0x4C8DFF), (840, 600, 0.3, 0xFF5A7A)])
    // Antennae behind the body.
    c.stroke(arc(CGPoint(x: 430, y: 600), CGPoint(x: 360, y: 730), bend: 30), rgb(0x1E1E24), 26)
    c.stroke(arc(CGPoint(x: 594, y: 600), CGPoint(x: 664, y: 730), bend: 30), rgb(0x1E1E24), 26)
    c.disc(360, 738, 34, rgb(0xFF5A7A))
    c.disc(664, 738, 34, rgb(0xFF5A7A))
    // Body: a dome that runs off the bottom edge.
    c.oval(CGRect(x: 212, y: -150, width: 600, height: 800), rgb(0x1E1E24))
    c.oval(CGRect(x: 262, y: 420, width: 220, height: 150), rgb(0xFFFFFF, 0.06))
    c.eye(512, 410, 150, look: CGPoint(x: 0.5, y: 0.6))
    c.stroke(arc(CGPoint(x: 452, y: 205), CGPoint(x: 572, y: 205), bend: -46), rgb(0xFFFFFF), 20)
    c.disc(330, 250, 34, rgb(0xFF5A7A, 0.75))
    c.disc(694, 250, 34, rgb(0xFF5A7A, 0.75))
}

/// One big googly eye with a raised brow.
func googly(_ c: CGContext) {
    c.vertical(0xFF5F52, 0xD61F3C, from: 924, to: 100)
    c.disc(512, 470, 268, rgb(0x000000, 0.18))
    c.eye(512, 490, 260, look: CGPoint(x: 0.55, y: -0.5))
    c.stroke(arc(CGPoint(x: 300, y: 790), CGPoint(x: 600, y: 850), bend: 50), rgb(0xFFFFFF), 40)
}

/// A night owl that never sleeps on the job: one eye open, one winking.
func owl(_ c: CGContext) {
    c.vertical(0x27357A, 0x0E1330, from: 924, to: 100)
    for (x, y, r) in [(210, 820, 9), (330, 870, 6), (760, 850, 10), (850, 720, 6), (170, 600, 7), (880, 520, 8)] as [(CGFloat, CGFloat, CGFloat)] {
        c.disc(x, y, r, rgb(0xFFFFFF, 0.8))
    }
    let body: UInt32 = 0xF2A24B
    // Ear tufts, then the head running off the bottom edge.
    for flip in [CGFloat(-1), 1] {
        let tuft = CGMutablePath()
        tuft.move(to: CGPoint(x: 512 + flip * 290, y: 790))
        tuft.addLine(to: CGPoint(x: 512 + flip * 120, y: 640))
        tuft.addLine(to: CGPoint(x: 512 + flip * 300, y: 560))
        tuft.closeSubpath()
        c.fill(tuft, rgb(body))
        c.stroke(tuft, rgb(body), 40)
    }
    c.oval(CGRect(x: 182, y: -60, width: 660, height: 760), rgb(body))
    c.oval(CGRect(x: 322, y: -120, width: 380, height: 420), rgb(0xFFE3B0))
    c.disc(382, 470, 136, rgb(0xFFE3B0))
    c.disc(642, 470, 136, rgb(0xFFE3B0))
    c.eye(382, 470, 108, look: CGPoint(x: 0.4, y: 0.3))
    c.stroke(arc(CGPoint(x: 566, y: 480), CGPoint(x: 718, y: 480), bend: -70), rgb(0x3A2A1A), 26)
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: 470, y: 400))
    beak.addLine(to: CGPoint(x: 554, y: 400))
    beak.addLine(to: CGPoint(x: 512, y: 318))
    beak.closeSubpath()
    c.fill(beak, rgb(0xFF7A3D))
    c.stroke(beak, rgb(0xFF7A3D), 18)
}

/// The notch island as a creature: a black pill hanging from the top with
/// two eyes looking down at your work.
func island(_ c: CGContext) {
    c.vertical(0xFF8A5B, 0xF0437A, from: 924, to: 100)
    c.confetti([(240, 330, 0.5, 0xFFFFFF), (400, 250, -0.5, 0xFFE27A), (640, 240, 0.8, 0xFFFFFF), (790, 340, -0.3, 0xFFE27A), (512, 380, 1.3, 0xFFFFFF)])
    c.fill(CGPath(roundedRect: CGRect(x: 212, y: 520, width: 600, height: 560), cornerWidth: 150, cornerHeight: 150, transform: nil), rgb(0x141417))
    c.eye(400, 690, 98, look: CGPoint(x: 0.2, y: -0.7), pupil: 0x141417)
    c.eye(624, 690, 98, look: CGPoint(x: 0.2, y: -0.7), pupil: 0x141417)
    c.stroke(arc(CGPoint(x: 462, y: 572), CGPoint(x: 562, y: 572), bend: -34), rgb(0xFFFFFF), 18)
}

let variants: [String: (CGContext) -> Void] = ["peeker": peeker, "googly": googly, "owl": owl, "island": island]
guard let draw = variants[variant] else { fatalError("unknown variant \(variant)") }

/// Draws the icon on a 1024-unit canvas scaled to `pixels`.
func render(pixels: Int) -> Data {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high

    // Apple's icon grid: an 824 pt tile centered on a 1024 pt canvas, with
    // room below for its shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
    context.fill(shape, rgb(0x202020))
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    draw(context)
    context.restoreGState()

    // A thin highlight along the tile's edge.
    context.stroke(
        CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil),
        rgb(0xFFFFFF, 0.16), 6
    )

    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
if arguments.count > 2 {
    try render(pixels: 1024).write(to: outDir.appendingPathComponent("icon-\(variant).png"))
} else {
    let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
    try render(pixels: 1024).write(to: outDir.appendingPathComponent("netra-app-icon-1024.png"))
}
