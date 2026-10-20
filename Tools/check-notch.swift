// Fails if the island paints anything under the physical notch.
//
// The bezel is a hole: pixels drawn there are in the framebuffer, so a
// screenshot shows them, but nobody can see them. That is how a header ended up
// hidden under the notch while every screenshot looked fine - `screencapture`
// captures what was rendered, not what is visible.
//
// Usage: swift Tools/check-notch.swift <captured-notch-rect.png>
// Exits non-zero when any pixel is brighter than the notch's own black.

import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("check-notch: could not read image")
    exit(2)
}

guard let data = cg.dataProvider?.data as Data? else {
    print("check-notch: no pixel data")
    exit(2)
}

let bytesPerPixel = cg.bitsPerPixel / 8
let bytesPerRow = cg.bytesPerRow
var brightest = 0
var offenders = 0

for y in 0 ..< cg.height {
    for x in 0 ..< cg.width {
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + 2 < data.count else { continue }
        // Ignore alpha; the panel paints true black behind the cutout, so any
        // real luminance is content that the user cannot see.
        let value = max(Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        brightest = max(brightest, value)
        if value > 24 { offenders += 1 }
    }
}

let total = cg.width * cg.height
print("check-notch: \(cg.width)x\(cg.height), brightest=\(brightest), lit pixels=\(offenders)/\(total)")

// A few stray pixels are antialiasing on the cutout's own corners. A band of
// them is text or a control sitting where it cannot be read.
if offenders > total / 100 {
    print("FAIL: content is rendered under the notch and is invisible to the user")
    exit(1)
}
print("OK: nothing renders under the notch")
