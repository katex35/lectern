import XCTest
@testable import LecternCore

final class LectureDatesTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }()

    /// Wednesday 28 October 2026, 10:00 in Istanbul.
    var lecture: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10))! }

    let transcript = """
    [00:00:00]
    Bugün yerel aramaya başlıyoruz.

    [00:05:00]
    Bir de şunu söyleyeyim. İkinci ödevi gelecek çarşamba
    derste teslim edin, geç kabul etmiyorum.
    """

    func testReadsAFencedAnswerAndLeavesOutPastAndRepeatedDates() {
        let answer = """
        İşte tarihler:
        ```json
        {"dates": [
          {"kind": "assignment", "title": "Ödev 2", "date": "2026-11-04", "time": null, "quote": "İkinci ödevi gelecek çarşamba derste teslim edin", "at": "00:05:00"},
          {"kind": "assignment", "title": "Ödev 2 teslimi", "date": "2026-11-04", "quote": "tekrar"},
          {"kind": "exam", "title": "Vize", "date": "2026-11-13", "time": "13:30", "quote": "Ara sınav cuma", "at": "00:00:00"},
          {"kind": "exam", "title": "Geçen yılki vize", "date": "2025-11-13", "quote": "geçen yıl"},
          {"kind": "quiz", "title": "Kısa sınav", "date": "bilinmiyor"}
        ]}
        ```
        """
        let dates = LectureDates.parse(answer, lectureDate: lecture, transcript: transcript, calendar: calendar)
        XCTAssertEqual(dates.map(\.title), ["Ödev 2", "Vize"])
        // no time given: in the morning
        XCTAssertEqual(calendar.dateComponents([.month, .day, .hour], from: dates[0].date), DateComponents(month: 11, day: 4, hour: 9))
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: dates[1].date), DateComponents(hour: 13, minute: 30))
        XCTAssertEqual(dates[0].kind, .assignment)
        // found in the text: a third of the way into the piece that starts at 5 minutes
        XCTAssertEqual(dates[0].at ?? 0, 383, accuracy: 5)
        // not in the text: the model's piece time
        XCTAssertEqual(dates[1].at, 0)
    }

    func testAnswerWithoutJSONGivesNothing() {
        XCTAssertEqual(LectureDates.parse("Tarih yok.", lectureDate: lecture, transcript: transcript), [])
        XCTAssertEqual(LectureDates.parse("{\"dates\": []}", lectureDate: lecture, transcript: transcript), [])
    }

    func testLocatesAQuoteAcrossALineBreak() throws {
        let at = try XCTUnwrap(LectureDates.locate("derste teslim edin, geç kabul etmiyorum", in: transcript))
        XCTAssertGreaterThan(at, 300)
        XCTAssertLessThan(at, 600)
        XCTAssertNil(LectureDates.locate("hiç söylenmemiş bir cümle burada", in: transcript))
        XCTAssertNil(LectureDates.locate("iki kelime", in: transcript))
    }

    func testMergeKeepsChoicesAndDropsUnseenPendingOnes() {
        let day = { (d: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 9))! }
        let added = MentionedDate(kind: .exam, title: "Vize", date: day(13), quote: "", decision: .added)
        let ignored = MentionedDate(kind: .other, title: "Gezi", date: day(20), quote: "", decision: .ignored)
        let pending = MentionedDate(kind: .assignment, title: "Ödev", date: day(4), quote: "")
        let found = [MentionedDate(kind: .exam, title: "Ara sınav", date: day(13).addingTimeInterval(3600), quote: "yeni")]
        let merged = LectureDates.merge(found, keeping: [added, ignored, pending], calendar: calendar)
        XCTAssertEqual(merged.map(\.id), [added.id, ignored.id])
        XCTAssertEqual(merged.map(\.decision), [.added, .ignored])
        XCTAssertEqual(merged.first?.quote, "yeni")
    }
}
