// icongen.swift — turns square app-icon art into a macOS-native 1024 master.
//
// Usage: swift icongen.swift <input.png> <output-1024.png>
//
// Two paths, auto-detected:
//  1. Art with a solid background ring (e.g. white margin around a rounded
//     shape): crop to the artwork's bounding box and lay it on the macOS
//     icon grid — 824×824 plate centered on a transparent 1024 canvas. The
//     artwork's own rounded shape becomes the icon; corners stay transparent.
//  2. Full-bleed art (no detectable background ring): mask the whole canvas
//     to the macOS rounded-rect radius (~22.37%) so corners are transparent.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("icongen: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: icongen <input.png> <output.png>") }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fail("cannot read \(inURL.path)")
}

// --- pixel access for background detection ---
let w = img.width, h = img.height
guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
    fail("cannot access pixels")
}
let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
let alphaIdx = img.alphaInfo.rawValue  // only used to decide how to read

func isBackground(_ x: Int, _ y: Int) -> Bool {
    let off = y * bpr + x * bpp
    guard off + 2 < CFDataGetLength(data) else { return true }
    let r = Double(ptr[off]), g = Double(ptr[off + 1]), b = Double(ptr[off + 2])
    let a = bpp >= 4 ? Double(ptr[off + 3]) : 255
    return a < 16 || (r > 243 && g > 243 && b > 243 && a > 243)
}

// Sample the four corners; if all match the background, detect the artwork box.
var cornersAreBackground = true
for (x, y) in [(4, 4), (w - 5, 4), (4, h - 5), (w - 5, h - 5)] {
    if !isBackground(x, y) { cornersAreBackground = false; break }
}

var artRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
if cornersAreBackground {
    var minX = w, minY = h, maxX = 0, maxY = 0
    let step = 2 // sample every other pixel; 1254² is plenty of resolution
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if !isBackground(x, y) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            x += step
        }
        y += step
    }
    // Ignore a detection that still covers ~everything → treat as full-bleed.
    let coverage = Double((maxX - minX) * (maxY - minY)) / Double(w * h)
    if maxX > minX, maxY > minY, coverage < 0.985 {
        // CG pixel coords are top-down for PNG decode via dataProvider;
        // CGImage.cropping expects top-down too, so no flip needed.
        artRect = CGRect(x: CGFloat(minX), y: CGFloat(minY),
                         width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
}

let fullBleed = artRect.width == CGFloat(w) && artRect.height == CGFloat(h)

// --- compose the 1024 master ---
let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

if fullBleed {
    // Rounded-rect mask at the macOS icon radius.
    let radius = S * 0.2237
    ctx.saveGState()
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    // ctx.draw maps a CGImage's top-down rows into context space upright —
    // no manual flip (one made every generated icon upside-down).
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()
} else {
    // Artwork plate on the macOS grid: 824×824 centered, transparent around.
    guard let cropped = img.cropping(to: artRect) else { fail("crop failed") }
    let plate: CGFloat = 824
    let side = max(cropped.width, cropped.height)
    let drawW = plate * CGFloat(cropped.width) / CGFloat(side)
    let drawH = plate * CGFloat(cropped.height) / CGFloat(side)
    let drawRect = CGRect(x: (S - drawW) / 2, y: (S - drawH) / 2, width: drawW, height: drawH)
    ctx.saveGState()
    ctx.draw(cropped, in: drawRect)
    ctx.restoreGState()
}

guard let out = ctx.makeImage() else { fail("render failed") }
let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fail("write failed") }

print("icongen: \(fullBleed ? "full-bleed → rounded mask" : "plate \(Int(artRect.width))×\(Int(artRect.height)) → 824 grid") wrote \(outURL.lastPathComponent)")
