import Foundation
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Files other than photos attached in the composer: PDFs, Word and
/// PowerPoint files, spreadsheets, and text or code files.
///
/// The rules mirror the web's (chrome-extension/src/utils/attachmentFileTypes.ts)
/// and the upload endpoint's ceilings (packages/api/src/files/handlers.ts):
/// change them together. A file is sent as the type the upload endpoint knows
/// it by, and code goes as text/plain whatever the system calls it, because
/// platforms disagree (a .ts file is MPEG video to some). The bytes go to the
/// page as base64; it uploads them to Ripul's file store, and a Claude Code
/// chat's Mac saves the file under its own name for the agent
/// (ripul-native-app/macOS/AttachedFiles.swift).
public enum FileAttachmentHelper {
    static let word = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let powerPoint = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    /// Word and PowerPoint 97-2003: the upload endpoint reads their text (files/legacyWord.ts, files/legacyPowerPoint.ts).
    static let legacyWord = "application/msword"
    static let legacyPowerPoint = "application/vnd.ms-powerpoint"
    static let spreadsheets = [
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls": "application/vnd.ms-excel",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
    ]
    /// Text files that keep a type of their own.
    static let namedText = ["csv": "text/csv", "tsv": "text/tab-separated-values", "md": "text/markdown", "markdown": "text/markdown"]
    /// Sent as text/plain whatever type the system reports.
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "xml", "ini", "cfg", "conf", "env",
        "html", "htm", "css", "scss", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "gradle", "go", "rs", "py",
        "rb", "php", "pl", "lua", "r", "dart", "scala", "sh", "bash", "zsh", "fish", "ps1", "sql", "graphql", "gql",
        "proto", "tex", "diff", "patch", "ipynb", "srt", "vtt", "rtf",
    ]

    /// What the Files picker offers: broad families, plus the system's type
    /// for each code extension, so a .swift or .ipynb file can be chosen.
    public static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .tabSeparatedText, .spreadsheet, .presentation]
        let documents = ["org.openxmlformats.wordprocessingml.document", "org.openxmlformats.presentationml.presentation",
                         "com.microsoft.word.doc", "com.microsoft.powerpoint.ppt",
                         "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "org.oasis-open.opendocument.spreadsheet",
                         "net.daringfireball.markdown"]
        types += documents.compactMap { UTType($0) }
        types += textExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    /// What follows a name's last dot, as the web reads it: ".env" is an env
    /// file, though Foundation gives it no extension.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// The type a file other than an image is sent as, or nil when it cannot be attached.
    public static func mediaType(forFileNamed name: String) -> String? {
        let ext = fileExtension(name)
        switch ext {
        case "svg": return nil // text, but scriptable: refused, as on the web
        case "pdf": return "application/pdf"
        case "docx": return word
        case "pptx": return powerPoint
        case "doc": return legacyWord
        case "ppt": return legacyPowerPoint
        default: break
        }
        if let type = spreadsheets[ext] ?? namedText[ext] { return type }
        if textExtensions.contains(ext) { return "text/plain" }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .text) { return "text/plain" }
        return nil
    }

    /// Largest file of a type. As the upload endpoint allows, except that a
    /// document stops at 20 MB here: its base64 copy is handed to the page,
    /// and a larger one risks the page's memory on a phone.
    public static func maxBytes(for mediaType: String) -> Int {
        if mediaType == "application/pdf" || mediaType == word || mediaType == powerPoint || mediaType == legacyPowerPoint { return 20 * 1024 * 1024 }
        // An old Word file is parsed whole on the server, which takes 10 MB at most.
        if mediaType == legacyWord { return 10 * 1024 * 1024 }
        if spreadsheets.values.contains(mediaType) { return 2 * 1024 * 1024 }
        return 10 * 1024 * 1024
    }

    /// Why a chosen file was not attached.
    public struct Refusal: LocalizedError {
        public let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Read a file chosen in the Files picker (or dropped) into an attachment.
    /// An image goes through the photo path, so it is resized like a photo.
    public static func attachment(fromFileAt url: URL) throws -> NativeImageAttachment {
        let name = url.lastPathComponent
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), !type.conforms(to: .svg) {
            guard let attachment = PhotoAttachmentHelper.makeAttachment(from: try Data(contentsOf: url)) else {
                throw Refusal("\(name) isn't an image this app can read.")
            }
            return attachment
        }
        guard let mediaType = mediaType(forFileNamed: name) else {
            throw Refusal("\(name) can't be attached. PDFs, Word and PowerPoint files, spreadsheets, and text or code files can.")
        }
        let limit = maxBytes(for: mediaType)
        let tooLarge = Refusal("\(name) is larger than \(limit / 1024 / 1024) MB, the most this app sends. Put it on the Mac and give the agent its path.")
        // The size on disk is checked before the file is read into memory.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { throw tooLarge }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw Refusal("\(name) is empty.") }
        guard data.count <= limit else { throw tooLarge }
        return NativeImageAttachment(id: "file_\(UUID().uuidString)", mediaType: mediaType, data: data.base64EncodedString(),
                                     thumbnail: thumbnail(for: mediaType, name: name), name: name)
    }

    /// The symbol shown for a file in the composer.
    public static func symbolName(for mediaType: String, name: String?) -> String {
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType == word || mediaType == legacyWord { return "doc.text" }
        if mediaType == powerPoint || mediaType == legacyPowerPoint { return "rectangle.on.rectangle" }
        if spreadsheets.values.contains(mediaType) || mediaType == "text/csv" || mediaType == "text/tab-separated-values" { return "tablecells" }
        let ext = fileExtension(name ?? "")
        if ext.isEmpty || ["txt", "text", "log", "md", "markdown", "rtf"].contains(ext) { return "doc.plaintext" }
        return "chevron.left.forwardslash.chevron.right"
    }

    /// A file's thumbnail: its symbol, since a file has no picture of its own.
    public static func thumbnail(for mediaType: String, name: String? = nil) -> PlatformImage {
        #if os(iOS)
        return UIImage(systemName: symbolName(for: mediaType, name: name)) ?? UIImage()
        #elseif os(macOS)
        return NSImage(systemSymbolName: symbolName(for: mediaType, name: name), accessibilityDescription: nil) ?? NSImage()
        #endif
    }
}
