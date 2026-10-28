import Foundation

/// Finds which course is on at a given moment and which week of the term it is.
public struct Schedule: Sendable {
    /// A course still counts as "now" this long before it starts and after it ends,
    /// so a recording started early or stopped late lands in the right course.
    public var leadMinutes = 30
    public var trailMinutes = 45
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public struct Match: Hashable, Sendable {
        public var course: Course
        public var slot: ScheduleSlot
    }

    /// ISO weekday (1 = Monday ... 7 = Sunday).
    public func isoWeekday(of date: Date) -> Int {
        let w = calendar.component(.weekday, from: date)  // 1 = Sunday in Gregorian
        return w == 1 ? 7 : w - 1
    }

    public func minutesOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The course whose slot (widened by lead and trail time) contains `date`.
    /// When two widened slots overlap, the one whose real start is closest wins.
    public func current(at date: Date, courses: [Course]) -> Match? {
        let day = isoWeekday(of: date)
        let now = minutesOfDay(date)
        var best: (Match, Int)?
        for course in courses {
            for slot in course.slots where slot.weekday == day {
                guard slot.start.minutes - leadMinutes <= now, now <= slot.end.minutes + trailMinutes else { continue }
                let distance = abs(now - slot.start.minutes)
                if best == nil || distance < best!.1 {
                    best = (Match(course: course, slot: slot), distance)
                }
            }
        }
        return best?.0
    }

    /// The next slot start after `date` (within a week), for reminders and the "next class" label.
    public func next(after date: Date, courses: [Course]) -> (match: Match, start: Date)? {
        var best: (Match, Date)?
        for course in courses {
            for slot in course.slots {
                guard let start = nextDate(of: slot, after: date) else { continue }
                if best == nil || start < best!.1 {
                    best = (Match(course: course, slot: slot), start)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    public func nextDate(of slot: ScheduleSlot, after date: Date) -> Date? {
        var comps = DateComponents()
        comps.weekday = slot.weekday == 7 ? 1 : slot.weekday + 1  // back to Gregorian numbering
        comps.hour = slot.start.hour
        comps.minute = slot.start.minute
        return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    /// Week of term: days since the start day divided by seven, plus one; never below 1.
    public func week(of date: Date, semester: Semester) -> Int {
        let start = calendar.startOfDay(for: semester.start)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        return max(1, days / 7 + 1)
    }
}
