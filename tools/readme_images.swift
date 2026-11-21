// Draws docs/images/hero.png and popover.gif from the popover snapshots,
// each under a piece of menu bar with the icon for that state.
// Run it through tools/readme-images.sh, which adds the app's own
// MenuBarGlyph to this file so the icon is drawn by the menu bar's code.
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum PowerMark { case battery, plugged, charging }
enum MenuBarMark {
    case level(Int)
    var percent: Int? { if case .level(let value) = self { value } else { nil } }
    var isWarning: Bool { false }
}

struct Frame {
    var page: String
    var percent: Int
    var power: PowerMark
}

// Pixels. The snapshots are 640 wide; the crop leaves out the window's
// title bar and the strip below the popover.
let crop = CGRect(x: 0, y: 48, width: 640, height: 1270)
let barHeight: CGFloat = 72
let gap: CGFloat = 16
let corner: CGFloat = 28
let barScale: CGFloat = 3 // pixels per menu bar point: one and a half times life size, so the icon reads
let panel = CGSize(width: crop.width, height: barHeight + gap + crop.height)

func ink(_ dark: Bool) -> NSColor { dark ? NSColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1) : NSColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) }

func load(_ shots: String, _ page: String, dark: Bool) -> CGImage {
    let url = URL(fileURLWithPath: "\(shots)/\(page)-\(dark ? "dark" : "light").png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let cut = image.cropping(to: crop) else { fatalError("no snapshot at \(url.path); run tools/snap.sh first") }
    return cut
}

/// One popover under its piece of menu bar, drawn with its top left at `origin` (y up).
func drawPanel(_ frame: Frame, shots: String, dark: Bool, at origin: CGPoint) {
    let shot = load(shots, frame.page, dark: dark)
    let context = NSGraphicsContext.current!.cgContext
    let popover = CGRect(x: origin.x, y: origin.y, width: crop.width, height: crop.height)
    context.saveGState()
    context.addPath(CGPath(roundedRect: popover, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.clip()
    context.draw(shot, in: popover)
    context.restoreGState()

    // The bar takes the popover's own background.
    let rep = NSBitmapImageRep(cgImage: shot)
    let bar = NSRect(x: origin.x, y: popover.maxY + gap, width: crop.width, height: barHeight)
    (rep.colorAt(x: 320, y: 8) ?? .black).setFill()
    NSBezierPath(roundedRect: bar, xRadius: corner, yRadius: corner).fill()

    let text = NSAttributedString(string: "\(frame.percent)%", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13 * barScale, weight: .regular), .foregroundColor: ink(dark),
    ])
    let glyph = MenuBarGlyph.image(for: .level(frame.percent), power: frame.power)
    let glyphSize = NSSize(width: glyph.size.width * barScale, height: glyph.size.height * barScale)
    let tinted = NSImage(size: glyph.size, flipped: false) { rect in
        glyph.draw(in: rect)
        ink(dark).set()
        rect.fill(using: .sourceIn)
        return true
    }
    let textX = bar.maxX - 32 - text.size().width
    text.draw(at: NSPoint(x: textX, y: bar.midY - text.size().height / 2))
    tinted.draw(in: NSRect(x: textX - 4 * barScale - glyphSize.width, y: bar.midY - glyphSize.height / 2,
                           width: glyphSize.width, height: glyphSize.height))
}

func render(width: Int, height: Int, scale: CGFloat = 1, backdrop: NSColor? = nil, _ draw: () -> Void) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let backdrop {
        backdrop.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
    }
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.current!.flushGraphics()
    return rep.cgImage!
}

let shots = CommandLine.arguments[1]
let out = CommandLine.arguments[2]

// The hero: holding at the limit in dark, charging in light.
let between: CGFloat = 48
let hero = render(width: Int(panel.width * 2 + between), height: Int(panel.height)) {
    drawPanel(Frame(page: "popover", percent: 80, power: .plugged), shots: shots, dark: true, at: .zero)
    drawPanel(Frame(page: "popover-charging", percent: 46, power: .charging), shots: shots, dark: false,
              at: CGPoint(x: panel.width + between, y: 0))
}
let png = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/hero.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, hero, nil)
guard CGImageDestinationFinalize(png) else { fatalError("could not write hero.png") }

// The GIF: one frame per state, in dark, at three quarters size.
let frames = [
    Frame(page: "popover", percent: 80, power: .plugged),
    Frame(page: "popover-charging", percent: 46, power: .charging),
    Frame(page: "popover-topup", percent: 88, power: .charging),
    Frame(page: "popover-sailing", percent: 77, power: .plugged),
    Frame(page: "popover-heat", percent: 61, power: .plugged),
    Frame(page: "popover-low", percent: 70, power: .plugged),
    Frame(page: "popover-calibrating", percent: 62, power: .plugged),
]
let shrink: CGFloat = 0.75
let gif = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/popover.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for frame in frames {
    // A GIF has no soft edges, so the corners sit on a flat backdrop.
    let image = render(width: Int(panel.width * shrink), height: Int((panel.height * shrink).rounded(.up)), scale: shrink,
                       backdrop: NSColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1)) {
        drawPanel(frame, shots: shots, dark: true, at: .zero)
    }
    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.7]] as CFDictionary)
}
guard CGImageDestinationFinalize(gif) else { fatalError("could not write popover.gif") }
print("wrote \(out)/hero.png and \(out)/popover.gif")

