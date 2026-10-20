// Reads text out of an image and exits.
//
// A separate executable on purpose. Vision caches its recognition model in the
// process that uses it and never gives the memory back: measured on this Mac,
// one pass took a process from 290 MB to 389 MB and a second pass added more.
// The island sits at about 19 MB, so doing this in-process would quadruple its
// resident size permanently for a feature used occasionally.
//
// As a child process the cost is real but temporary - it dies with the request
// and the memory goes back to the OS. Same shape as the Now Playing helper.
//
// Usage: di-ocr <image-path>
// Prints recognised text to stdout, one line per observation. Exit 1 on failure.

import AppKit
import Vision

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: di-ocr <image-path>\n".utf8))
    exit(2)
}

guard let image = NSImage(contentsOfFile: arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("di-ocr: could not read image\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
// Accurate over fast: this runs once on a region the user deliberately picked,
// so a third of a second buys correctness worth having.
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

// Barcodes in the same pass - a QR code in a screenshot is the other thing
// people select a region to read.
let barcodes = VNDetectBarcodesRequest()

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try? handler.perform([request, barcodes])

var lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let payloads = (barcodes.results ?? []).compactMap { $0.payloadStringValue }
// Barcode payloads first: if one is present it is almost certainly the point.
lines = payloads + lines

guard !lines.isEmpty else { exit(1) }
print(lines.joined(separator: "\n"))
