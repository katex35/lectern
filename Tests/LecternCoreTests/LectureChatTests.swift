import XCTest
@testable import LecternCore

final class LectureChatTests: XCTestCase {
    let session = Session(id: "s", kind: .lecture, courseID: "GORU", title: "s", date: Date())
    let course = Course(id: "GORU", name: "Computer Vision", language: "en")

    func testTheLectureIsTheBackgroundAndTheConversationTheMessages() {
        let entries = [ChatEntry(role: .user, text: "Zincir kuralı ne?"), ChatEntry(role: .assistant, text: "Türevlerin çarpımı."),
                       ChatEntry(role: .user, text: "Örnek ver")]
        let request = LectureChat.request(model: "m", entries: entries, session: session, course: course,
                                          notes: "# Geri yayılım", transcript: "[00:00:00]\nmetin")
        XCTAssertEqual(request.model, "m")
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(request.messages.last?.text, "Örnek ver")
        XCTAssertTrue(request.system.contains("Course: Computer Vision"))
        XCTAssertTrue(request.system.contains("Notes:\n# Geri yayılım"))
        XCTAssertTrue(request.system.contains("Transcript:\n[00:00:00]\nmetin"))
        XCTAssertEqual(request.maxOutputTokens, 4000)

        let bare = LectureChat.request(model: "m", entries: entries, session: session, course: nil, notes: nil, transcript: "")
        XCTAssertFalse(bare.system.contains("Notes:"))
        XCTAssertFalse(bare.system.contains("Transcript:"))
        XCTAssertTrue(bare.system.contains("Meeting: s"))
    }

    func testTheConversationIsKeptInTheSessionFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(LectureChat.load(from: folder), [])
        let entries = [ChatEntry(role: .user, text: "Soru", date: Date(timeIntervalSince1970: 1_800_000_000))]
        try LectureChat.save(entries, in: folder)
        XCTAssertEqual(LectureChat.load(from: folder), entries)
    }
}
