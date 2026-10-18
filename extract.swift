// scriba-extract – the text of school documents, for Scriba (a Lotus plugin). Everything runs on this Mac:
// PDFKit reads PDFs, Apple's Vision reads text in pictures and scans, Office files are read from their XML.
//
//   scriba-extract <file> <out> [<pictures>]
//                                    the text of <file> into <out>, in units (pages, slides, sheets):
//                                    "\u{1E}<label>\u{1F}<kind>" on a line of its own, then the text
//                                    label: "S. 3", "Folie 2", "Blatt Noten" or "" (the whole file)
//                                    kind:  text · math (formulas a PDF may have broken) · ocr (all of it read
//                                           from a picture) · pic (text, and blocks "[Bildtext]" … read from
//                                           pictures in it, each ending with an empty line) · code · note
//                                    on stdout: progress ("page <n> <of>"), or "error <what>" and status 1;
//                                    status 3: the text recognition of macOS hung (it does, rarely) – what it read
//                                    up to then is written, and a new run usually goes through
//                                    (stderr is silenced – PDFKit and CoreText talk a lot there)
//                                    with <pictures>: the pictures of the file go into that folder (PDF pictures cut
//                                    out of their page, a scanned page whole), and a line "\u{1D}<file>\u{1D}<alt>"
//                                    stands where each one was
//   scriba-extract --version
//
// Formulas of Word and PowerPoint become LaTeX, tables become Markdown tables, Excel formulas are kept next to
// their values. Headers and footers that repeat on every page are left out – they only cost tokens.

import AppKit
import CoreImage
import Foundation
import PDFKit
import Vision

setvbuf(stdout, nil, _IOLBF, 0)
freopen("/dev/null", "w", stderr)

struct Unit { var label: String; var kind: String; var text: String }
struct Fail: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

func progress(_ n: Int, _ of: Int) { print("page \(n) \(of)") }

// ── Text recognition (Vision) ──────────────────────────────────

let ocrLanguages: [String] = {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    let have = (try? req.supportedRecognitionLanguages()) ?? ["en-US"]
    let want = ["de-DE", "en-US", "fr-FR", "it-IT"].filter { have.contains($0) }
    return want.isEmpty ? ["en-US"] : want
}()

var ocrHung = false

/// The lines of text in a picture, top to bottom; pieces side by side are kept apart by two spaces
/// minimum: how sure Vision has to be – higher for pictures inside documents (screenshots make noise)
/// Vision gets a minute (its first start on a Mac can take half of that). When it hangs, there is no more text
/// recognition in this run – the program ends with status 3 and Scriba starts it once more.
func ocr(_ image: CGImage, _ orientation: CGImagePropertyOrientation = .up, minimum: Float = 0.3) -> [String] {
    guard !ocrHung, image.width >= 24, image.height >= 24 else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ocrLanguages
    let done = DispatchSemaphore(value: 0)
    var failed = false
    DispatchQueue.global(qos: .userInitiated).async {
        do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([req]) } catch { failed = true }
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .timedOut { ocrHung = true; return [] }
    if failed { return [] }
    struct Piece { let x, y, h: CGFloat; let s: String }
    var pieces: [Piece] = (req.results ?? []).compactMap { o in
        guard let c = o.topCandidates(1).first, c.confidence >= minimum else { return nil }
        let b = o.boundingBox
        return Piece(x: b.minX, y: b.midY, h: b.height, s: c.string)
    }
    pieces.sort { $0.y > $1.y }
    var lines: [[Piece]] = []
    for p in pieces {
        if let first = lines.last?.first, abs(first.y - p.y) < min(first.h, p.h) * 0.5 {
            lines[lines.count - 1].append(p)
        } else {
            lines.append([p])
        }
    }
    return lines.map { $0.sorted { $0.x < $1.x }.map(\.s).joined(separator: "  ") }
}

/// A picture file → its pixels and how it is turned (photos of a phone)
func loadImage(_ url: URL) -> (CGImage, CGImagePropertyOrientation)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
    return (img, CGImagePropertyOrientation(rawValue: raw) ?? .up)
}

// ── Pictures for the Markdown ──────────────────────────────────

var pictureDir: URL? = nil                 // the third argument – without it no pictures are kept
var pictureSeen = Set<String>()            // a picture of a document is shown and read once (a logo on every slide)
var pictureCounts: [String: Int] = [:]

/// "Bild S. 3" – what a picture is called in the Markdown
func alt(_ label: String) -> String { label.isEmpty ? "Bild" : "Bild \(label)" }

/// The line that stands for a picture: "\u{1D}<file>\u{1D}<alt>"
func pictureMark(_ file: String, _ label: String) -> String { "\u{1D}\(file)\u{1D}\(alt(label))" }

/// A free name in the picture folder: "S3-1.jpg", "Folie2-1.png", "Bild-1.png"
func pictureName(_ label: String, _ ext: String) -> String {
    let base = label.isEmpty ? "Bild" : label.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
    let n = (pictureCounts[base] ?? 0) + 1
    pictureCounts[base] = n
    return "\(base)-\(n).\(ext)"
}

/// The picture turned upright, at most 1600 pixels on its long side
func upright(_ img: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
    var ci = CIImage(cgImage: img).oriented(orientation)
    let long = max(ci.extent.width, ci.extent.height)
    if long > 1600 { ci = ci.transformed(by: CGAffineTransform(scaleX: 1600 / long, y: 1600 / long)) }
    if orientation == .up, long <= 1600 { return img }
    return CIContext().createCGImage(ci, from: ci.extent.integral) ?? img
}

/// Writes a picture into the folder → its name
func savePicture(_ img: CGImage, _ label: String, jpeg: Bool) -> String? {
    guard let dir = pictureDir else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = pictureName(label, jpeg ? "jpg" : "png")
    guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                     (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil)
    return CGImageDestinationFinalize(dest) ? name : nil
}

/// A picture file of a document into the folder: copied as it is when a browser shows it and it is not too large,
/// otherwise as PNG or JPEG → its name
func keepPicture(_ url: URL, _ img: CGImage, _ orientation: CGImagePropertyOrientation, _ label: String) -> String? {
    guard let dir = pictureDir else { return nil }
    let ext = url.pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif"].contains(ext), orientation == .up, max(img.width, img.height) <= 1600 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = pictureName(label, ext == "jpeg" ? "jpg" : ext)
        return (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))) != nil ? name : nil
    }
    let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(img.alphaInfo)
    return savePicture(upright(img, orientation), label, jpeg: opaque && ext != "png")
}

/// A picture inside a document as lines: the picture (when they are kept), then "[Bildtext]" and what it says.
/// "[Bild]" for a larger picture without text when pictures are not kept; nothing for small decoration and for a
/// picture that was shown before.
func pictureLines(_ url: URL, _ label: String) -> [String] {
    guard pictureSeen.insert(url.standardizedFileURL.path).inserted, let (img, orientation) = loadImage(url) else { return [] }
    let big = img.width >= 120 && img.height >= 60 && img.width * img.height >= 20_000
    let lines = cleanLines(ocr(img, orientation, minimum: 0.5).joined(separator: "\n")).filter { $0.count >= 3 }
    var out: [String] = []
    if big, let name = keepPicture(url, img, orientation, label) { out.append(pictureMark(name, label)) }
    if lines.isEmpty {
        if out.isEmpty, img.width >= 200, img.height >= 150 { out.append("[Bild]") }
        return out.isEmpty ? [] : out + [""]
    }
    return out + ["[Bildtext]"] + lines + [""]
}

// ── Lines ──────────────────────────────────────────────────────

let ligatures: [(String, String)] = [("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"),
                                     ("\u{FB04}", "ffl"), ("\u{00A0}", " "), ("\u{00AD}", ""), ("\u{2028}", "\n"),
                                     ("\u{2029}", "\n"), ("\r\n", "\n"), ("\r", "\n"), ("\t", "  "), ("\u{000B}", "\n"),
                                     ("\u{F0B7}", "•"), ("\u{F0A7}", "•"), ("\u{F0D8}", "•"), ("\u{FFFC}", "")]

/// Runs that only cost tokens: dot leaders of a table of contents, long lines to write on, wide gaps
let squeeze: [(NSRegularExpression, String)] = [
    (try! NSRegularExpression(pattern: #"\s*(?:\.\s?){4,}\s*|\s*…{2,}\s*"#), " … "),
    (try! NSRegularExpression(pattern: #"_{4,}"#), "___"),
    (try! NSRegularExpression(pattern: #"[-–—=]{5,}"#), "---"),
    (try! NSRegularExpression(pattern: #"(?<=\S) {3,}(?=\S)"#), "  "),
]

/// HTML tags in running text ("Tags wie <h1> und <p>") as code – a Markdown viewer would take them as HTML
let tags = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*?)?/?>"#)
func codeTags(_ s: String) -> String {
    guard s.contains("<"), !s.contains("`") else { return s }
    return tags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "`$0`")
}

/// Text → lines without trailing spaces, at most one empty line in a row, words split at the end of a line joined
func cleanLines(_ text: String) -> [String] {
    var t = text
    for (a, b) in ligatures { t = t.replacingOccurrences(of: a, with: b) }
    var out: [String] = []
    for raw in t.components(separatedBy: "\n") {
        var line = raw
        for (re, with) in squeeze where line.count >= 4 {
            line = re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: with)
        }
        line = codeTags(line)
        while line.last == " " { line.removeLast() }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = out.last, !last.isEmpty { out.append("") }
            continue
        }
        // "Bruch-" + "rechnung" → "Bruchrechnung", but "Ein-" + "und Ausgabe" stays
        if let last = out.last, last.count > 2, last.hasSuffix("-"),
           let before = last.dropLast().last, before.isLetter,
           let first = line.first, first.isLowercase {
            let next = line.split(separator: " ").first.map(String.init) ?? ""
            if !["und", "oder", "bzw.", "sowie", "bis", "and", "or"].contains(next) {
                out[out.count - 1] = String(last.dropLast()) + line.trimmingCharacters(in: .whitespaces)
                continue
            }
        }
        out.append(line)
    }
    while out.last?.isEmpty == true { out.removeLast() }
    while out.first?.isEmpty == true { out.removeFirst() }
    return out
}

/// For comparing lines: lower case, letters and digits only
func norm(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

/// Lines that open or close most pages (a header, a footer, "Seite 3 von 12") – left out of every page. So are the
/// lines a browser prints itself: the address with "3/60" at the bottom, date and time at the top.
func dropRepeated(_ pages: inout [[String]]) {
    let n = pages.filter { !$0.isEmpty }.count
    let pageNumber = try! NSRegularExpression(pattern: #"^\s*(seite|page|s\.)?\s*\d{1,4}\s*((/|von|of)\s*\d{1,4})?\s*$"#,
                                              options: .caseInsensitive)
    let browser = try! NSRegularExpression(pattern: #"^\s*((https?|file)://\S+(\s+\d{1,4}\s*/\s*\d{1,4})?|\d{1,2}[./]\d{1,2}[./]\d{2,4},?\s+\d{1,2}:\d{2}(\s.*)?)\s*$"#)
    func isNumber(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return pageNumber.firstMatch(in: s, range: r) != nil || browser.firstMatch(in: s, range: r) != nil
    }
    func key(_ s: String) -> String { String(norm(s).map { $0.isNumber ? "#" : $0 }) }
    func edges(_ p: [String]) -> [Int] {
        let idx = p.indices.filter { !p[$0].isEmpty }
        return Array(Set(idx.prefix(3) + idx.suffix(3))).sorted()
    }
    var count: [String: Int] = [:]
    for p in pages {
        var seen = Set<String>()
        for i in edges(p) { let k = key(p[i]); if !k.isEmpty, p[i].count < 400, seen.insert(k).inserted { count[k, default: 0] += 1 } }
    }
    let repeated = n >= 3 ? Set(count.filter { $0.value >= max(3, (n + 1) / 2) }.keys) : []
    for i in pages.indices {
        let drop = Set(edges(pages[i]).filter { repeated.contains(key(pages[i][$0])) || isNumber(pages[i][$0]) })
        if drop.isEmpty { continue }
        pages[i] = pages[i].enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        while pages[i].first?.isEmpty == true { pages[i].removeFirst() }
        while pages[i].last?.isEmpty == true { pages[i].removeLast() }
    }
}

// ── PDF ────────────────────────────────────────────────────────

let mathFonts = ["math", "cmmi", "cmsy", "cmex", "msbm", "symbol", "mt extra", "mtextra", "stix", "euclid", "mathtype",
                 "esstix", "rsfs", "lmmath", "asana"]

/// Formulas set with a font for math – a PDF breaks them apart (fractions on two lines, powers as plain digits).
/// Calculations in normal text read fine as they are.
func hasMath(_ page: PDFPage) -> Bool {
    var found = false
    if let a = page.attributedString, a.length > 0 {
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, _, stop in
            if let f = v as? NSFont, mathFonts.contains(where: { f.fontName.lowercased().contains($0) }) {
                found = true; stop.pointee = true
            }
        }
    }
    return found
}

/// Pictures on a page that are large enough to hold text (logos and icons do not count)
func pictureCount(_ page: CGPDFPage?) -> Int {
    guard let page, var dict = page.dictionary else { return 0 }
    var res: CGPDFDictionaryRef?
    while !CGPDFDictionaryGetDictionary(dict, "Resources", &res) {   // inherited from the page tree
        var parent: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Parent", &parent), let p = parent else { break }
        dict = p
    }
    guard let res else { return 0 }
    return pictures(in: res, depth: 0)
}

func pictures(in res: CGPDFDictionaryRef, depth: Int) -> Int {
    var xo: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return 0 }
    var count = 0
    CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) else { return true }
        var sub: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(sd, "Subtype", &sub), let sub else { return true }
        switch String(cString: sub) {
        case "Image":
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(sd, "Width", &w)
            CGPDFDictionaryGetInteger(sd, "Height", &h)
            if w >= 120, h >= 60, w * h >= 40_000 { count += 1 }
        case "Form" where depth < 3:
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(sd, "Resources", &r), let r { count += pictures(in: r, depth: depth + 1) }
        default: break
        }
        return true
    }, nil)
    return count
}

/// The page as a picture, about 2400 pixels on its long side
func render(_ page: PDFPage) -> CGImage? {
    let b = page.bounds(for: .mediaBox)
    let long = max(b.width, b.height)
    guard long > 0 else { return nil }
    let side = long * min(3, 2400 / long)
    return page.thumbnail(of: CGSize(width: side, height: side), for: .mediaBox)
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// Where a page draws its pictures: its content is read like a PDF viewer does (q Q cm, Do of images and forms)
final class Drawn {
    var ctm = CGAffineTransform.identity
    var saved: [CGAffineTransform] = []
    var rects: [CGRect] = []
    var depth = 0
}

func drawn(_ info: UnsafeMutableRawPointer?) -> Drawn { Unmanaged<Drawn>.fromOpaque(info!).takeUnretainedValue() }

func pdfMatrix(_ v: [CGPDFReal]) -> CGAffineTransform { CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]) }

let pdfOperators: CGPDFOperatorTableRef = {
    let t = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(t, "q") { _, info in let d = drawn(info); d.saved.append(d.ctm) }
    CGPDFOperatorTableSetCallback(t, "Q") { _, info in let d = drawn(info); if let m = d.saved.popLast() { d.ctm = m } }
    CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
        let d = drawn(info)
        d.ctm = pdfMatrix(v).concatenating(d.ctm)
    }
    CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in pdfDo(scanner, info) }
    return t
}()

func pdfDo(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    let d = drawn(info)
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    let cs = CGPDFScannerGetContentStream(scanner)
    guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
    var sub: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dict, "Subtype", &sub), let sub else { return }
    switch String(cString: sub) {
    case "Image":
        d.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(d.ctm))
    case "Form" where d.depth < 4:
        var m = CGAffineTransform.identity
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in 0..<6 { CGPDFArrayGetNumber(arr, i, &v[i]) }
            m = pdfMatrix(v)
        }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { return }   // no resources: no pictures
        let inner = CGPDFContentStreamCreateWithStream(stream, res, cs)
        let before = d.ctm, saved = d.saved
        d.ctm = m.concatenating(d.ctm)
        d.depth += 1
        let sc = CGPDFScannerCreate(inner, pdfOperators, info)
        CGPDFScannerScan(sc)
        CGPDFScannerRelease(sc)
        CGPDFContentStreamRelease(inner)
        d.depth -= 1
        d.ctm = before
        d.saved = saved
    default: break
    }
}

/// The places of the pictures on a page, in its points: big enough to show, side by side ones joined, at most 8
func pictureRects(_ page: CGPDFPage?) -> [CGRect] {
    guard let page else { return [] }
    let d = Drawn()
    let cs = CGPDFContentStreamCreateWithPage(page)
    let sc = CGPDFScannerCreate(cs, pdfOperators, Unmanaged.passUnretained(d).toOpaque())
    CGPDFScannerScan(sc)
    CGPDFScannerRelease(sc)
    CGPDFContentStreamRelease(cs)
    let box = page.getBoxRect(.mediaBox)
    var rs: [CGRect] = []
    for r in d.rects {
        let c = r.standardized.intersection(box)
        if !c.isNull, c.width >= 48, c.height >= 36, c.width * c.height >= 6000 { rs.append(c) }
    }
    var joined = true
    while joined {
        joined = false
        outer: for i in rs.indices {
            for j in rs.indices where j > i {
                let near: CGRect = rs[i].insetBy(dx: -4, dy: -4)
                if near.intersects(rs[j]) { rs[i] = rs[i].union(rs[j]); rs.remove(at: j); joined = true; break outer }
            }
        }
    }
    let ordered: [CGRect] = rs.sorted { (a: CGRect, b: CGRect) -> Bool in
        abs(a.maxY - b.maxY) > 8 ? a.maxY > b.maxY : a.minX < b.minX
    }
    return Array(ordered.prefix(8))
}

/// A part of a page as a picture, at most 1600 pixels on its long side
func crop(_ page: CGPDFPage, _ r: CGRect) -> CGImage? {
    let scale = min(3, 1600 / max(r.width, r.height))
    let w = Int(r.width * scale), h = Int(r.height * scale)
    guard w > 8, h > 8, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -r.minX, y: -r.minY)
    ctx.drawPDFPage(page)
    return ctx.makeImage()
}

/// Pictures at the same place on most pages (a logo in the header) are decoration, not content
func dropDecoration(_ rects: inout [[CGRect]], _ box: (Int) -> CGRect) {
    let n = rects.filter { !$0.isEmpty }.count
    guard n >= 3 else { return }
    func key(_ r: CGRect) -> String { "\(Int(r.minX / 4)) \(Int(r.minY / 4)) \(Int(r.width / 4)) \(Int(r.height / 4))" }
    var count: [String: Int] = [:]
    for page in rects { for k in Set(page.map(key)) { count[k, default: 0] += 1 } }
    for i in rects.indices {
        let area = box(i).width * box(i).height
        rects[i] = rects[i].filter { r in r.width * r.height > area * 0.5 || (count[key(r)] ?? 0) < max(3, (n + 1) / 2) }
    }
}

/// Words that are already in the page's text – a line read from the picture that only repeats them is left out
func repeats(_ line: String, _ words: Set<String>) -> Bool {
    let w = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { norm(String($0)) }.filter { $0.count >= 3 }
    if w.isEmpty { return norm(line).count < 3 }
    return Double(w.filter(words.contains).count) / Double(w.count) >= 0.7
}

func pdf(_ url: URL) throws -> [Unit] {
    guard let doc = PDFDocument(url: url) else { throw Fail("Das PDF lässt sich nicht öffnen") }
    if doc.isLocked { return [Unit(label: "", kind: "note", text: "[Das PDF ist mit einem Passwort geschützt]")] }
    let n = doc.pageCount
    var pages: [[String]] = [], extra: [[String]] = [], kinds: [String] = [], shown: [[String]] = []
    var places: [[CGRect]] = pictureDir == nil ? [] : (0..<n).map { pictureRects(doc.page(at: $0)?.pageRef) }
    if !places.isEmpty { dropDecoration(&places) { doc.page(at: $0)?.bounds(for: .mediaBox) ?? .zero } }
    for i in 0..<n {
        progress(i + 1, n)
        autoreleasepool {
            var marks: [String] = []
            if i < places.count, let ref = doc.page(at: i)?.pageRef {
                for r in places[i] {
                    if let img = crop(ref, r), let name = savePicture(img, n > 1 ? "S. \(i + 1)" : "", jpeg: true) {
                        marks.append(pictureMark(name, n > 1 ? "S. \(i + 1)" : ""))
                    }
                }
            }
            shown.append(marks)
            guard let page = doc.page(at: i) else { pages.append([]); extra.append([]); kinds.append("text"); return }
            let text = page.string ?? ""
            var lines = cleanLines(text), more: [String] = []
            var kind = hasMath(page) ? "math" : "text"
            let chars = lines.joined().filter { !$0.isWhitespace }.count
            if chars == 0 || pictureCount(page.pageRef) > 0, let img = render(page) {
                if chars < 40 {                                  // a scan
                    let read = cleanLines(ocr(img).joined(separator: "\n"))
                    if read.joined().count > chars * 2 { lines = read; kind = "ocr" }
                } else {                                         // text with pictures: what only the pictures say
                    let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { norm(String($0)) })
                    more = cleanLines(ocr(img, minimum: 0.5).joined(separator: "\n")).filter { $0.count >= 3 && !repeats($0, words) }
                    if !more.isEmpty, kind == "text" { kind = "pic" }
                }
            }
            pages.append(lines); extra.append(more); kinds.append(kind)
        }
    }
    dropRepeated(&pages)
    dropRepeated(&extra)
    var units: [Unit] = []
    for i in 0..<n {
        var lines = pages[i]
        // the pictures: a scan before its text, others after the text and before what was read from them
        if kinds[i] == "ocr" { lines = shown[i] + (shown[i].isEmpty ? [] : [""]) + lines }
        else if !shown[i].isEmpty { lines += (lines.isEmpty ? [] : [""]) + shown[i] }
        if !extra[i].isEmpty { lines += (lines.isEmpty ? [] : [""]) + ["[Bildtext]"] + extra[i] + [""] }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.joined().trimmingCharacters(in: .whitespaces).isEmpty { continue }
        units.append(Unit(label: n > 1 ? "S. \(i + 1)" : "", kind: kinds[i], text: lines.joined(separator: "\n")))
    }
    return units
}

// ── Pictures ───────────────────────────────────────────────────

func picture(_ url: URL) throws -> [Unit] {
    progress(1, 1)
    guard let (img, orientation) = loadImage(url) else { throw Fail("Das Bild lässt sich nicht öffnen") }
    let lines = cleanLines(ocr(img, orientation).joined(separator: "\n"))
    let mark = keepPicture(url, img, orientation, "").map { [pictureMark($0, ""), ""] } ?? []
    if lines.isEmpty { return [Unit(label: "", kind: "note", text: (mark + ["[Bild ohne lesbaren Text]"]).joined(separator: "\n"))] }
    return [Unit(label: "", kind: "ocr", text: (mark + lines).joined(separator: "\n"))]
}

// ── XML of Office files ────────────────────────────────────────

final class Node {
    let name: String
    let attrs: [String: String]
    var kids: [Node] = []
    var text = ""
    init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }
    func first(_ n: String) -> Node? { kids.first { $0.name == n } }
    func all(_ n: String) -> [Node] { kids.filter { $0.name == n } }
    /// The first node with this name below, depth first
    func find(_ n: String) -> Node? {
        for k in kids { if k.name == n { return k }; if let f = k.find(n) { return f } }
        return nil
    }
    func findAll(_ n: String) -> [Node] { kids.flatMap { ($0.name == n ? [$0] : []) + $0.findAll(n) } }
    func attr(_ key: String) -> String? { attrs[key] }
}

final class XMLTree: NSObject, XMLParserDelegate {
    let root = Node("#root", [:])
    var stack: [Node] = []
    let strip: String?
    init(strip: String?) { self.strip = strip; super.init(); stack = [root] }
    func name(_ n: String) -> String {
        if let s = strip, n.hasPrefix(s + ":") { return String(n.dropFirst(s.count + 1)) }
        return n
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let n = Node(name(e), attributes)
        stack.last!.kids.append(n)
        stack.append(n)
    }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
    func parser(_ p: XMLParser, foundCharacters s: String) { stack.last!.text += s }
}

/// An XML file of the unpacked document → its root element. strip: a prefix to leave out ("x" in some Excel files)
func xml(_ url: URL, strip: String? = nil) -> Node? {
    guard let p = XMLParser(contentsOf: url) else { return nil }
    let t = XMLTree(strip: strip)
    p.delegate = t
    p.shouldResolveExternalEntities = false
    guard p.parse() else { return nil }
    return t.root.kids.first
}

/// A .rels file → Id → path of the target, resolved against the folder of the part
func relations(_ dir: URL, part: String) -> [String: (path: URL, type: String)] {
    let partURL = dir.appendingPathComponent(part)
    let rels = partURL.deletingLastPathComponent().appendingPathComponent("_rels/\(partURL.lastPathComponent).rels")
    var out: [String: (URL, String)] = [:]
    for r in xml(rels)?.all("Relationship") ?? [] {
        guard let id = r.attr("Id"), let target = r.attr("Target"), r.attr("TargetMode") != "External" else { continue }
        let path = target.hasPrefix("/") ? dir.appendingPathComponent(String(target.dropFirst()))
                                         : partURL.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
        out[id] = (path, r.attr("Type") ?? "")
    }
    return out
}

/// Unpacks an Office file into a temporary folder for <work>
func unzipped<T>(_ url: URL, _ work: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scriba-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    p.arguments = ["-qq", "-o", url.path, "-d", dir.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus <= 1 else { throw Fail("Die Datei ist beschädigt oder kein Office-Dokument") }
    return try work(dir)
}

// ── Formulas (Office Math) → LaTeX ─────────────────────────────

let bigOperators: [String: String] = ["∑": "\\sum", "∏": "\\prod", "∫": "\\int", "∬": "\\iint", "∭": "\\iiint",
                                      "∮": "\\oint", "⋃": "\\bigcup", "⋂": "\\bigcap"]
let functions: Set<String> = ["sin", "cos", "tan", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log",
                              "ln", "lg", "exp", "lim", "max", "min", "det", "gcd"]

func math(_ n: Node?) -> String { (n?.kids ?? []).map(mathNode).joined() }

/// One letter or number stays as it is, more get braces
func group(_ s: String) -> String { s.count <= 1 || s.allSatisfy({ $0.isNumber }) ? s : "{\(s)}" }

func mathNode(_ n: Node) -> String {
    let pr = n.first("m:\(n.name.dropFirst(2))Pr")
    func prop(_ key: String) -> String? { pr?.first("m:\(key)")?.attr("m:val") }
    switch n.name {
    case "m:r":
        return n.findAll("m:t").map(\.text).joined() + n.findAll("w:t").map(\.text).joined()
    case "m:f":
        let num = math(n.first("m:num")), den = math(n.first("m:den"))
        switch prop("type") {
        case "lin": return "\(group(num))/\(group(den))"
        case "noBar": return "\\binom{\(num)}{\(den)}"
        default: return "\\frac{\(num)}{\(den)}"
        }
    case "m:sSup": return group(math(n.first("m:e"))) + "^{" + math(n.first("m:sup")) + "}"
    case "m:sSub": return group(math(n.first("m:e"))) + "_{" + math(n.first("m:sub")) + "}"
    case "m:sSubSup":
        return group(math(n.first("m:e"))) + "_{" + math(n.first("m:sub")) + "}^{" + math(n.first("m:sup")) + "}"
    case "m:sPre": return "{}_{" + math(n.first("m:sub")) + "}^{" + math(n.first("m:sup")) + "}" + math(n.first("m:e"))
    case "m:rad":
        let deg = math(n.first("m:deg")), e = math(n.first("m:e"))
        return deg.isEmpty ? "\\sqrt{\(e)}" : "\\sqrt[\(deg)]{\(e)}"
    case "m:d":
        func chr(_ key: String, _ standard: String) -> String {
            guard let pr, let c = pr.first("m:\(key)") else { return standard }
            let v = c.attr("m:val") ?? ""
            return v == "{" ? "\\{" : v == "}" ? "\\}" : v
        }
        return chr("begChr", "(") + n.all("m:e").map(math).joined(separator: chr("sepChr", "|")) + chr("endChr", ")")
    case "m:nary":
        let op = prop("chr") ?? "∫"
        var s = bigOperators[op] ?? op
        let sub = math(n.first("m:sub")), sup = math(n.first("m:sup"))
        if !sub.isEmpty { s += "_{\(sub)}" }
        if !sup.isEmpty { s += "^{\(sup)}" }
        return s + " " + math(n.first("m:e"))
    case "m:func":
        let name = math(n.first("m:fName")).trimmingCharacters(in: .whitespaces)
        return (functions.contains(name) ? "\\\(name)" : name) + " " + math(n.first("m:e"))
    case "m:limLow":
        let e = math(n.first("m:e")).trimmingCharacters(in: .whitespaces)
        return (functions.contains(e) ? "\\\(e)" : group(e)) + "_{" + math(n.first("m:lim")) + "}"
    case "m:limUpp": return group(math(n.first("m:e"))) + "^{" + math(n.first("m:lim")) + "}"
    case "m:acc":
        let e = math(n.first("m:e"))
        switch prop("chr") ?? "\u{0302}" {
        case "\u{0302}": return "\\hat{\(e)}"
        case "\u{0304}", "\u{0305}", "¯": return "\\bar{\(e)}"
        case "\u{20D7}", "\u{20D1}": return "\\vec{\(e)}"
        case "\u{0307}": return "\\dot{\(e)}"
        case "\u{0303}": return "\\tilde{\(e)}"
        default: return e
        }
    case "m:bar": return (prop("pos") == "bot" ? "\\underline{" : "\\overline{") + math(n.first("m:e")) + "}"
    case "m:groupChr":
        let e = math(n.first("m:e"))
        return prop("chr") == "⏞" ? "\\overbrace{\(e)}" : "\\underbrace{\(e)}"
    case "m:eqArr": return "\\begin{aligned}" + n.all("m:e").map(math).joined(separator: " \\\\ ") + "\\end{aligned}"
    case "m:m":
        let rows = n.all("m:mr").map { $0.all("m:e").map(math).joined(separator: " & ") }
        return "\\begin{pmatrix}" + rows.joined(separator: " \\\\ ") + "\\end{pmatrix}"
    case "m:t": return n.text
    default:
        if n.name.hasSuffix("Pr") { return "" }
        return math(n)
    }
}

/// A formula: inline $…$, a formula on its own line $$…$$
func formula(_ n: Node) -> String {
    let parts = (n.name == "m:oMathPara" ? n.all("m:oMath") : [n]).map { math($0).trimmingCharacters(in: .whitespaces) }
    return n.name == "m:oMathPara" ? parts.map { "$$\($0)$$" }.joined(separator: "\n") : "$\(parts.joined())$"
}

// ── Markdown tables ────────────────────────────────────────────

func table(_ rows: [[String]]) -> [String] {
    let rows = rows.filter { $0.contains { !$0.isEmpty } }
    guard let cols = rows.map(\.count).max(), cols > 0 else { return [] }
    if cols == 1 { return rows.map { $0[0] } }
    let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
    var out: [String] = []
    for (i, r) in rows.enumerated() {
        let padded = r + Array(repeating: "", count: cols - r.count)
        out.append("| " + padded.map(cell).joined(separator: " | ") + " |")
        if i == 0 { out.append("|" + Array(repeating: "---", count: cols).joined(separator: "|") + "|") }
    }
    return out
}

// ── Word ───────────────────────────────────────────────────────

final class WordReader {
    let dir: URL
    let rels: [String: (path: URL, type: String)]
    var units: [Unit] = []
    var lines: [String] = []
    var page = 1, broke = false, pending = false, pictures = false

    init(_ dir: URL) {
        self.dir = dir
        rels = relations(dir, part: "word/document.xml")
    }

    func read() throws -> [Unit] {
        guard let doc = xml(dir.appendingPathComponent("word/document.xml")), let body = doc.find("w:body") else {
            throw Fail("Das Word-Dokument lässt sich nicht lesen")
        }
        progress(1, 1)
        body.kids.forEach(block)
        newPage()
        if !broke, units.count == 1 { units[0].label = "" }
        return units
    }

    func newPage() {
        while lines.last?.isEmpty == true { lines.removeLast() }
        if !lines.isEmpty {
            units.append(Unit(label: "S. \(page)", kind: pictures ? "pic" : "text", text: lines.joined(separator: "\n")))
        }
        lines = []; pictures = false; page += 1
    }

    func add(_ s: String) {
        if s.isEmpty { if let l = lines.last, !l.isEmpty { lines.append("") }; return }
        lines.append(s)
    }

    func block(_ n: Node) {
        switch n.name {
        case "w:p": paragraph(n)
        case "w:tbl": tableLines(n).forEach(add); add("")
        case "w:sdt": n.first("w:sdtContent")?.kids.forEach(block)
        case "w:customXml", "w:smartTag", "w:ins": n.kids.forEach(block)
        case "m:oMathPara": add(formula(n))
        default: break
        }
    }

    func paragraph(_ p: Node, plain: Bool = false) {
        var prefix = ""
        if !plain, let ppr = p.first("w:pPr") {
            let style = (ppr.first("w:pStyle")?.attr("w:val") ?? "").lowercased()
            if style.hasPrefix("title") || style.hasPrefix("titel") { prefix = "## " }
            else if let r = style.range(of: #"^(heading|berschrift|überschrift|kop|titre)\s*(\d)"#, options: .regularExpression),
                    let d = Int(String(style[r].last!)) {
                prefix = String(repeating: "#", count: min(d + 1, 4)) + " "
            } else if let num = ppr.first("w:numPr"), num.first("w:numId")?.attr("w:val") != "0" {
                let level = Int(num.first("w:ilvl")?.attr("w:val") ?? "0") ?? 0
                prefix = String(repeating: "  ", count: min(level, 4)) + "- "
            }
        }
        var s = "", after: [String] = []
        inline(p, &s, &after)
        let text = codeTags(s.trimmingCharacters(in: .whitespaces))
        if !text.isEmpty {
            add(prefix.hasPrefix("#") ? prefix + text.replacingOccurrences(of: "\n", with: " ") : prefix + text)
            if prefix.hasPrefix("#") || prefix.isEmpty { add("") }
        }
        after.forEach(add)
        if pending { pending = false; newPage() }
    }

    func inline(_ n: Node, _ s: inout String, _ after: inout [String]) {
        for k in n.kids {
            switch k.name {
            case "w:t": s += k.text
            case "w:tab", "w:ptab": s += " "
            case "w:br":
                if k.attr("w:type") == "page" { pageBreak(s) } else if k.attr("w:type") != "column" { s += "\n" }
            case "w:cr": s += "\n"
            case "w:lastRenderedPageBreak": pageBreak(s)
            case "w:noBreakHyphen": s += "-"
            case "w:sym": if let c = k.attr("w:char"), let v = UInt32(c, radix: 16), v < 0xF000, let u = Unicode.Scalar(v) { s += String(u) }
            case "w:instrText", "w:delText", "w:del", "w:fldChar", "w:pPr", "w:rPr", "mc:Fallback", "w:moveFrom": break
            case "m:oMath": s += formula(k)
            case "m:oMathPara":
                if !s.trimmingCharacters(in: .whitespaces).isEmpty { s += "\n" }
                s += formula(k)
            case "w:drawing", "w:pict", "w:object":
                after += pictureOf(k)
                for box in k.findAll("w:txbxContent") { after += boxLines(box) }
            case "w:txbxContent": after += boxLines(k)
            default: inline(k, &s, &after)
            }
        }
    }

    /// A page break: before this paragraph when nothing of it was written yet, otherwise after it
    func pageBreak(_ s: String) {
        broke = true
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { newPage() } else { pending = true }
    }

    func pictureOf(_ n: Node) -> [String] {
        if let ole = n.find("o:OLEObject"), (ole.attr("ProgID") ?? "").contains("Equation") {
            return ["[Formel als Bild – nicht lesbar]"]
        }
        let id = n.find("a:blip")?.attr("r:embed") ?? n.find("v:imagedata")?.attr("r:id")
        guard let id, let target = rels[id] else { return [] }
        let lines = pictureLines(target.path, "")
        if lines.contains("[Bildtext]") { pictures = true }
        return lines
    }

    func boxLines(_ box: Node) -> [String] {
        let saved = lines
        lines = []
        for p in box.kids { if p.name == "w:p" { paragraph(p, plain: true) } else if p.name == "w:tbl" { tableLines(p).forEach(add) } }
        let out = lines.filter { !$0.isEmpty }
        lines = saved
        return out.isEmpty ? [] : out + [""]
    }

    func tableLines(_ t: Node) -> [String] {
        var rows: [[String]] = []
        for tr in t.all("w:tr") {
            var cells: [String] = []
            for tc in tr.kids where tc.name == "w:tc" || tc.name == "w:sdt" {
                let c = tc.name == "w:sdt" ? (tc.find("w:tc") ?? tc) : tc
                var parts: [String] = []
                for b in c.findAll("w:p") {
                    var s = "", after: [String] = []
                    inline(b, &s, &after)
                    let t = codeTags(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !t.isEmpty { parts.append(t) }
                    parts += after.filter { $0 != "[Bild]" && !$0.isEmpty }
                }
                cells.append(parts.joined(separator: "<br>"))
                let span = Int(c.first("w:tcPr")?.first("w:gridSpan")?.attr("w:val") ?? "1") ?? 1
                if span > 1 { cells += Array(repeating: "", count: span - 1) }
            }
            rows.append(cells)
        }
        return table(rows)
    }
}

// ── PowerPoint ─────────────────────────────────────────────────

func pptx(_ dir: URL) throws -> [Unit] {
    guard let pres = xml(dir.appendingPathComponent("ppt/presentation.xml")) else {
        throw Fail("Die PowerPoint-Datei lässt sich nicht lesen")
    }
    let rels = relations(dir, part: "ppt/presentation.xml")
    let ids = pres.find("p:sldIdLst")?.all("p:sldId").compactMap { $0.attr("r:id") } ?? []
    var units: [Unit] = []
    for (i, id) in ids.enumerated() {
        progress(i + 1, ids.count)
        guard let target = rels[id], let slide = xml(target.path) else { continue }
        let part = target.path.path.replacingOccurrences(of: dir.path + "/", with: "")
        let srels = relations(dir, part: part)
        var lines: [String] = [], read = false
        slideLabel = "Folie \(i + 1)"
        autoreleasepool {
            if let tree = slide.find("p:spTree") { shapes(tree, &lines, &read, srels) }
            // the speaker's notes often explain the slide
            if let notes = srels.values.first(where: { $0.type.hasSuffix("/notesSlide") }), let n = xml(notes.path) {
                var said: [String] = []
                for sp in n.findAll("p:sp") where sp.find("p:ph")?.attr("type") == "body" {
                    said += paragraphs(sp.first("p:txBody"), bullets: false)
                }
                let t = said.filter { !$0.isEmpty }
                if !t.isEmpty { lines += ["Notizen: " + t.joined(separator: " ")] }
            }
        }
        if lines.isEmpty { continue }
        while lines.last?.isEmpty == true { lines.removeLast() }
        units.append(Unit(label: "Folie \(i + 1)", kind: read ? "pic" : "text", text: lines.joined(separator: "\n")))
    }
    return units
}

var slideLabel = ""

func shapes(_ n: Node, _ out: inout [String], _ read: inout Bool, _ rels: [String: (path: URL, type: String)]) {
    for k in n.kids {
        switch k.name {
        case "p:sp":
            let ph = k.find("p:ph"), type = ph?.attr("type") ?? (ph == nil ? "" : "body")
            if ["sldNum", "dt", "ftr", "hdr"].contains(type) { continue }
            let title = type == "title" || type == "ctrTitle"
            let lines = paragraphs(k.first("p:txBody"), bullets: type == "body" || type == "obj")
            if title, !lines.isEmpty { out.append("## " + lines.joined(separator: " ")) } else { out += lines }
        case "p:grpSp": shapes(k, &out, &read, rels)
        case "mc:AlternateContent": if let c = k.first("mc:Choice") { shapes(c, &out, &read, rels) }
        case "p:graphicFrame":
            if let t = k.find("a:tbl") {
                out += table(t.all("a:tr").map { tr in
                    tr.all("a:tc").map { paragraphs($0.first("a:txBody"), bullets: false).filter { !$0.isEmpty }.joined(separator: "<br>") }
                })
            } else if k.find("c:chart") != nil {
                out.append("[Diagramm]")
            }
        case "p:pic":
            if let id = k.find("a:blip")?.attr("r:embed"), let target = rels[id] {
                let lines = pictureLines(target.path, slideLabel)
                if lines.contains("[Bildtext]") { read = true }
                out += lines
            }
        default: break
        }
    }
}

/// The paragraphs of a text body as lines – bullets with "- ", indented by their level
func paragraphs(_ body: Node?, bullets: Bool) -> [String] {
    guard let body else { return [] }
    var out: [String] = []
    for p in body.all("a:p") {
        var s = ""
        runs(p, &s)
        let t = codeTags(s.trimmingCharacters(in: .whitespaces))
        if t.isEmpty { continue }
        let ppr = p.first("a:pPr")
        let level = Int(ppr?.attr("lvl") ?? "0") ?? 0
        let marked = ppr?.first("a:buChar") != nil || ppr?.first("a:buAutoNum") != nil
        let bullet = ppr?.first("a:buNone") == nil && (bullets || marked)
        out.append(bullet ? String(repeating: "  ", count: min(level, 4)) + "- " + t : t)
    }
    return out
}

func runs(_ n: Node, _ s: inout String) {
    for k in n.kids {
        switch k.name {
        case "a:t": s += k.text
        case "a:br": s += "\n"
        case "a:fld": if k.attr("type") != "slidenum" { s += k.find("a:t")?.text ?? "" }
        case "m:oMath", "m:oMathPara": s += (k.name == "m:oMathPara" ? " " : "") + formula(k)
        case "a:pPr", "a:rPr", "a:endParaRPr", "mc:Fallback": break
        default: runs(k, &s)
        }
    }
}

// ── Excel ──────────────────────────────────────────────────────

func xlsx(_ dir: URL) throws -> [Unit] {
    guard let wb = xml(dir.appendingPathComponent("xl/workbook.xml"), strip: "x") else {
        throw Fail("Die Excel-Datei lässt sich nicht lesen")
    }
    let rels = relations(dir, part: "xl/workbook.xml")
    let shared: [String] = (xml(dir.appendingPathComponent("xl/sharedStrings.xml"), strip: "x")?.all("si") ?? []).map { si in
        si.kids.flatMap { k -> [String] in
            k.name == "t" ? [k.text] : k.name == "r" ? k.all("t").map(\.text) : []
        }.joined()
    }
    let dates = dateStyles(dir)
    let sheets = wb.find("sheets")?.all("sheet") ?? []
    var units: [Unit] = []
    for (i, sheet) in sheets.enumerated() {
        progress(i + 1, sheets.count)
        guard let id = sheet.attr("r:id"), let target = rels[id], let ws = xml(target.path, strip: "x") else { continue }
        var grid: [Int: [Int: String]] = [:], formulas = false
        var maxCol = 0, minCol = Int.max
        for row in ws.find("sheetData")?.all("row") ?? [] {
            let r = Int(row.attr("r") ?? "") ?? (grid.keys.max() ?? 0) + 1
            if r > 400 { break }
            var next = 1
            for c in row.all("c") {
                let col = c.attr("r").map(column) ?? next
                next = col + 1
                if col > 40 { continue }
                var v = c.first("v")?.text ?? ""
                switch c.attr("t") {
                case "s": v = Int(v).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "inlineStr": v = c.find("is")?.findAll("t").map(\.text).joined() ?? ""
                case "b": v = v == "1" ? "WAHR" : "FALSCH"
                case "str", "e": break
                default: v = number(v, date: dates.contains(Int(c.attr("s") ?? "0") ?? 0))
                }
                let f = c.first("f")?.text ?? ""
                if !f.isEmpty { v = v.isEmpty ? "=\(f)" : "\(v) (=\(f))"; formulas = true }
                v = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty { continue }
                grid[r, default: [:]][col] = v
                maxCol = max(maxCol, col); minCol = min(minCol, col)
            }
        }
        if grid.isEmpty { continue }
        var rows: [[String]] = []
        // with formulas Claude needs the cell names: a row of column letters, the row numbers in front
        if formulas { rows.append([""] + (minCol...maxCol).map(letters)) }
        for r in grid.keys.sorted() {
            let cells = (minCol...maxCol).map { grid[r]?[$0] ?? "" }
            rows.append(formulas ? ["\(r)"] + cells : cells)
        }
        let name = sheet.attr("name") ?? "\(i + 1)"
        units.append(Unit(label: sheets.count > 1 ? "Blatt \(name)" : "", kind: "text", text: table(rows).joined(separator: "\n")))
    }
    return units
}

func column(_ ref: String) -> Int { ref.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } }
func letters(_ n: Int) -> String { n <= 0 ? "" : letters((n - 1) / 26) + String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) }

func number(_ v: String, date: Bool) -> String {
    guard let d = Double(v) else { return v }
    if date, d > 0, d < 2_958_466 {
        let day = Date(timeIntervalSince1970: (d - 25569) * 86400)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = d.truncatingRemainder(dividingBy: 1) == 0 ? "dd.MM.yyyy" : d < 1 ? "HH:mm" : "dd.MM.yyyy HH:mm"
        return f.string(from: day)
    }
    if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
    return String(format: "%.10g", d)
}

/// The cell styles that show a date or a time
func dateStyles(_ dir: URL) -> Set<Int> {
    guard let st = xml(dir.appendingPathComponent("xl/styles.xml"), strip: "x") else { return [] }
    var custom: [Int: String] = [:]
    for f in st.find("numFmts")?.all("numFmt") ?? [] {
        if let id = Int(f.attr("numFmtId") ?? ""), let code = f.attr("formatCode") { custom[id] = code }
    }
    func isDate(_ id: Int) -> Bool {
        if (14...22).contains(id) || (45...47).contains(id) { return true }
        guard let code = custom[id]?.lowercased() else { return false }
        let bare = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]"#, with: "", options: .regularExpression)
        return bare.contains("yy") || bare.contains("dd") || bare.contains("mmm") || bare.contains("h:")
    }
    var out = Set<Int>()
    for (i, xf) in (st.find("cellXfs")?.all("xf") ?? []).enumerated() {
        if isDate(Int(xf.attr("numFmtId") ?? "0") ?? 0) { out.insert(i) }
    }
    return out
}

// ── Notebooks, rich text, plain text and code ─────────────────

let codeLanguages: [String: String] = [
    "java": "java", "py": "python", "js": "javascript", "mjs": "javascript", "ts": "typescript", "jsx": "jsx", "tsx": "tsx",
    "html": "html", "htm": "html", "css": "css", "scss": "scss", "c": "c", "h": "c", "cpp": "cpp", "hpp": "cpp", "cs": "csharp",
    "sql": "sql", "sh": "bash", "zsh": "zsh", "bash": "bash", "ps1": "powershell", "bat": "bat", "php": "php", "kt": "kotlin",
    "swift": "swift", "go": "go", "rs": "rust", "rb": "ruby", "vb": "vb", "vbs": "vb", "r": "r", "pl": "perl", "lua": "lua",
    "dart": "dart", "json": "json", "xml": "xml", "yml": "yaml", "yaml": "yaml", "ini": "ini", "toml": "toml", "m": "matlab",
]

func readText(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
    if let s = String(data: data, encoding: .windowsCP1252) { return s }
    return String(decoding: data, as: UTF8.self)
}

func plain(_ url: URL, _ ext: String) throws -> [Unit] {
    progress(1, 1)
    var lines = try readText(url).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    var cut = ""
    if lines.count > 3000 { cut = "\n[… \(lines.count - 3000) weitere Zeilen weggelassen]"; lines = Array(lines.prefix(3000)) }
    if let lang = codeLanguages[ext] {
        return [Unit(label: "", kind: "code", text: "```\(lang)\n" + lines.joined(separator: "\n") + "\n```" + cut)]
    }
    return [Unit(label: "", kind: "text", text: cleanLines(lines.joined(separator: "\n")).joined(separator: "\n") + cut)]
}

func notebook(_ url: URL) throws -> [Unit] {
    progress(1, 1)
    guard let nb = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
          let cells = nb["cells"] as? [[String: Any]] else { throw Fail("Das Notebook lässt sich nicht lesen") }
    let lang = ((nb["metadata"] as? [String: Any])?["kernelspec"] as? [String: Any])?["language"] as? String ?? "python"
    func source(_ v: Any?) -> String { (v as? [String])?.joined() ?? (v as? String) ?? "" }
    var out: [String] = []
    for c in cells {
        let src = source(c["source"]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch c["cell_type"] as? String {
        case "markdown": if !src.isEmpty { out.append(src) }
        case "code":
            if !src.isEmpty { out.append("```\(lang)\n\(src)\n```") }
            var shown: [String] = []
            for o in c["outputs"] as? [[String: Any]] ?? [] {
                shown.append(source(o["text"]))
                shown.append(source((o["data"] as? [String: Any])?["text/plain"]))
            }
            let res = shown.joined().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").prefix(30)
            if !res.joined().isEmpty { out.append("Ausgabe:\n```\n" + res.joined(separator: "\n") + "\n```") }
        default: break
        }
    }
    return [Unit(label: "", kind: "code", text: out.joined(separator: "\n\n"))]
}

/// .doc, .rtf, .odt – macOS reads them itself
func rich(_ url: URL) throws -> [Unit] {
    progress(1, 1)
    let s = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
    return [Unit(label: "", kind: "text", text: cleanLines(s).joined(separator: "\n"))]
}

// ── Main ───────────────────────────────────────────────────────

let args = CommandLine.arguments
if args.count == 2, args[1] == "--version" { print("scriba-extract 1"); exit(0) }
guard args.count == 3 || args.count == 4 else { print("error usage: scriba-extract <file> <out> [<pictures>]"); exit(2) }
let file = URL(fileURLWithPath: args[1]), outFile = URL(fileURLWithPath: args[2])
if args.count == 4 { pictureDir = URL(fileURLWithPath: args[3]) }
let ext = file.pathExtension.lowercased()
do {
    let units: [Unit]
    switch ext {
    case "pdf": units = try pdf(file)
    case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp": units = try picture(file)
    case "docx", "docm", "dotx", "dotm": units = try unzipped(file) { try WordReader($0).read() }
    case "pptx", "pptm", "ppsx", "potx": units = try unzipped(file) { try pptx($0) }
    case "xlsx", "xlsm", "xltx": units = try unzipped(file) { try xlsx($0) }
    case "ipynb": units = try notebook(file)
    case "doc", "rtf", "odt", "wordml": units = try rich(file)
    default: units = try plain(file, ext)
    }
    var out = ""
    for u in units where !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out += "\u{1E}\(u.label)\u{1F}\(u.kind)\n\(u.text)\n"
    }
    try out.write(to: outFile, atomically: true, encoding: .utf8)
    if ocrHung { exit(3) }
} catch {
    print("error \(error)")
    exit(1)
}
