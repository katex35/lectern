import Foundation

/// A wall-clock time of day such as 09:55. Encoded as "HH:mm".
public struct ClockTime: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// Minutes since midnight.
    public var minutes: Int { hour * 60 + minute }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ClockTime(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "expected HH:mm, got \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A weekly lecture slot. `weekday` follows ISO 8601: 1 is Monday, 7 is Sunday.
public struct ScheduleSlot: Codable, Hashable, Sendable {
    public var weekday: Int
    public var start: ClockTime
    public var end: ClockTime
    public var room: String?

    public init(weekday: Int, start: ClockTime, end: ClockTime, room: String? = nil) {
        self.weekday = weekday
        self.start = start
        self.end = end
        self.room = room
    }
}

public struct Course: Codable, Identifiable, Hashable, Sendable {
    /// Short code, also the folder name, e.g. "CSE5217".
    public var id: String
    public var name: String
    /// BCP 47 language of the lectures ("tr", "en"); used for transcription and generated notes.
    public var language: String
    public var slots: [ScheduleSlot]
    public var instructor: String?
    public var colorHex: String?

    public init(id: String, name: String, language: String, slots: [ScheduleSlot] = [],
                instructor: String? = nil, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.slots = slots
        self.instructor = instructor
        self.colorHex = colorHex
    }

    /// A folder-safe version of a user-typed code.
    public static func sanitizedID(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = text.uppercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The folder name for a new course: its code, or its name when there is no code, made safe and
    /// numbered when another course already has it.
    public static func newID(code: String, name: String, taken: Set<String>) -> String {
        var base = sanitizedID(code)
        if base.isEmpty { base = sanitizedID(name) }
        if base.isEmpty { base = "COURSE" }
        var id = base
        var number = 2
        // folders are compared without case on a default Mac disk
        let used = Set(taken.map { $0.uppercased() })
        while used.contains(id.uppercased()) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }
}

extension ScheduleSlot {
    /// A weekday from 1 to 7 and an end after the start.
    public var isValid: Bool { (1...7).contains(weekday) && end > start }

    public func overlaps(_ other: ScheduleSlot) -> Bool {
        weekday == other.weekday && start < other.end && other.start < end
    }
}

/// Two lectures of different courses at the same time on the same day.
public struct ScheduleClash: Equatable, Sendable {
    public var course: Course
    public var slot: ScheduleSlot
    public var other: Course
    public var otherSlot: ScheduleSlot

    /// Each clash once, between `course`'s slots and the other courses' slots.
    public static func find(for course: Course, among courses: [Course]) -> [ScheduleClash] {
        var clashes: [ScheduleClash] = []
        for slot in course.slots where slot.isValid {
            for other in courses where other.id != course.id {
                for otherSlot in other.slots where otherSlot.isValid && slot.overlaps(otherSlot) {
                    clashes.append(ScheduleClash(course: course, slot: slot, other: other, otherSlot: otherSlot))
                }
            }
        }
        return clashes
    }
}

/// Term dates. Week numbers count from the Monday-independent start day, like the original tool:
/// days since start divided by seven, plus one.
public struct Semester: Codable, Hashable, Sendable {
    public var name: String
    public var start: Date
    public var end: Date?

    public init(name: String, start: Date, end: Date? = nil) {
        self.name = name
        self.start = start
        self.end = end
    }
}
