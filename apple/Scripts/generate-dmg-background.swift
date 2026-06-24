#!/usr/bin/env swift
// Generates the styled DMG background for Haven's drag-to-Applications installer window
// (parity with Blip / Enter Space Helper). Renders Haven's sunset-over-a-constellation brand at
// 660×400 — the window size the release CI sets — with the constellation mark, the wordmark, an
// install hint, scattered stars, and a glowing arrow from the app icon toward Applications.
//
//   swift generate-dmg-background.swift <output-dir>   →   <output-dir>/dmg-background.png

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660
let H: CGFloat = 400

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r, green: g, blue: b, alpha: a)
}

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let full = NSRect(x: 0, y: 0, width: W, height: H)

// 1. Sunset gradient — deep indigo at the base rising into warm magenta/coral.
NSGradient(colors: [
    rgb(0.07, 0.04, 0.15),
    rgb(0.20, 0.08, 0.30),
    rgb(0.42, 0.15, 0.38),
    rgb(0.62, 0.26, 0.34),
], atLocations: [0.0, 0.45, 0.80, 1.0], colorSpace: .deviceRGB)!
    .draw(in: NSBezierPath(rect: full), angle: 90)

// 2. Warm sunset bloom, upper centre.
NSGradient(colors: [
    rgb(1.0, 0.55, 0.45, 0.30),
    rgb(1.0, 0.40, 0.55, 0.12),
    rgb(1.0, 0.40, 0.55, 0.0),
])!.draw(in: NSBezierPath(ovalIn: NSRect(x: W*0.05, y: H*0.30, width: W*0.9, height: H*0.95)),
         relativeCenterPosition: NSPoint(x: 0, y: -0.1))

// 3. Scattered stars (deterministic), denser up top, sparse in the icon band.
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (40,360,1.4,0.8),(95,330,1.0,0.5),(150,375,1.6,0.7),(210,348,1.1,0.6),(300,378,1.3,0.55),
    (360,352,1.0,0.5),(430,372,1.7,0.75),(500,340,1.1,0.5),(560,368,1.4,0.7),(615,344,1.2,0.6),
    (70,300,1.0,0.4),(255,312,1.2,0.5),(405,300,1.0,0.45),(590,305,1.3,0.55),(140,288,0.9,0.4),
    (480,295,1.0,0.4),(30,250,1.1,0.4),(640,255,1.2,0.45),(330,268,0.9,0.35),
    (25,150,1.0,0.30),(635,140,1.1,0.32),(60,95,1.2,0.30),(600,90,1.0,0.28),(120,60,0.9,0.25),(545,55,1.0,0.25),
]
for (x, y, r, a) in stars {
    rgb(1, 0.96, 0.98, a).setFill()
    NSBezierPath(ovalIn: NSRect(x: x-r, y: y-r, width: r*2, height: r*2)).fill()
}

// 4. Constellation mark — Haven's signet (5 nodes + links), glowing, centred up top.
//    SVG units (top-down) mapped into image space (bottom-up), centred on (cx, cy).
func drawConstellation(cx: CGFloat, cy: CGFloat, scale: CGFloat, alpha: CGFloat, dotR: CGFloat, glow: Bool) {
    let s = scale / 14.0
    func P(_ sx: CGFloat, _ sy: CGFloat) -> NSPoint { NSPoint(x: cx + (sx-12)*s, y: cy - (sy-11.5)*s) }
    let nodes = [P(6,7), P(18,6), P(12,13), P(5,17), P(19,17)]
    let edges = [(P(6,7),P(12,13)), (P(12,13),P(18,6)), (P(12,13),P(5,17)), (P(12,13),P(19,17))]
    let line = NSBezierPath()
    for (a, b) in edges { line.move(to: a); line.line(to: b) }
    rgb(1, 0.85, 0.92, alpha*0.7).setStroke()
    line.lineWidth = max(1, scale/55)
    line.lineCapStyle = .round
    line.stroke()
    for n in nodes {
        if glow {
            rgb(1, 0.55, 0.70, alpha*0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: n.x-dotR*2.4, y: n.y-dotR*2.4, width: dotR*4.8, height: dotR*4.8)).fill()
        }
        rgb(1, 0.97, 0.99, alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: n.x-dotR, y: n.y-dotR, width: dotR*2, height: dotR*2)).fill()
    }
}
// Large faint watermark behind everything, then a crisp glowing mark above the wordmark.
drawConstellation(cx: W/2, cy: 210, scale: 360, alpha: 0.05, dotR: 5, glow: false)
drawConstellation(cx: W/2, cy: H-78, scale: 70, alpha: 1.0, dotR: 3, glow: true)

// 5. Wordmark + hint, both softly shadowed for legibility over the gradient.
let shadow = NSShadow(); shadow.shadowColor = rgb(0,0,0,0.5); shadow.shadowBlurRadius = 8; shadow.shadowOffset = .zero
func centered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .shadow: shadow]
    let s = text as NSString
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (W - sz.width)/2, y: y), withAttributes: attrs)
}
centered("Haven", font: .systemFont(ofSize: 30, weight: .bold), color: rgb(1, 0.98, 1.0), y: H-150)
centered("Drag Haven to Applications to install", font: .systemFont(ofSize: 13, weight: .medium), color: rgb(0.92, 0.86, 0.92), y: H-178)

// 6. Glowing arrow from the app toward Applications (icons sit at the window's mid-height).
let ay: CGFloat = 196
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 252, y: ay)); arrow.line(to: NSPoint(x: 410, y: ay))
arrow.move(to: NSPoint(x: 398, y: ay+10)); arrow.line(to: NSPoint(x: 412, y: ay)); arrow.line(to: NSPoint(x: 398, y: ay-10))
arrow.lineWidth = 2.4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
rgb(1.0, 0.55, 0.68, 0.35).setStroke(); arrow.lineWidth = 6; arrow.stroke() // glow
rgb(1.0, 0.80, 0.88, 0.95).setStroke(); arrow.lineWidth = 2.2; arrow.stroke() // core

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("⚠ Failed to render DMG background\n".utf8)); exit(1)
}
let out = URL(fileURLWithPath: outputDir).appendingPathComponent("dmg-background.png")
try png.write(to: out)
print("✓ Generated \(out.path)")
