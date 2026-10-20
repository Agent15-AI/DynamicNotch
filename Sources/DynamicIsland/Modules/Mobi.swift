import Foundation

/// EPUB to MOBI, written here rather than shelled out to Calibre.
///
/// An EPUB is a zip of XHTML plus a manifest, and a MOBI is a Palm database whose
/// first record is a header and whose remaining records are the book. Neither
/// format needs a library: the reading is `XMLDocument`, the unzipping is
/// `/usr/bin/ditto`, and the writing is the byte layout below.
///
/// What it does: metadata (title, author), reading order from the spine, the text
/// of every chapter, and the images, rewritten to the `recindex` references Kindle
/// resolves.
///
/// What it does not do: a navigation table of contents. That needs `filepos`
/// anchors, which are byte offsets into the finished file, so every one of them has
/// to be patched after the text is assembled - a second pass this does not have.
/// Chapters still start on their own page and the whole book is readable; the
/// Kindle's chapter list is what is missing. Written down rather than discovered.
///
/// ponytail: records are stored uncompressed. PalmDOC compression is another
/// hundred lines to make a book about a third smaller, and every Kindle reads
/// uncompressed records.
enum Mobi {
    enum Failure: LocalizedError {
        case notEPUB
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notEPUB: "That is not an EPUB"
            case .unreadable(let what): "Could not read \(what)"
            case .empty: "That EPUB has no readable chapters"
            }
        }
    }

    /// Converts an EPUB and returns where the MOBI landed.
    @discardableResult
    static func convert(_ epub: URL, to destination: URL? = nil) throws -> URL {
        guard epub.pathExtension.lowercased() == "epub" else { throw Failure.notEPUB }
        let out = destination ?? epub.deletingPathExtension().appendingPathExtension("mobi")

        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }

        // ponytail: `ditto` is the system's own unzip and ships on every Mac. A zip
        // reader written here would be a few hundred lines to do what this does.
        guard run("/usr/bin/ditto", ["-x", "-k", epub.path, unpacked.path]) else {
            throw Failure.unreadable("the EPUB archive")
        }

        let book = try read(unpacked)
        guard !book.chapters.isEmpty else { throw Failure.empty }
        let data = assemble(book)
        try data.write(to: out, options: .atomic)
        return out
    }

    // MARK: - Reading the EPUB

    private struct Book {
        var title: String
        var author: String
        /// Body HTML per chapter, in spine order.
        var chapters: [String]
        /// Image bytes in the order they are referenced.
        var images: [Data]
    }

    private static func read(_ folder: URL) throws -> Book {
        // The one file an EPUB is guaranteed to have at a fixed path, and it says
        // where everything else lives.
        let containerURL = folder.appendingPathComponent("META-INF/container.xml")
        guard let container = try? XMLDocument(contentsOf: containerURL, options: []),
              let rootPath = (try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?
                  .first?.stringValue
        else { throw Failure.unreadable("META-INF/container.xml") }

        let opfURL = folder.appendingPathComponent(rootPath)
        guard let opf = try? XMLDocument(contentsOf: opfURL, options: []) else {
            throw Failure.unreadable(rootPath)
        }
        // Everything in the manifest is relative to the folder holding the OPF,
        // not to the root of the archive.
        let base = opfURL.deletingLastPathComponent()

        func text(_ xpath: String) -> String? {
            (try? opf.nodes(forXPath: xpath))?.first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = text("//*[local-name()='title']") ?? opfURL.deletingPathExtension().lastPathComponent
        let author = text("//*[local-name()='creator']") ?? ""

        // id -> (href, media type)
        var manifest: [String: (href: String, type: String)] = [:]
        for item in (try? opf.nodes(forXPath: "//*[local-name()='item']")) ?? [] {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue
            else { continue }
            manifest[id] = (href, element.attribute(forName: "media-type")?.stringValue ?? "")
        }

        var images: [Data] = []
        /// Image path (as written in the manifest) -> 1-based recindex.
        var imageIndex: [String: Int] = [:]
        var chapters: [String] = []

        for ref in (try? opf.nodes(forXPath: "//*[local-name()='itemref']")) ?? [] {
            guard let element = ref as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let item = manifest[idref],
                  let raw = try? String(
                      contentsOf: base.appendingPathComponent(item.href), encoding: .utf8
                  )
            else { continue }
            let chapter = body(of: raw)
            guard !chapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            chapters.append(rewriteImages(
                chapter,
                base: base.appendingPathComponent(item.href).deletingLastPathComponent(),
                images: &images,
                index: &imageIndex
            ))
        }

        return Book(title: title, author: author, chapters: chapters, images: images)
    }

    /// The contents of `<body>`, or the whole document when there is no body tag.
    ///
    /// Everything outside the body is either metadata or a stylesheet link, and
    /// Kindle ignores both - but an XML declaration left at the front of a chapter
    /// shows up as literal text in some readers.
    private static func body(of html: String) -> String {
        guard let open = html.range(of: "<body", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: open.upperBound ..< html.endIndex),
              let close = html.range(of: "</body>", options: [.caseInsensitive, .backwards])
        else {
            return html.replacingOccurrences(
                of: "<\\?xml[^>]*\\?>", with: "", options: .regularExpression
            )
        }
        return String(html[openEnd.upperBound ..< close.lowerBound])
    }

    /// Points every `<img>` at the image record that will hold it.
    ///
    /// Kindle does not resolve file paths inside a MOBI - an image is a record, and
    /// `recindex` is its number counting from the first image record. Anything that
    /// cannot be found on disk loses its tag rather than becoming a broken image.
    private static func rewriteImages(
        _ chapter: String, base: URL, images: inout [Data], index: inout [String: Int]
    ) -> String {
        var result = ""
        var rest = Substring(chapter)

        while let tag = rest.range(of: "<img", options: .caseInsensitive) {
            guard let end = rest.range(of: ">", range: tag.upperBound ..< rest.endIndex) else { break }
            result += rest[rest.startIndex ..< tag.lowerBound]
            let element = rest[tag.lowerBound ..< end.upperBound]
            rest = rest[end.upperBound...]

            guard let source = attribute("src", in: String(element)) else { continue }
            // Percent escapes are how a space in a filename travels in an href.
            let relative = source.removingPercentEncoding ?? source
            let file = URL(fileURLWithPath: relative, relativeTo: base).standardizedFileURL
            let key = file.path

            let recindex: Int
            if let known = index[key] {
                recindex = known
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                images.append(data)
                recindex = images.count
                index[key] = recindex
            }
            result += "<img recindex=\"\(String(format: "%05d", recindex))\"/>"
        }
        result += rest
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            guard let start = tag.range(of: "\(name)=\(quote)", options: .caseInsensitive),
                  let end = tag.range(of: quote, range: start.upperBound ..< tag.endIndex)
            else { continue }
            return String(tag[start.upperBound ..< end.lowerBound])
        }
        return nil
    }

    // MARK: - Writing the MOBI

    private static let recordSize = 4096

    private static func assemble(_ book: Book) -> Data {
        var html = "<html><head><guide></guide></head><body>"
        // A page break between chapters, which is the only structure MOBI has
        // without a table of contents.
        html += book.chapters.joined(separator: "<mbp:pagebreak/>")
        html += "</body></html>"
        let text = Data(html.utf8)

        var textRecords: [Data] = []
        var offset = 0
        while offset < text.count {
            let end = min(offset + recordSize, text.count)
            textRecords.append(text[offset ..< end])
            offset = end
        }
        if textRecords.isEmpty { textRecords.append(Data()) }

        let titleBytes = Array(book.title.utf8)
        let firstNonBook = 1 + textRecords.count
        let firstImage = firstNonBook
        let lastContent = textRecords.count + book.images.count

        // Record 0: PalmDOC header, MOBI header, EXTH, then the title it points at.
        var header = Data()
        header.append(uint16: 1)                          // no compression
        header.append(uint16: 0)
        header.append(uint32: UInt32(text.count))
        header.append(uint16: UInt16(textRecords.count))
        header.append(uint16: UInt16(recordSize))
        header.append(uint16: 0)                          // not encrypted
        header.append(uint16: 0)

        let exth = exthBlock(book)
        // The MOBI header is a fixed 232 bytes from its own magic, so the title
        // lands right after the EXTH block that follows it.
        let mobiLength = 232
        let fullNameOffset = 16 + mobiLength + exth.count

        var mobi = Data(count: mobiLength)
        mobi.replaceSubrange(0 ..< 4, with: Data("MOBI".utf8))
        mobi.write(uint32: UInt32(mobiLength), at: 4)     // header length
        mobi.write(uint32: 2, at: 8)                      // a book
        mobi.write(uint32: 65001, at: 12)                 // UTF-8
        mobi.write(uint32: UInt32.random(in: 1 ... .max), at: 16)
        mobi.write(uint32: 6, at: 20)                     // file version
        // Index fields: none of them exist in this file.
        for field in stride(from: 24, through: 60, by: 4) {
            mobi.write(uint32: 0xFFFF_FFFF, at: field)
        }
        mobi.write(uint32: UInt32(firstNonBook), at: 64)
        mobi.write(uint32: UInt32(fullNameOffset), at: 68)
        mobi.write(uint32: UInt32(titleBytes.count), at: 72)
        mobi.write(uint32: 9, at: 76)                     // locale: English
        mobi.write(uint32: 0, at: 80)                     // input language
        mobi.write(uint32: 0, at: 84)                     // output language
        mobi.write(uint32: 6, at: 88)                     // minimum reader version
        mobi.write(uint32: UInt32(firstImage), at: 92)
        // Huffman fields stay zero: the text is not compressed.
        mobi.write(uint32: 0x40, at: 112)                 // EXTH present
        mobi.write(uint32: 0xFFFF_FFFF, at: 148)          // unknown, always this
        mobi.write(uint32: 0xFFFF_FFFF, at: 152)          // DRM offset: none
        mobi.write(uint32: 0, at: 156)                    // DRM count
        mobi.write(uint32: 0, at: 160)                    // DRM size
        mobi.write(uint32: 0, at: 164)                    // DRM flags
        mobi.write(uint16: 1, at: 176)                    // first content record
        mobi.write(uint16: UInt16(lastContent), at: 178)
        mobi.write(uint32: 1, at: 180)
        mobi.write(uint32: 0xFFFF_FFFF, at: 184)          // no FCIS record
        mobi.write(uint32: 1, at: 188)
        mobi.write(uint32: 0xFFFF_FFFF, at: 192)          // no FLIS record
        mobi.write(uint32: 1, at: 196)
        mobi.write(uint32: 0xFFFF_FFFF, at: 208)
        mobi.write(uint32: 0, at: 212)
        mobi.write(uint32: 0xFFFF_FFFF, at: 216)
        mobi.write(uint32: 0xFFFF_FFFF, at: 220)
        mobi.write(uint32: 0, at: 224)                    // no trailing record data
        mobi.write(uint32: 0xFFFF_FFFF, at: 228)          // no index record

        header.append(mobi)
        header.append(exth)
        header.append(contentsOf: titleBytes)
        // Two zero bytes terminate the name, then pad to a four-byte boundary -
        // what every MOBI in the wild does, and some readers expect it.
        header.append(contentsOf: [0, 0])
        while header.count % 4 != 0 { header.append(0) }

        let records = [header] + textRecords + book.images
        return palmDatabase(name: book.title, records: records)
    }

    /// Title and author, as the Kindle's own metadata rather than only as text.
    private static func exthBlock(_ book: Book) -> Data {
        var entries: [(UInt32, String)] = [(503, book.title)]     // updated title
        if !book.author.isEmpty { entries.append((100, book.author)) }

        var body = Data()
        for (type, value) in entries {
            let bytes = Array(value.utf8)
            body.append(uint32: type)
            body.append(uint32: UInt32(bytes.count + 8))
            body.append(contentsOf: bytes)
        }

        var exth = Data()
        exth.append(contentsOf: Array("EXTH".utf8))
        // Length counts the magic, these two fields, the records and the padding.
        var length = 12 + body.count
        let padding = (4 - length % 4) % 4
        length += padding
        exth.append(uint32: UInt32(length))
        exth.append(uint32: UInt32(entries.count))
        exth.append(body)
        exth.append(contentsOf: [UInt8](repeating: 0, count: padding))
        return exth
    }

    /// The Palm database around the records: a 78-byte header, an offset per
    /// record, then the records themselves.
    private static func palmDatabase(name: String, records: [Data]) -> Data {
        var file = Data()

        // 32 bytes, null-terminated. Spaces would be legal and every tool in this
        // lineage writes underscores.
        var nameField = Array(name.replacingOccurrences(of: " ", with: "_").utf8.prefix(31))
        nameField += [UInt8](repeating: 0, count: 32 - nameField.count)
        file.append(contentsOf: nameField)

        file.append(uint16: 0)                            // attributes
        file.append(uint16: 0)                            // version
        // Palm time is seconds since 1904, and a zero here makes some readers show
        // 1904 as the date added.
        let palmTime = UInt32(Date().timeIntervalSince1970 + 2_082_844_800)
        file.append(uint32: palmTime)                     // created
        file.append(uint32: palmTime)                     // modified
        file.append(uint32: 0)                            // backed up
        file.append(uint32: 0)                            // modification number
        file.append(uint32: 0)                            // app info
        file.append(uint32: 0)                            // sort info
        file.append(contentsOf: Array("BOOK".utf8))
        file.append(contentsOf: Array("MOBI".utf8))
        file.append(uint32: UInt32(palmTime))             // unique id seed
        file.append(uint32: 0)                            // next record list
        file.append(uint16: UInt16(records.count))

        // Two bytes of gap after the record list, which is what the format's own
        // writers leave and what readers measure the first record against.
        var offset = 78 + records.count * 8 + 2
        for (index, record) in records.enumerated() {
            file.append(uint32: UInt32(offset))
            file.append(0)                                // attributes
            // Unique id: three bytes, conventionally twice the index.
            let uid = UInt32(index * 2)
            file.append(contentsOf: [
                UInt8((uid >> 16) & 0xFF), UInt8((uid >> 8) & 0xFF), UInt8(uid & 0xFF),
            ])
            offset += record.count
        }
        file.append(contentsOf: [0, 0])
        for record in records { file.append(record) }
        return file
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Big-endian writers. Every number in a Palm database is big-endian, and getting
/// one of them the wrong way round produces a file that opens and shows nothing.
private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    mutating func write(uint16 value: UInt16, at index: Int) {
        replaceSubrange(index ..< index + 2, with: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func write(uint32 value: UInt32, at index: Int) {
        replaceSubrange(index ..< index + 4, with: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}
