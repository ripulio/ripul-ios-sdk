import XCTest
import UniformTypeIdentifiers
@testable import RipulAgent

/// The composer's file rules, which mirror the web's
/// (chrome-extension/src/utils/attachmentFileTypes.test.ts).
final class FileAttachmentHelperTests: XCTestCase {
    private let word = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private let powerPoint = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    private let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testSendsEachFileAsTheTypeTheUploadEndpointKnows() {
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Report.pdf"), "application/pdf")
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Notes.docx"), word)
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Deck.pptx"), powerPoint)
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Old rota.doc"), "application/msword")
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Old deck.PPT"), "application/vnd.ms-powerpoint")
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "Budget.xlsx"), xlsx)
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "data.csv"), "text/csv")
        XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: "README.md"), "text/markdown")
        for code in ["main.ts", "App.swift", "config.JSON", "Analysis.ipynb", "server.log", ".env"] {
            XCTAssertEqual(FileAttachmentHelper.mediaType(forFileNamed: code), "text/plain", code)
        }
        for refused in ["logo.svg", "site.zip", "clip.mov", "Talk.key"] {
            XCTAssertNil(FileAttachmentHelper.mediaType(forFileNamed: refused), refused)
        }
    }

    func testCeilings() {
        let megabyte = 1024 * 1024
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: "application/pdf"), 20 * megabyte)
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: word), 20 * megabyte)
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: "application/msword"), 10 * megabyte)
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: "application/vnd.ms-powerpoint"), 20 * megabyte)
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: xlsx), 2 * megabyte)
        XCTAssertEqual(FileAttachmentHelper.maxBytes(for: "text/plain"), 10 * megabyte)
    }

    func testReadsAChosenFileUnderItsOwnName() throws {
        let attachment = try FileAttachmentHelper.attachment(fromFileAt: file("main.swift", Data("print(1)".utf8)))
        XCTAssertEqual(attachment.mediaType, "text/plain")
        XCTAssertEqual(attachment.name, "main.swift")
        XCTAssertEqual(Data(base64Encoded: attachment.data), Data("print(1)".utf8))
        XCTAssertFalse(attachment.isImage)
        XCTAssertEqual(attachment.toDictionary()["name"], "main.swift")
    }

    func testAnImageFileIsResizedLikeAPhoto() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let attachment = try FileAttachmentHelper.attachment(fromFileAt: file("pixel.png", png))
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.mediaType, "image/jpeg")
        XCTAssertNil(attachment.toDictionary()["name"])
    }

    func testRefusesWhatCannotBeSentAndSaysWhy() throws {
        func reason(_ name: String, _ bytes: Data) throws -> String {
            do {
                _ = try FileAttachmentHelper.attachment(fromFileAt: file(name, bytes))
                return "attached"
            } catch {
                return error.localizedDescription
            }
        }
        XCTAssertTrue(try reason("site.zip", Data("PK".utf8)).contains("can't be attached"))
        XCTAssertEqual(try reason("empty.txt", Data()), "empty.txt is empty.")
        XCTAssertTrue(try reason("Budget.xlsx", Data(count: 2 * 1024 * 1024 + 1)).contains("larger than 2 MB"))
    }

    func testThePickerOffersCodeFilesOnce() {
        let identifiers = FileAttachmentHelper.allowedContentTypes.map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.contains(UTType.pdf.identifier))
        if let swift = UTType(filenameExtension: "swift") { XCTAssertTrue(identifiers.contains(swift.identifier)) }
    }

    func testADraftFileComesBackWithItsNameAndSymbol() {
        let thumbnail = FileAttachmentHelper.thumbnail(for: "application/pdf", name: "Report.pdf")
        XCTAssertGreaterThan(thumbnail.size.width, 0)
        XCTAssertEqual(FileAttachmentHelper.symbolName(for: xlsx, name: "Budget.xlsx"), "tablecells")
        XCTAssertEqual(FileAttachmentHelper.symbolName(for: "text/plain", name: "main.swift"), "chevron.left.forwardslash.chevron.right")
    }
}
