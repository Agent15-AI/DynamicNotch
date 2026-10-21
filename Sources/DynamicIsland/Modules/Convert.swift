import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turning one file into another, and a link into a file.
///
/// Every job here runs only when pressed, on a background queue, and reports into
/// one short list the Convert section draws. Nothing is queued in the background,
/// nothing is watched, and the list is thrown away on quit - a conversion you
/// started and closed the island on has already finished or already failed.
///
/// The conversions themselves live where they belong: `Mobi` writes MOBI, `MP3`
/// encodes MP3, `YouTube` fetches. This is the part that runs them off the main
/// thread, keeps one line of state per job, and says what happened.
@MainActor
@Observable
final class Convert {
    static let shared = Convert()

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        /// 0...1 while running, nil when the work reports no progress.
        var progress: Double?
        var finished = false
        var failed = false
        /// Where the result landed, for the Reveal button.
        var result: URL?
    }

    private(set) var jobs: [Job] = []

    var working: Bool { jobs.contains { !$0.finished && !$0.failed } }

    private static let remembered = 5

    private init() {}

    // MARK: - What can be done to a file

    static func isEPUB(_ url: URL) -> Bool { url.pathExtension.lowercased() == "epub" }

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["zip", "cbz", "epub"].contains(url.pathExtension.lowercased())
            || name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tar.xz")
            || name.hasSuffix(".gz")
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }

    /// Anything with sound in it, which is what "save the audio as MP3" applies to.
    static func isMedia(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
            return false
        }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    // MARK: - Jobs

    func epubToMobi(_ url: URL) {
        // Unique like every other output here: a Book.mobi already beside the
        // EPUB - bought, or made by Calibre - was silently replaced.
        let target = Self.unique(url.deletingPathExtension().appendingPathExtension("mobi"))
        start(title: url.lastPathComponent, detail: "to MOBI", progress: nil) {
            try Mobi.convert(url, to: target)
        }
    }

    func toMP3(_ url: URL) {
        let target = Self.unique(url.deletingPathExtension().appendingPathExtension("mp3"))
        let id = begin(title: url.lastPathComponent, detail: "to MP3", progress: 0)
        perform(id) { [weak self] in
            try MP3.encode(url, to: target) { fraction in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(id, progress: fraction) }
                }
            }
            return target
        }
    }

    /// Unpacks an archive into a folder beside it.
    ///
    /// ponytail: `ditto` and `tar` are the system's own archivers and handle every
    /// format here, compression included. A zip reader written in Swift would be
    /// hundreds of lines to do the same job worse.
    func extract(_ url: URL) {
        let folder = Self.unique(url.deletingPathExtension(), directory: true)
        let name = url.lastPathComponent.lowercased()
        start(title: url.lastPathComponent, detail: "extracting", progress: nil) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ok: Bool
            if name.hasSuffix(".gz"), !name.hasSuffix(".tar.gz") {
                // A lone .gz is one compressed file, not an archive of many.
                ok = Self.run("/usr/bin/gzip", ["-dkc", url.path], writingTo:
                    folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent))
            } else if url.pathExtension.lowercased() == "zip"
                || url.pathExtension.lowercased() == "cbz"
                || url.pathExtension.lowercased() == "epub" {
                ok = Self.run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
            } else {
                ok = Self.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
            }
            guard ok else {
                try? FileManager.default.removeItem(at: folder)
                throw Failure.message("Could not unpack it")
            }
            return folder
        }
    }

    /// Several images into one PDF, a page each, in the order given.
    ///
    /// HEIC included - the format an iPhone actually takes photographs in, and
    /// the one that makes this worth having. `CIImage` reads it like anything
    /// else, and `.applyOrientationProperty` is what keeps a picture taken
    /// sideways from landing sideways: an iPhone stores the sensor's pixels and
    /// an orientation tag beside them, so a page built from the raw pixels is
    /// rotated a quarter turn in about half of all photographs.
    ///
    /// ponytail: a Core Graphics PDF context. PDFKit would want an `NSImage` per
    /// page and an `NSSize` guess for each; this draws the pixels it already has
    /// at their own size.
    func imagesToPDF(_ urls: [URL]) {
        let images = urls.filter(Self.isImage)
        guard !images.isEmpty else {
            HUD.shared.show(
                .utility(symbol: "doc.richtext", title: "No images", detail: "Pick pictures to combine"),
                for: 2.4
            )
            return
        }
        // Named after the first picture, beside it - the folder the pictures came
        // from is where the PDF is looked for.
        let target = Self.unique(
            images[0].deletingPathExtension().appendingPathExtension("pdf")
        )
        let id = begin(title: images.count == 1 ? images[0].lastPathComponent : "\(images.count) images",
                       detail: "to PDF", progress: 0)
        perform(id) { [weak self] in
            guard let consumer = CGDataConsumer(url: target as CFURL) else {
                throw Failure.message("Could not write there")
            }
            // Replaced per page; a PDF needs a box to start with.
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw Failure.message("Could not start a PDF")
            }
            let renderer = CIContext()
            var written = 0
            for (index, url) in images.enumerated() {
                guard let picture = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                      let page = renderer.createCGImage(picture, from: picture.extent)
                else { continue }
                // A pixel to a point. A phone photograph is then a big page, which
                // is what you want when the PDF is going to be read rather than
                // printed.
                var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(page.width), height: CGFloat(page.height))
                context.beginPage(mediaBox: &mediaBox)
                context.draw(page, in: mediaBox)
                context.endPage()
                written += 1
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.update(id, progress: Double(index + 1) / Double(images.count))
                    }
                }
            }
            context.closePDF()
            guard written > 0 else {
                try? FileManager.default.removeItem(at: target)
                throw Failure.message("None of those could be read as a picture")
            }
            return target
        }
    }

    func convertImage(_ url: URL, to type: UTType) {
        let target = Self.unique(
            url.deletingPathExtension()
                .appendingPathExtension(type.preferredFilenameExtension ?? "png")
        )
        start(title: url.lastPathComponent,
              detail: "to \(type.preferredFilenameExtension?.uppercased() ?? "image")",
              progress: nil) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw Failure.message("Could not read that image") }
            guard let destination = CGImageDestinationCreateWithURL(
                target as CFURL, type.identifier as CFString, 1, nil
            ) else { throw Failure.message("Cannot write \(type.identifier)") }
            // Quality is ignored by the lossless formats, so one setting covers all
            // three.
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: 0.9,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw Failure.message("Could not write the image")
            }
            return target
        }
    }

    func youtube(_ link: String, kind: YouTube.Kind) {
        let id = begin(title: "Downloading", detail: kind.label, progress: 0)
        perform(id) { [weak self] in
            try YouTube.download(link, kind: kind) { fraction in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(id, progress: fraction) }
                }
            }
        }
    }

    // MARK: - Running

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }

    /// One shape for every job: a row appears, the work runs off the main thread,
    /// the row ends as a result or as a reason.
    private func start(
        title: String, detail: String, progress: Double?,
        _ work: @escaping @Sendable () throws -> URL
    ) {
        let id = begin(title: title, detail: detail, progress: progress)
        perform(id, work)
    }

    private func begin(title: String, detail: String, progress: Double?) -> UUID {
        let job = Job(title: title, detail: detail, progress: progress)
        jobs.insert(job, at: 0)
        if jobs.count > Self.remembered { jobs.removeLast(jobs.count - Self.remembered) }
        return job.id
    }

    private func perform(_ id: UUID, _ work: @escaping @Sendable () throws -> URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Convert.shared.finish(id, outcome) }
            }
        }
    }

    private func update(_ id: UUID, progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = progress
    }

    private func finish(_ id: UUID, _ outcome: Result<URL, Error>) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let url):
            jobs[index].finished = true
            jobs[index].progress = 1
            jobs[index].result = url
            jobs[index].detail = url.deletingLastPathComponent().lastPathComponent
            HUD.shared.show(
                .utility(symbol: "arrow.triangle.2.circlepath", title: url.lastPathComponent,
                         detail: "Saved"),
                for: 2.6
            )
        case .failure(let error):
            jobs[index].failed = true
            jobs[index].progress = nil
            jobs[index].detail = error.localizedDescription
            // A conversion that failed silently is the shape of a dead button, and
            // these all take long enough that the island has usually closed.
            HUD.shared.show(
                .utility(symbol: "exclamationmark.triangle.fill", title: jobs[index].title,
                         detail: error.localizedDescription),
                for: 3.4
            )
        }
    }

    func clear() {
        jobs.removeAll { $0.finished || $0.failed }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Files

    /// Never overwrites. A second conversion lands beside the first rather than on
    /// top of it - these are cheap to redo and impossible to undo.
    private static func unique(_ url: URL, directory: Bool = false) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        let extension_ = url.pathExtension
        for suffix in 2 ... 99 {
            var candidate = folder.appendingPathComponent("\(base)-\(suffix)")
            if !directory, !extension_.isEmpty {
                candidate = candidate.appendingPathExtension(extension_)
            }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    @discardableResult
    private nonisolated static func run(
        _ path: String, _ arguments: [String], writingTo output: URL? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: output)
            else { return false }
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
