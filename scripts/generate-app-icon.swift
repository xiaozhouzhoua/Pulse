#!/usr/bin/env swift
// Renders the Tick app icon into every PNG the AppIcon.appiconset ships.
//
// The dark squircle (geometry, alpha mask) is lifted from the previous Pulse
// icon so the shape stays on Apple's icon grid, filled with the vertical
// gradient keeps its depth. On top sits a rising three-candle stack — the
// app's chart motif — stepping up in brightness with the newest candle in
// pure white: monochrome, but each tick reads brighter than the last.
//
// Candle geometry is authored directly in visual coordinates; no font metrics
// are involved.
//
// Run from the repo root after adjusting the drawing below:
//   swift scripts/generate-app-icon.swift

import AppKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let appiconset = repoRoot.appendingPathComponent(
    "PulseMac/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

let master = 1024
/// The donor icon: same squircle mask and background the icon has always had.
let donorURL = appiconset.appendingPathComponent("icon_1024x1024.png")

// Brand colors. The squircle is a near-black vertical gradient (top darker);
// candles step up in brightness — mid gray, light gray, white — so the rising
// stack reads as "each tick brighter than the last" in a pure monochrome icon.
let navy = NSColor(srgbRed: 0x08 / 255.0, green: 0x09 / 255.0, blue: 0x0A / 255.0, alpha: 1)
let bottomNavy = NSColor(srgbRed: 0x15 / 255.0, green: 0x17 / 255.0, blue: 0x1A / 255.0, alpha: 1)
let midGray = NSColor(srgbRed: 0x7A / 255.0, green: 0x80 / 255.0, blue: 0x88 / 255.0, alpha: 1)
let lightGray = NSColor(srgbRed: 0xB0 / 255.0, green: 0xB6 / 255.0, blue: 0xBE / 255.0, alpha: 1)
let inkWhite = NSColor(srgbRed: 0xF1 / 255.0, green: 0xF3 / 255.0, blue: 0xF6 / 255.0, alpha: 1)

/// Candle bodies and wicks, authored in visual top-left coordinates on the
/// 1024 canvas. Bodies are centered on `x`; wicks run the full high–low range.
struct Candle {
    let x: CGFloat
    let wickTop: CGFloat
    let wickBottom: CGFloat
    let bodyTop: CGFloat
    let bodyBottom: CGFloat
    let color: NSColor
}

let bodyWidth: CGFloat = 150
let bodyCorner: CGFloat = 22
let wickWidth: CGFloat = 36
let candles = [
    Candle(x: 300, wickTop: 460, wickBottom: 700, bodyTop: 496, bodyBottom: 656, color: midGray),
    Candle(x: 512, wickTop: 370, wickBottom: 634, bodyTop: 406, bodyBottom: 590, color: lightGray),
    Candle(x: 724, wickTop: 272, wickBottom: 560, bodyTop: 308, bodyBottom: 516, color: inkWhite),
]

// MARK: - Background

/// The donor's alpha mask filled with the sampled vertical gradient.
func makeBackground(from donor: CGImage) -> CGImage {
    let context = CGContext(
        data: nil, width: master, height: master, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Raw CGContext is y-up: the gradient's first color goes at device top.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [navy.cgColor, bottomNavy.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(master)),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    // Keep the gradient only where the donor is opaque: destination-in
    // multiplies by the donor's alpha without bringing its colors along.
    context.setBlendMode(.destinationIn)
    context.draw(donor, in: CGRect(x: 0, y: 0, width: master, height: master))
    return context.makeImage()!
}

// MARK: - Render

guard let donorSource = CGImageSourceCreateWithURL(donorURL as CFURL, nil),
      let donorImage = CGImageSourceCreateImageAtIndex(donorSource, 0, nil) else {
    fputs("failed to load \(donorURL.path)\n", stderr)
    exit(1)
}
let context = CGContext(
    data: nil, width: master, height: master, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.interpolationQuality = .high
context.draw(makeBackground(from: donorImage), in: CGRect(x: 0, y: 0, width: master, height: master))

// A raw CGContext is y-up; authoring coordinates are visual top-left.
func flipY(_ y: CGFloat) -> CGFloat { CGFloat(master) - y }

for candle in candles {
    context.setStrokeColor(candle.color.cgColor)
    context.setLineWidth(wickWidth)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: candle.x, y: flipY(candle.wickTop)))
    context.addLine(to: CGPoint(x: candle.x, y: flipY(candle.wickBottom)))
    context.strokePath()
    context.setFillColor(candle.color.cgColor)
    let body = CGRect(
        x: candle.x - bodyWidth / 2,
        y: flipY(candle.bodyBottom),
        width: bodyWidth,
        height: candle.bodyBottom - candle.bodyTop
    )
    context.addPath(CGPath(roundedRect: body, cornerWidth: bodyCorner, cornerHeight: bodyCorner, transform: nil))
    context.fillPath()
}

let masterImage = context.makeImage()!

func writePNG(_ image: CGImage, pixels: Int, name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode \(name)\n", stderr)
        exit(1)
    }
    let url = appiconset.appendingPathComponent(name)
    try data.write(to: url)
    fputs("wrote \(url.path) (\(pixels)×\(pixels))\n", stderr)
}

try writePNG(masterImage, pixels: 1024, name: "icon_1024x1024.png")
for pixels in [512, 256, 128, 64, 32, 16] {
    try writePNG(masterImage, pixels: pixels, name: "icon_\(pixels)x\(pixels).png")
}
