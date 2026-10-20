import AVFoundation
import Foundation

/// Saving a video, or its audio, as a file.
///
/// The extraction is `yt-dlp`'s job, not ours, and that is a deliberate call. A
/// native extractor was written and thrown away: the player page hands out
/// `signatureCipher` for every format, the decipher function lives in a 2.6 MB
/// `base.js` that no longer matches any of the published patterns, and the
/// Innertube clients that used to return plain URLs now answer `UNPLAYABLE`
/// without a token from the page. Measured on 2026-09-27, not assumed. Anything
/// written here would break the next time YouTube shipped, which for a feature
/// inside a notch app means it would simply be broken.
///
/// Everything after extraction *is* ours: no `ffmpeg`, no post-processors. A
/// progressive MP4 needs no muxing, and MP3 goes through the vendored encoder in
/// `MP3`. So the whole dependency is one binary.
///
/// It looks for that binary in the app bundle first, then where Homebrew puts it.
/// Drop a copy at `Vendor/yt-dlp` and `make.sh` puts it inside the .app, which is
/// what makes the app work on a Mac that has nothing installed.
enum YouTube {
    enum Kind {
        /// H.264 video up to 1080p with its audio, joined here.
        ///
        /// YouTube has stopped serving a progressive stream for most videos -
        /// checked against a video whose entire format list is video-only and
        /// audio-only - so the two halves come down as separate files. Joining them
        /// is normally ffmpeg's job; `mux` does it with AVFoundation instead, which
        /// is already on every Mac.
        case video
        /// The audio stream as it comes, which is already an m4a.
        case audio
        /// The same audio, re-encoded to MP3 by `MP3`.
        case mp3

        /// A comma means "fetch each of these as its own file" - the one selector
        /// shape that does not ask yt-dlp to merge, and so does not need ffmpeg.
        var format: String {
            switch self {
            case .video:
                "bv*[ext=mp4][vcodec^=avc1][height<=1080][protocol^=https]"
                    + "/bv*[ext=mp4][height<=1080][protocol^=https],"
                    + "ba[ext=m4a][protocol^=https]/ba[protocol^=https]"
            case .audio, .mp3: "ba[ext=m4a][protocol^=https]/ba/b"
            }
        }

        var label: String {
            switch self {
            case .video: "MP4"
            case .audio: "M4A"
            case .mp3: "MP3"
            }
        }
    }

    enum Failure: LocalizedError {
        case missingTool
        case badLink
        case failed(String)
        case noFile

        var errorDescription: String? {
            switch self {
            case .missingTool: "yt-dlp is not installed"
            case .badLink: "That is not a web link"
            case .failed(let line): line
            case .noFile: "Nothing was downloaded"
            }
        }
    }

    /// Where the downloader is, if it is anywhere.
    ///
    /// The bundled copy wins: an app someone was handed must not depend on what
    /// they happen to have installed.
    static var tool: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("yt-dlp"))
        }
        candidates += [
            "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp",
        ].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var available: Bool { tool != nil }

    /// Downloads into the Downloads folder and returns the file.
    ///
    /// Call this off the main thread: it waits for a subprocess. `progress` is
    /// called with 0...1 while the download runs, and again while an MP3 is being
    /// encoded.
    static func download(
        _ link: String, kind: Kind, progress: @escaping (Double) -> Void
    ) throws -> URL {
        guard let tool else { throw Failure.missingTool }
        // Only ever a web link, and never something that could be read as a flag.
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url
        else { throw Failure.badLink }

        // Its own folder, so the finished file is whatever is in there - no
        // guessing at the name yt-dlp chose, and no parsing its output for it.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "--no-playlist",
            "--no-part",
            "--newline",
            "--restrict-filenames",
            "-f", kind.format,
            // 150 bytes of title keeps the name recognisable and inside the
            // filesystem's limit.
            "-o", workspace.appendingPathComponent("%(title).150B.%(ext)s").path,
            "--", url.absoluteString,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        // Read as it goes: the progress lines are the only way to know how far in
        // this is, and a full pipe would block the download.
        var trailing = ""
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let text = String(decoding: chunk, as: UTF8.self)
            trailing = String((trailing + text).suffix(2000))
            for line in text.split(whereSeparator: \.isNewline) {
                guard let percent = percentage(in: String(line)) else { continue }
                // The MP3 path spends the second half of the bar encoding.
                progress(kind == .mp3 ? percent * 0.7 : percent)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.failed(Self.reason(in: trailing))
        }

        let produced = ((try? FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil
        )) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard var downloaded = produced.first else { throw Failure.noFile }
        // What it should be called once it lands, which stops being the temporary
        // file's own name as soon as two halves are joined into a third file.
        var name = downloaded.lastPathComponent

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        // Two files means the picture and the sound arrived separately.
        if kind == .video, produced.count > 1,
           let video = produced.first(where: { $0.pathExtension.lowercased() == "mp4" }),
           let audio = produced.first(where: { $0.pathExtension.lowercased() != "mp4" }) {
            // Both halves are written under the same name with different
            // extensions, so either one carries the title.
            name = video.deletingPathExtension().lastPathComponent + ".mp4"
            // A name of its own inside the workspace: an export will not write
            // over a file that already exists, and the video half is already
            // sitting at the obvious one.
            let joined = workspace.appendingPathComponent("joined.mp4")
            try join(video: video, audio: audio, to: joined)
            downloaded = joined
        }

        if kind == .mp3 {
            let target = unique(
                downloads.appendingPathComponent((name as NSString).deletingPathExtension)
                    .appendingPathExtension("mp3")
            )
            try MP3.encode(downloaded, to: target) { progress(0.7 + $0 * 0.3) }
            return target
        }

        let target = unique(downloads.appendingPathComponent(name))
        // Moved across filesystems - the temporary folder is not always on the
        // same volume as the home folder, and `moveItem` handles the copy.
        try FileManager.default.moveItem(at: downloaded, to: target)
        progress(1)
        return target
    }

    /// Puts a video track and an audio track into one MP4.
    ///
    /// Passthrough: the streams are copied as they are, not re-encoded, so this
    /// costs a file copy rather than a transcode and loses nothing. It is the whole
    /// reason this app needs no ffmpeg.
    ///
    /// Synchronous on purpose. The caller is already on a background queue waiting
    /// for a download, and threading an async path all the way back through the job
    /// runner would buy nothing.
    private static func join(video: URL, audio: URL, to output: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        // A box rather than a captured `var`: the task and this thread are two
        // isolation domains, and the semaphore is what orders them.
        final class Outcome: @unchecked Sendable { var failure: Error? }
        let outcome = Outcome()
        Task.detached {
            do {
                let composition = AVMutableComposition()
                let videoAsset = AVURLAsset(url: video)
                let audioAsset = AVURLAsset(url: audio)
                guard let source = try await videoAsset.loadTracks(withMediaType: .video).first,
                      let sound = try await audioAsset.loadTracks(withMediaType: .audio).first,
                      let videoTrack = composition.addMutableTrack(
                          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                      ),
                      let audioTrack = composition.addMutableTrack(
                          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                      )
                else { throw Failure.failed("The downloaded streams could not be read") }

                // The shorter of the two, for both tracks. The halves are the same
                // video, so they are the same length - but AVFoundation reads the
                // duration of yt-dlp's fragmented MP4 as exactly twice what it is
                // (measured: a 634s video declared as 1269s, with the frames
                // themselves correct and only the header wrong). Taking the audio
                // length as well avoids writing a file that claims ten minutes of
                // nothing at the end.
                let pictureLength = try await videoAsset.load(.duration)
                let soundLength = try await audioAsset.load(.duration)
                let length = min(pictureLength, soundLength)
                try videoTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: length), of: source, at: .zero
                )
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: length), of: sound, at: .zero
                )

                guard let export = AVAssetExportSession(
                    asset: composition, presetName: AVAssetExportPresetPassthrough
                ) else { throw Failure.failed("This Mac would not start an export") }
                try await export.export(to: output, as: .mp4)
            } catch {
                outcome.failure = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure = outcome.failure { throw failure }
    }

    /// `[download]  73.2% of 4.20MiB at ...`
    private static func percentage(in line: String) -> Double? {
        guard line.contains("[download]"), let percent = line.firstIndex(of: "%") else { return nil }
        let head = line[line.startIndex ..< percent]
        guard let start = head.lastIndex(where: { $0 == " " }) else { return nil }
        guard let value = Double(head[head.index(after: start)...]) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// The shortest useful line out of a failure, rather than the whole log.
    private static func reason(in output: String) -> String {
        let error = output.split(whereSeparator: \.isNewline)
            .last { $0.contains("ERROR:") || $0.contains("error:") }
        guard let error else { return "The download failed" }
        return String(error.replacingOccurrences(of: "ERROR: ", with: "").prefix(120))
    }

    /// Never overwrites: a second copy lands as "name-2.mp4", the way a browser
    /// would do it.
    private static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        for suffix in 2 ... 99 {
            let candidate = folder.appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(url.pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
