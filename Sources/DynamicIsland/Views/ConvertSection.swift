import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files in, files out: a link to a video file, an EPUB to a MOBI, anything with
/// sound to an MP3.
///
/// Two columns, because these are two different gestures. A link is typed; a file
/// is chosen or dropped on the shelf, where the same conversions sit in the
/// right-click menu. The list underneath is what is running and what just landed -
/// a conversion takes long enough that the island is usually shut by the time it
/// finishes, which is why every job also posts a receipt.
struct ConvertSection: View {
    var convert = Convert.shared
    @State private var link = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            fromALink.frame(width: 262)

            Rectangle()
                .fill(Theme.edge)
                .frame(width: 1)
                .padding(.vertical, 2)

            fromAFile.frame(maxWidth: .infinity, alignment: .leading)
        }
        // The link is almost always the one just copied in a browser, so the field
        // starts filled in rather than asking for a paste that has already
        // happened. Only a web link, and only while the field is empty.
        .onAppear {
            guard link.isEmpty,
                  let copied = NSPasteboard.general.string(forType: .string)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  copied.hasPrefix("http"), copied.count < 2048,
                  !copied.contains(where: \.isWhitespace)
            else { return }
            link = copied
        }
    }

    // MARK: - Link

    @ViewBuilder
    private var fromALink: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("FROM A LINK").sectionLabel()

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                TextField("Paste a video link", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primary)
                    .onSubmit { download(.video) }
                if !link.isEmpty {
                    TextAction("Clear", tint: Theme.tertiary) { link = "" }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )

            if YouTube.available {
                HStack(spacing: 5) {
                    ForEach([YouTube.Kind.video, .audio, .mp3], id: \.label) { kind in
                        TextAction(kind.label, tint: kind == .video ? Theme.core : Theme.gold) {
                            download(kind)
                        }
                        .disabled(link.isEmpty)
                        .opacity(link.isEmpty ? 0.45 : 1)
                    }
                    Spacer(minLength: 0)
                }
                Text("MP4 joins the picture and sound here, no ffmpeg needed. "
                     + "MP3 is encoded here, not downloaded.")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // A row of buttons that cannot work is worse than saying why.
                Text("Needs yt-dlp. Put a copy in the project's Vendor folder and "
                     + "rebuild, or install it with Homebrew.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextAction("Copy the install command", tint: Theme.gold) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                    HUD.shared.show(
                        .utility(symbol: "doc.on.doc.fill", title: "brew install yt-dlp",
                                 detail: "Copied"),
                        for: 2.0
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func download(_ kind: YouTube.Kind) {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        convert.youtube(text, kind: kind)
        link = ""
    }

    // MARK: - File

    @ViewBuilder
    private var fromAFile: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("FROM A FILE").sectionLabel()
                Spacer(minLength: 0)
                if convert.jobs.contains(where: { $0.finished || $0.failed }) {
                    TextAction("Clear", tint: Theme.tertiary) { convert.clear() }
                }
            }

            if convert.jobs.isEmpty {
                EmptyState(symbol: "book.closed",
                           title: "Images to PDF, EPUB to MOBI, audio to MP3",
                           detail: "Pick several at once · or right-click the shelf",
                           actionTitle: "Choose files…",
                           action: choose)
            } else {
                HStack(spacing: 6) {
                    TextAction("Choose files…", tint: Theme.gold, action: choose)
                    Spacer(minLength: 0)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(convert.jobs) { JobRow(job: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The system's own open panel, for the same reason the uninstaller uses it -
    /// dropping onto the island is already the shelf's gesture.
    ///
    /// Several files at once, because the thing people most want converted is a
    /// pile of photographs rather than one. Pictures in the selection become one
    /// PDF, a page each, in the order the panel hands them over; anything else
    /// converts on its own.
    ///
    /// `UTType.image` covers HEIC, which is what a phone actually produces. A
    /// picker that greys out every photograph on the Mac is not a picker.
    private func choose() {
        let panel = NSOpenPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.allowsMultipleSelection = true
        panel.prompt = "Convert"
        panel.message = "Pictures become one PDF, a page each. Anything else converts on its own."
        panel.allowedContentTypes = [
            .image, .heic, .heif, .jpeg, .png, .tiff, .gif, .bmp, .webP,
            .epub, .audio, .audiovisualContent, .zip, .archive,
        ]
        // The island floats above everything, so an open island would sit on top
        // of the panel.
        PanelManager.shared.collapseAll()
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                let pictures = urls.filter(Convert.isImage)
                if !pictures.isEmpty { Convert.shared.imagesToPDF(pictures) }
                for url in urls where !Convert.isImage(url) {
                    Convert.shared.bestGuess(for: url)
                }
                PanelManager.shared.focusIsland(tab: .tools)
            }
        }
        // An accessory app's panel opens without the keyboard: it appears, and
        // ⇧⌘G, type-to-select and ⌘A all go to whatever was in front before.
        // Claimed after `begin`, because that is when the window exists.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct JobRow: View {
    var job: Convert.Job
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(job.failed ? Theme.core : Theme.gold)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let progress = job.progress, !job.finished, !job.failed {
                    LevelBar(fraction: progress).frame(height: 3)
                } else {
                    Text(job.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let result = job.result {
                TextAction("Reveal", tint: Theme.core) { Convert.shared.reveal(result) }
            } else if let progress = job.progress, !job.failed {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.06 : 0.03))
        )
        .hoverHighlight($hovering)
        .help(job.result?.path ?? job.detail)
    }

    private var symbol: String {
        if job.failed { return "exclamationmark.triangle.fill" }
        if job.finished { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }
}

extension Convert {
    /// Picks the obvious conversion for a file, so one button covers the panel.
    ///
    /// An EPUB means MOBI, a sound or a video means MP3, an archive means unpack.
    /// Nothing else has one obvious answer, so nothing else is guessed at.
    func bestGuess(for url: URL) {
        if Self.isEPUB(url) {
            epubToMobi(url)
        } else if Self.isMedia(url) {
            toMP3(url)
        } else if Self.isArchive(url) {
            extract(url)
        } else if Self.isImage(url) {
            imagesToPDF([url])
        } else {
            HUD.shared.show(
                .utility(symbol: "questionmark.folder", title: url.lastPathComponent,
                         detail: "Nothing to convert it to"),
                for: 2.6
            )
        }
    }
}
