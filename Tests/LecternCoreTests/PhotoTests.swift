import XCTest
@testable import LecternCore

final class PhotoTimingTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two halves of a lecture: 50 minutes, a 15 minute break, 40 minutes.
    var session: Session {
        Session(id: "s", kind: .lecture, courseID: "GORU", title: "s", date: start, recordings: [
            RecordingInfo(file: "a.m4a", start: start, duration: 3000),
            RecordingInfo(file: "b.m4a", start: start.addingTimeInterval(3900), duration: 2400),
        ])
    }

    func testCameraTimeWithAndWithoutOffset() {
        let istanbul = TimeZone(identifier: "Europe/Istanbul")!
        let moment = ISO8601DateFormatter().date(from: "2027-01-12T07:42:13Z")
        XCTAssertEqual(PhotoTiming.exifDate("2027:01:12 10:42:13", offset: "+03:00"), moment)
        XCTAssertEqual(PhotoTiming.exifDate("2027:01:12 10:42:13", offset: nil, timeZone: istanbul), moment)
        XCTAssertEqual(PhotoTiming.exifDate("2027:01:12 07:42:13", offset: "+00:00", timeZone: istanbul), moment)
        XCTAssertNil(PhotoTiming.exifDate("12.01.2027", offset: nil))
    }

    func testPlacesAPhotoInTheRecordingThatWasRunning() throws {
        let first = try XCTUnwrap(PhotoTiming.place(start.addingTimeInterval(600), in: session))
        XCTAssertEqual(first.recording, "a.m4a")
        XCTAssertEqual(first.time, 600)
        let second = try XCTUnwrap(PhotoTiming.place(start.addingTimeInterval(4000), in: session))
        XCTAssertEqual(second.recording, "b.m4a")
        XCTAssertEqual(second.time, 100)
    }

    func testPhotosNearTheRecordingGoToTheNearestEnd() throws {
        // 5 minutes into the break: closer to the end of the first half
        let inBreak = try XCTUnwrap(PhotoTiming.place(start.addingTimeInterval(3300), in: session))
        XCTAssertEqual(inBreak.recording, "a.m4a")
        XCTAssertEqual(inBreak.time, 3000)
        // ten minutes before it began
        let early = try XCTUnwrap(PhotoTiming.place(start.addingTimeInterval(-600), in: session))
        XCTAssertEqual(early.time, 0)
        // the next morning
        XCTAssertNil(PhotoTiming.place(start.addingTimeInterval(86_400), in: session))
        XCTAssertNil(PhotoTiming.session(for: start.addingTimeInterval(86_400), among: [session]))
        XCTAssertEqual(PhotoTiming.session(for: start.addingTimeInterval(60), among: [session])?.id, "s")
    }

    func testARecordingStillGoingCountsUpToNow() throws {
        var live = session
        live.recordings[1].duration = nil
        live.recordings[1].inProgress = true
        let now = start.addingTimeInterval(3900 + 120)
        let spot = try XCTUnwrap(PhotoTiming.place(now.addingTimeInterval(-30), in: live, now: now))
        XCTAssertEqual(spot.recording, "b.m4a")
        XCTAssertEqual(spot.time, 90)
    }

    func testAddingPhotosKeepsSameNamesApartAndPlacesThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let course = Course(id: "GORU", name: "Vision", language: "en")
        try library.save(course)
        var lecture = try library.lectureSession(course: course, date: Date(), week: 1)
        // recording since five minutes ago; a copied file is dated now, so it lands about 300 s in
        lecture.recordings = [RecordingInfo(file: "a.m4a", start: Date().addingTimeInterval(-300), inProgress: true)]
        try library.save(lecture)

        let source = root.appendingPathComponent("from", isDirectory: true)
        for folder in ["one", "two"] {
            let dir = source.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("IMG_0001.jpg"))
        }
        let updated = try library.addPhotos([source.appendingPathComponent("one/IMG_0001.jpg"),
                                             source.appendingPathComponent("two/IMG_0001.jpg")], to: lecture)
        XCTAssertEqual(updated.photos.map(\.file), ["IMG_0001.jpg", "IMG_0001-2.jpg"])
        XCTAssertEqual(updated.photos.first?.recording, "a.m4a")
        XCTAssertEqual(updated.photos.first?.time ?? 0, 300, accuracy: 5)
        XCTAssertEqual(library.reload(lecture)?.photos.count, 2)
        let board = library.folder(of: lecture).appendingPathComponent("board")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: board.path)), ["IMG_0001.jpg", "IMG_0001-2.jpg"])
    }
}

final class NotePhotoTests: XCTestCase {
    func testPictureLinesBecomeImageBlocks() {
        XCTAssertEqual(NoteDocument.parse("Metin\n![](board/IMG_1.jpg)\n![Tahta](board/a b.png)"), [
            .paragraph("Metin"), .image(path: "board/IMG_1.jpg", caption: ""), .image(path: "board/a b.png", caption: "Tahta"),
        ])
        // not a picture line: text around it, or an empty path
        XCTAssertEqual(NoteDocument.parse("Bak ![](x.jpg) burada"), [.paragraph("Bak ![](x.jpg) burada")])
        XCTAssertEqual(NoteDocument.parse("![]()"), [.paragraph("![]()")])
    }

    func testTheNotesPromptListsPhotosOnTheTimeline() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(id: "s", kind: .lecture, courseID: "GORU", title: "s", date: start,
                              recordings: [RecordingInfo(file: "a.m4a", start: start, duration: 600),
                                           RecordingInfo(file: "b.m4a", start: start.addingTimeInterval(900), duration: 600)],
                              photos: [BoardPhoto(file: "IMG_2.jpg", recording: "b.m4a", time: 30),
                                       BoardPhoto(file: "IMG_1.jpg", recording: "a.m4a", time: 125),
                                       BoardPhoto(file: "loose.jpg")])
        let input = NotePrompts.lecture(session: session, course: nil, transcript: "…")
        XCTAssertTrue(input.contains("Board photos the student took:\n[00:02:05] board/IMG_1.jpg\n[00:10:30] board/IMG_2.jpg\n"))
        XCTAssertFalse(input.contains("loose.jpg"))
    }
}
