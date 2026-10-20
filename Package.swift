// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "DynamicIsland", dependencies: ["MenuBarShim", "Shine"], path: "Sources/DynamicIsland"),
        // macOS ships no MP3 encoder - AudioToolbox decodes MP3 and refuses to
        // write it, checked with `afconvert -f MPG3` ("fmt?"). shine is 2,800
        // lines of C with no dependencies, so "save as MP3" needs nothing
        // installed. LGPL v2; the source it was built from is right here.
        .target(name: "Shine", path: "Sources/Shine", exclude: ["COPYING"]),
        // Objective-C so exceptions from macOS 27's private menu bar API are
        // caught rather than fatal. See Sources/MenuBarShim/include.
        .target(name: "MenuBarShim", path: "Sources/MenuBarShim"),
        // Separate binary so Vision's model memory dies with the request.
        // See Sources/OCRHelper/main.swift.
        .executableTarget(name: "di-ocr", path: "Sources/OCRHelper"),
    ]
)
