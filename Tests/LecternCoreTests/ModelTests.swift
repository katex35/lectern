import XCTest
@testable import LecternCore

final class ScheduleTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    let vision = Course(id: "GORU", name: "Computer Vision", language: "en",
                        slots: [ScheduleSlot(weekday: 2, start: ClockTime("09:55")!, end: ClockTime("12:30")!)])
    let research = Course(id: "ARASTIRMA", name: "Research Methods", language: "tr",
                          slots: [ScheduleSlot(weekday: 1, start: ClockTime("13:30")!, end: ClockTime("16:05")!)])

    func testCurrentCourseIncludesLeadAndTrail() {
        let s = Schedule(calendar: calendar)
        // 2026-10-27 is a Tuesday
        XCTAssertEqual(s.current(at: date(2026, 10, 27, 9, 25), courses: [vision, research])?.course.id, "GORU")
        XCTAssertNil(s.current(at: date(2026, 10, 27, 9, 24), courses: [vision, research]))
        XCTAssertEqual(s.current(at: date(2026, 10, 27, 13, 15), courses: [vision, research])?.course.id, "GORU")
        XCTAssertNil(s.current(at: date(2026, 10, 27, 13, 16), courses: [vision, research]))
        XCTAssertEqual(s.current(at: date(2026, 10, 26, 14, 0), courses: [vision, research])?.course.id, "ARASTIRMA")
    }

    func testWeekOfTermMatchesTheOriginalTool() {
        let s = Schedule(calendar: calendar)
        let term = Semester(name: "Fall 2026", start: date(2026, 9, 16))
        XCTAssertEqual(s.week(of: date(2026, 9, 16, 10), semester: term), 1)
        XCTAssertEqual(s.week(of: date(2026, 9, 22, 23), semester: term), 1)
        XCTAssertEqual(s.week(of: date(2026, 9, 23), semester: term), 2)
        XCTAssertEqual(s.week(of: date(2026, 10, 27), semester: term), 6)
        XCTAssertEqual(s.week(of: date(2026, 10, 28), semester: term), 7)
        XCTAssertEqual(s.week(of: date(2026, 9, 1), semester: term), 1)
    }

    func testNextSlot() {
        let s = Schedule(calendar: calendar)
        let next = s.next(after: date(2026, 10, 27, 13, 0), courses: [vision, research])
        XCTAssertEqual(next?.match.course.id, "ARASTIRMA")
        XCTAssertEqual(next?.start, date(2026, 11, 2, 13, 30))
    }

    func testUpcomingLecturesStayInTheTerm() {
        let s = Schedule(calendar: calendar)
        // Tuesday 27 October, 10:00: the Vision lecture of that morning has started already
        let all = s.upcoming(from: date(2026, 10, 27, 10), days: 14, courses: [vision, research])
        XCTAssertEqual(all.map { $0.start }, [date(2026, 11, 2, 13, 30), date(2026, 11, 3, 9, 55),
                                             date(2026, 11, 9, 13, 30), date(2026, 11, 10, 9, 55)])
        let term = Semester(name: "Fall", start: date(2026, 9, 16), end: date(2026, 11, 2))
        let inTerm = s.upcoming(from: date(2026, 10, 27, 10), days: 14, courses: [vision, research], semester: term)
        XCTAssertEqual(inTerm.map { $0.match.course.id }, ["ARASTIRMA"])
    }

    func testCourseDatesAreOptionalInOldFilesAndListedInOrder() throws {
        let old = #"{"id":"GORU","name":"Vision","language":"en","slots":[]}"#
        let course = try JSONStore.decoder.decode(Course.self, from: Data(old.utf8))
        XCTAssertNil(course.dates)
        XCTAssertEqual(course.events, [])

        let midterm = CourseDate(kind: .exam, title: "Vize", date: date(2026, 11, 13, 10))
        let homework = CourseDate(kind: .assignment, title: "Ödev 2", date: date(2026, 11, 3, 23, 59))
        let final = CourseDate(kind: .exam, title: "Final", date: date(2027, 1, 10, 10))
        let dated = Course(id: "GORU", name: "Vision", language: "en", dates: [midterm, homework, final])
        XCTAssertEqual(dated.events.map(\.title), ["Ödev 2", "Vize", "Final"])
        let soon = CourseDate.upcoming(in: [dated, research], from: date(2026, 11, 1), days: 30)
        XCTAssertEqual(soon.map(\.date.title), ["Ödev 2", "Vize"])
        // round trip keeps them
        let back = try JSONStore.decoder.decode(Course.self, from: JSONStore.encoder.encode(dated))
        XCTAssertEqual(back.events, dated.events)
        XCTAssertNil(Course(id: "X", name: "x", language: "tr").dates)
    }

    func testNewCourseIDs() {
        XCTAssertEqual(Course.newID(code: "cse 5217", name: "Vision", taken: []), "CSE-5217")
        XCTAssertEqual(Course.newID(code: "", name: "Veri Bilimi", taken: []), "VERI-BILIMI")
        XCTAssertEqual(Course.newID(code: "goru", name: "x", taken: ["GORU", "GORU-2"]), "GORU-3")
        XCTAssertEqual(Course.newID(code: "Goru", name: "x", taken: ["goru"]), "GORU-2")
        XCTAssertEqual(Course.newID(code: "", name: "!!!", taken: []), "COURSE")
    }

    func testClashesAndInvalidSlots() {
        let overlapping = Course(id: "DOGALDIL", name: "NLP", language: "en",
                                 slots: [ScheduleSlot(weekday: 2, start: ClockTime("12:00")!, end: ClockTime("14:00")!),
                                         ScheduleSlot(weekday: 2, start: ClockTime("12:30")!, end: ClockTime("12:30")!)])
        let clashes = ScheduleClash.find(for: overlapping, among: [vision, research, overlapping])
        XCTAssertEqual(clashes.map(\.other.id), ["GORU"])
        XCTAssertFalse(overlapping.slots[1].isValid)
        // touching ends do not clash
        let after = ScheduleSlot(weekday: 2, start: ClockTime("12:30")!, end: ClockTime("13:00")!)
        XCTAssertFalse(after.overlaps(vision.slots[0]))
    }

    func testClockTimeCoding() throws {
        let data = try JSONStore.encoder.encode(vision)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"09:55\""))
        XCTAssertEqual(try JSONStore.decoder.decode(Course.self, from: data), vision)
        XCTAssertNil(ClockTime("25:00"))
    }
}

final class LibraryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-lib-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCoursesAndSessionsRoundTrip() throws {
        let lib = Library(root: root)
        let course = Course(id: "GORU", name: "Computer Vision", language: "en")
        try lib.save(course)
        XCTAssertEqual(lib.courses(), [course])

        let morning = Date(timeIntervalSince1970: 1_793_000_000)
        var s = try lib.lectureSession(course: course, date: morning, week: 6)
        XCTAssertTrue(s.id.hasSuffix("Week 06"))
        let file = lib.newRecordingFile(in: s, start: morning)
        s.recordings.append(RecordingInfo(file: file, start: morning, duration: 3600.5,
                                          gaps: [RecordingGap(start: 10, duration: 2, reason: .noInput)]))
        // whole seconds: JSON keeps milliseconds, so finer dates would not compare equal after a reload
        s.markers.append(Marker(recording: file, time: 12.25, text: "exam topic", created: morning))
        try lib.save(s)

        // after the break, the second recording joins the same session
        let again = try lib.lectureSession(course: course, date: morning.addingTimeInterval(3 * 3600), week: 6)
        XCTAssertEqual(again, s)
        XCTAssertEqual(lib.sessions(ofCourse: "GORU"), [s])
        XCTAssertEqual(lib.reload(s)?.recordings.first?.start, morning)
    }

    func testRecordingAndMeetingNamesNeverCollide() throws {
        let lib = Library(root: root)
        let course = Course(id: "X", name: "X", language: "en")
        try lib.save(course)
        let s = try lib.lectureSession(course: course, date: Date(), week: nil)
        let start = Date()
        let first = lib.newRecordingFile(in: s, start: start)
        try Data().write(to: lib.folder(of: s).appendingPathComponent(first))
        XCTAssertNotEqual(lib.newRecordingFile(in: s, start: start), first)

        let a = try lib.newMeeting(title: "Budget / Q4", date: start)
        let b = try lib.newMeeting(title: "Budget / Q4", date: start)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.id.contains("/"))
        XCTAssertEqual(lib.meetings().count, 2)
    }

    func testSettingsDefaultAndSave() throws {
        let lib = Library(root: root)
        XCTAssertNil(lib.settings().semester)
        try lib.save(Library.Settings(semester: Semester(name: "Fall", start: Date(timeIntervalSince1970: 0))))
        XCTAssertEqual(lib.settings().semester?.name, "Fall")
    }
}
