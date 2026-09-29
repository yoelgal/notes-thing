// Cuts the generated icon art (scripts/icon-art.png) out of its white background into a macOS
// squircle, then writes app/AppIcon.icns, site/assets/icon.png and site/assets/favicon.png.
// swift scripts/icon.swift
import AppKit

let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "scripts/icon-art.png")))!
let (w, h) = (src.pixelsWide, src.pixelsHigh)

// Bounding box of the tile = everything clearly darker than the white background.
var (minX, minY, maxX, maxY) = (w, h, 0, 0)
for y in stride(from: 0, to: h, by: 2) {
  for x in stride(from: 0, to: w, by: 2) {
    let c = src.colorAt(x: x, y: y)!
    if c.redComponent + c.greenComponent + c.blueComponent < 1.2 {
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
  }
}
let inset = 4 // trim so no background fringe survives the mask
let tile = src.cgImage!.cropping(to: CGRect(x: minX + inset, y: minY + inset,
                                             width: maxX - minX - 2 * inset, height: maxY - minY - 2 * inset))!

func png(_ size: Int, pad: Double = 100.0 / 1024) -> Data {
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let p = Double(size) * pad, box = Double(size) - 2 * p
  let rect = CGRect(x: p, y: p, width: box, height: box)
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: box * 0.225, cornerHeight: box * 0.225, transform: nil))
  ctx.clip()
  ctx.interpolationQuality = .high
  ctx.draw(tile, in: rect)
  return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
  try! png(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
  try! png(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "app/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! png(512).write(to: URL(fileURLWithPath: "site/assets/icon.png"))
try! png(64, pad: 0).write(to: URL(fileURLWithPath: "site/assets/favicon.png"))
print("tile", minX, minY, maxX, maxY, "→ app/AppIcon.icns, site/assets/icon.png, site/assets/favicon.png")
