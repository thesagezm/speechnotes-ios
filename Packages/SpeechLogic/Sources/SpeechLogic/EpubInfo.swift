import Foundation

/// One table-of-contents row, already resolved to a ZIP entry path
/// (fragment `#…` stripped).
public struct EpubTocEntry: Equatable {
    public let label: String
    public let href: String
}

/// What the library list + reader need to know about an EPUB without ever
/// rendering it: metadata, spine (reading order), TOC and cover location.
/// Parsed with Foundation's XMLParser only — no dependencies. Rendering is
/// epub.js's job; this type exists so the LIBRARY never opens a webview
/// (title/author/cover for a shelf of books must cost a few XML reads, not
/// one web process per book).
public struct EpubInfo: Equatable {
    public let title: String?
    public let creator: String?
    public let language: String?
    /// Zip entry paths of the spine items, in reading order.
    public let spine: [String]
    public let toc: [EpubTocEntry]
    /// Zip entry path of the cover image (EPUB3 `properties="cover-image"`
    /// or EPUB2 `<meta name="cover">` — Gutenberg uses the latter), if found.
    public let coverPath: String?
}

/// Parsing entry point + XML delegates. (`EpubInfo` above is the parsed
/// RESULT type; this enum is the operations namespace.)
public enum EpubParser {

    public enum EpubError: Error, Equatable {
        /// META-INF/container.xml missing or has no rootfile.
        case missingContainer
        /// The OPF file named by container.xml is missing.
        case missingOpf(path: String)
        /// The OPF could not be parsed as XML (EPUB requires well-formed XML;
        /// this indicates a broken container, not a style variant).
        case malformedOpf(path: String, message: String)
    }

    /// Parses metadata from a whole EPUB archive. Only reads a handful of
    /// small XML entries — pass the file memory-mapped if it is large.
    public static func parse(archive: Data) throws -> EpubInfo {
        let containerData: Data
        do {
            containerData = try ZipReader.readEntry("META-INF/container.xml", in: archive)
        } catch ZipReader.ZipError.entryNotFound {
            throw EpubError.missingContainer
        }
        let opfPath = ContainerDelegate.run(containerData)
        guard let opfPath else { throw EpubError.missingContainer }
        guard let opfData = try? ZipReader.readEntry(opfPath, in: archive) else {
            throw EpubError.missingOpf(path: opfPath)
        }

        let opf = PackageDelegate.run(opfData)
        guard opf.parsedWithoutError else {
            throw EpubError.malformedOpf(path: opfPath, message: opf.errorMessage ?? "unknown")
        }

        let opfDir = directory(of: opfPath)
        let manifestByID = opf.manifest
        let spine = opf.spineItemRefs.compactMap { id -> String? in
            guard let href = manifestByID[id]?.href else { return nil }
            return resolve(href, relativeTo: opfDir)
        }

        // Cover: EPUB3 property first (explicit), EPUB2 meta fallback
        // (Gutenberg's convention — verified against pg1342/pg11).
        var coverPath: String? = nil
        if let item = opf.manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            coverPath = resolve(item.href, relativeTo: opfDir)
        } else if let coverID = opf.coverMetaID, let item = manifestByID[coverID] {
            coverPath = resolve(item.href, relativeTo: opfDir)
        }

        let toc = toc(from: opf, archive: archive, opfDir: opfDir)
        return EpubInfo(
            title: opf.title,
            creator: opf.creator,
            language: opf.language,
            spine: spine,
            toc: toc,
            coverPath: coverPath
        )
    }

    // MARK: - TOC

    /// EPUB3 `properties="nav"` XHTML preferred, EPUB2 NCX fallback (the
    /// spine's `toc=` attribute, else the NCX media-type in the manifest).
    /// TOC problems are never fatal — a shelf book without a TOC is still
    /// readable; navigation just falls back to the spine.
    private static func toc(from opf: PackageDelegate.Package, archive: Data, opfDir: String) -> [EpubTocEntry] {
        if let navItem = opf.manifest.values.first(where: { $0.properties.contains("nav") }) {
            let navPath = resolve(navItem.href, relativeTo: opfDir)
            if let navData = try? ZipReader.readEntry(navPath, in: archive) {
                let entries = NavDelegate.run(navData)
                if !entries.isEmpty {
                    // Nav anchors are relative to the NAV file's directory
                    // (usually the same as the OPF's, but never assume).
                    let navDir = directory(of: navPath)
                    return entries.map { entry in
                        EpubTocEntry(label: entry.label, href: resolve(entry.href, relativeTo: navDir))
                    }
                }
            }
        }
        let ncxHref: String? = opf.spineTocID.flatMap { opf.manifest[$0]?.href }
            ?? opf.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.href
        guard let ncxHref,
              let ncxData = try? ZipReader.readEntry(resolve(ncxHref, relativeTo: opfDir), in: archive) else {
            return []
        }
        let ncxDir = directory(of: resolve(ncxHref, relativeTo: opfDir))
        return NcxDelegate.run(ncxData).map { entry in
            EpubTocEntry(label: entry.label, href: resolve(entry.href, relativeTo: ncxDir))
        }
    }

    // MARK: - Path helpers

    /// Directory part of a zip entry path ("OEBPS/content.opf" → "OEBPS",
    /// "content.opf" → "").
    static func directory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<idx])
    }

    /// Resolves an OPF/NCX href to a zip entry path (fragment stripped,
    /// `..` collapsed). Falls back to percent-encoding because sloppy books
    /// ship unencoded spaces; a resolution failure degrades to the raw href.
    static func resolve(_ href: String, relativeTo baseDir: String) -> String {
        let clean = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        guard !clean.isEmpty else { return clean }
        let base = URL(fileURLWithPath: baseDir.isEmpty ? "/" : baseDir, isDirectory: true)
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clean
        guard let url = URL(string: encoded, relativeTo: base) else { return clean }
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    // MARK: - container.xml

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        static func run(_ data: Data) -> String? {
            let delegate = ContainerDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.rootfilePath
        }

        var rootfilePath: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if localName(qName ?? elementName) == "rootfile" {
                rootfilePath = rootfilePath ?? attributeDict["full-path"]
            }
        }
    }

    // MARK: - OPF (package)

    private final class PackageDelegate: NSObject, XMLParserDelegate {
        struct Item {
            var href: String
            var mediaType: String
            var properties: [String]
        }

        struct Package {
            var title: String?
            var creator: String?
            var language: String?
            var coverMetaID: String?
            var manifest: [String: Item] = [:]
            var spineItemRefs: [String] = []
            var spineTocID: String?
            var parsedWithoutError = true
            var errorMessage: String?
        }

        static func run(_ data: Data) -> Package {
            let delegate = PackageDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            parser.parse()
            return delegate.pkg
        }

        var pkg = Package()
        private var textBuffer = ""
        private var capturing: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = localName(qName ?? elementName)
            let isDublinCore = namespaceURI == "http://purl.org/dc/elements/1.1/" || (qName ?? elementName).hasPrefix("dc:")
            if isDublinCore, name == "title" || name == "creator" || name == "language" {
                textBuffer = ""
                capturing = name
            } else if name == "meta" {
                if attributeDict["name"] == "cover" {
                    pkg.coverMetaID = pkg.coverMetaID ?? attributeDict["content"]
                }
            } else if name == "item" {
                if let id = attributeDict["id"], let href = attributeDict["href"] {
                    pkg.manifest[id] = Item(
                        href: href,
                        mediaType: attributeDict["media-type"] ?? "",
                        properties: (attributeDict["properties"] ?? "")
                            .split(separator: " ")
                            .map(String.init)
                    )
                }
            } else if name == "itemref" {
                if let idref = attributeDict["idref"] {
                    pkg.spineItemRefs.append(idref)
                }
            } else if name == "spine" {
                pkg.spineTocID = attributeDict["toc"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = localName(qName ?? elementName)
            if capturing == name {
                let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    switch name {
                    case "title": pkg.title = pkg.title ?? value
                    case "creator": pkg.creator = pkg.creator ?? value
                    case "language": pkg.language = pkg.language ?? value
                    default: break
                    }
                }
                capturing = nil
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            pkg.parsedWithoutError = false
            pkg.errorMessage = parseError.localizedDescription
        }
    }

    // MARK: - EPUB2 toc.ncx

    private final class NcxDelegate: NSObject, XMLParserDelegate {
        static func run(_ data: Data) -> [(label: String, href: String)] {
            let delegate = NcxDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            parser.parse()
            return delegate.entries
        }

        private var entries: [(label: String, href: String)] = []
        private var labelBuffers: [String] = []
        private var pendingHrefs: [String?] = [nil]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch localName(qName ?? elementName) {
            case "navPoint":
                labelBuffers.append("")
                pendingHrefs.append(nil)
            case "content":
                pendingHrefs[pendingHrefs.count - 1] = attributeDict["src"]
            case "text":
                // docTitle's <text> arrives before any navPoint opens — only
                // reset when a navPoint's buffer actually exists.
                if !labelBuffers.isEmpty { labelBuffers[labelBuffers.count - 1] = "" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !labelBuffers.isEmpty {
                labelBuffers[labelBuffers.count - 1] += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard localName(qName ?? elementName) == "navPoint", !labelBuffers.isEmpty else { return }
            let label = labelBuffers.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
            let href = pendingHrefs.removeLast()
            if let href, !href.isEmpty, !label.isEmpty {
                entries.append((label: label, href: href))
            }
        }
    }

    // MARK: - EPUB3 nav.xhtml

    private final class NavDelegate: NSObject, XMLParserDelegate {
        static func run(_ data: Data) -> [EpubTocEntry] {
            let delegate = NavDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            parser.parse()
            // The nav document may carry several <nav> lists (toc, landmarks,
            // page-list). Prefer the one marked epub:type~"toc"; else the first.
            return delegate.tocNav ?? delegate.navs.first ?? []
        }

        private var navs: [[EpubTocEntry]] = []
        private var tocNav: [EpubTocEntry]?
        private var navIsToc = false
        private var anchorHref: String?
        private var anchorBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = localName(qName ?? elementName)
            switch name {
            case "nav":
                let type = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
                navIsToc = type.split(separator: " ").contains("toc")
                navs.append([])
            case "a":
                anchorHref = attributeDict["href"]
                anchorBuffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            anchorBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(qName ?? elementName) {
            case "nav":
                if navIsToc, tocNav == nil, let last = navs.last {
                    tocNav = last
                }
                navIsToc = false
            case "a":
                let label = anchorBuffer
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Collapses the whitespace runs multi-line labels accumulate.
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if let href = anchorHref, !href.isEmpty, !label.isEmpty, !navs.isEmpty {
                    navs[navs.count - 1].append(EpubTocEntry(label: label, href: href))
                }
                anchorHref = nil
            default:
                break
            }
        }
    }

    // MARK: - XML name helpers

    /// "dc:title" → "title", "title" → "title". XMLParser hands prefixed
    /// qNames for namespaced elements; the app targets are matched on the
    /// local part so prefix variations keep working.
    private static func localName(_ qName: String) -> String {
        qName.split(separator: ":", maxSplits: 1).last.map(String.init) ?? qName
    }
}
