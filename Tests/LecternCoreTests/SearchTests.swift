import XCTest
@testable import LecternCore

final class LibrarySearchTests: XCTestCase {
    var root: URL!
    var library: Library!
    var session: Session!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        library = Library(root: root)
        let course = Course(id: "GORU", name: "Vision", language: "tr")
        try library.save(course)
        session = try library.lectureSession(course: course, date: Date(timeIntervalSince1970: 1_800_000_000), week: 6)
        let folder = library.folder(of: session)
        try "# Geri yayılım\n\n- **Zincir kuralı:** türevleri çarpar\n- Öğrenme katsayısı \\(\\eta\\)\n"
            .write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "[00:00:00]\nBugün başlıyoruz.\n\n[00:05:00]\nZincir kuralı ile ağırlığı güncelleriz.\n"
            .write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try LectureChat.save([ChatEntry(role: .user, text: "Öğrenme katsayısı ne işe yarar?")], in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsInEveryFileIgnoringCaseAndTurkishLetters() {
        let hits = LibrarySearch.search("ZINCIR kurali", in: [session], library: library)
        XCTAssertEqual(hits.map(\.source), [.notes, .transcript])
        XCTAssertEqual(hits[0].snippet, "Zincir kuralı: türevleri çarpar")
        XCTAssertEqual(hits[1].time, 300)
        XCTAssertNil(hits[0].time)

        let learning = LibrarySearch.search("ogrenme", in: [session], library: library)
        XCTAssertEqual(learning.map(\.source), [.notes, .chat])
    }

    func testEveryWordHasToBeOnTheLine() {
        XCTAssertEqual(LibrarySearch.search("zincir bugün", in: [session], library: library), [])
        XCTAssertEqual(LibrarySearch.search("a", in: [session], library: library), [])
    }

    func testLongLinesAreCutAroundTheMatch() {
        let line = String(repeating: "önce ", count: 40) + "hedef kelime " + String(repeating: "sonra ", count: 40)
        let snippet = LibrarySearch.snippet(line, around: "hedef")
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("hedef kelime"))
        XCTAssertLessThanOrEqual(snippet.count, 142)
    }

    func testStampsAreReadOnlyWhenTheyAreWholeLines() {
        XCTAssertEqual(LibrarySearch.stampTime("[01:02:03]"), 3723)
        XCTAssertNil(LibrarySearch.stampTime("[01:02]"))
        XCTAssertNil(LibrarySearch.stampTime("bkz. [00:01:00] sonra"))
    }
}
