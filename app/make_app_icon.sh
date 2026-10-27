#!/bin/bash
set -e

PNG_FILE="antigravityusagebar-icon.png"

if [ ! -f "$PNG_FILE" ]; then
    echo "Generating icon PNG..."
    swift -e '
import AppKit

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// Rounded rect background gradient
let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
let bgPath = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
let grad = NSGradient(colors: [
    NSColor(red: 0.08, green: 0.10, blue: 0.20, alpha: 1.0),
    NSColor(red: 0.16, green: 0.22, blue: 0.45, alpha: 1.0)
])!
grad.draw(in: bgPath, angle: -45)

// Spark/Rocket star center
let star = NSBezierPath()
star.move(to: NSPoint(x: 512, y: 180))
star.line(to: NSPoint(x: 590, y: 434))
star.line(to: NSPoint(x: 844, y: 512))
star.line(to: NSPoint(x: 590, y: 590))
star.line(to: NSPoint(x: 512, y: 844))
star.line(to: NSPoint(x: 434, y: 590))
star.line(to: NSPoint(x: 180, y: 512))
star.line(to: NSPoint(x: 434, y: 434))
star.close()

let starGrad = NSGradient(colors: [
    NSColor(red: 0.25, green: 0.88, blue: 0.55, alpha: 1.0),
    NSColor(red: 0.30, green: 0.65, blue: 1.00, alpha: 1.0)
])!
starGrad.draw(in: star, angle: 45)

// Orbital dot
let dot = NSBezierPath(ovalIn: NSRect(x: 680, y: 680, width: 110, height: 110))
NSColor(red: 0.40, green: 0.85, blue: 1.0, alpha: 1.0).setFill()
dot.fill()

img.unlockFocus()

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try! png.write(to: URL(fileURLWithPath: "antigravityusagebar-icon.png"))
}
'
fi

mkdir -p AntigravityUsageBar.iconset

sips -z 16 16     "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_16x16.png >/dev/null
sips -z 32 32     "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_16x16@2x.png >/dev/null
sips -z 32 32     "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_32x32.png >/dev/null
sips -z 64 64     "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_32x32@2x.png >/dev/null
sips -z 128 128   "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_128x128.png >/dev/null
sips -z 256 256   "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_128x128@2x.png >/dev/null
sips -z 256 256   "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_256x256.png >/dev/null
sips -z 512 512   "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_256x256@2x.png >/dev/null
sips -z 512 512   "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_512x512.png >/dev/null
sips -z 1024 1024 "$PNG_FILE" --out AntigravityUsageBar.iconset/icon_512x512@2x.png >/dev/null

iconutil -c icns AntigravityUsageBar.iconset
rm -rf AntigravityUsageBar.iconset

echo "✅ App icon created: AntigravityUsageBar.icns"
