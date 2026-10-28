import LecternCore
import SwiftUI

/// The week's lectures on a grid, with the exams and deadlines ahead beside it.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    /// Weeks away from this one.
    @State private var offset = 0
    @State private var appeared = false

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    WeekGrid(days: days)
                }
                .frame(maxWidth: .infinity)
                .enter(appeared, delay: 0)
                DatesColumn()
                    .frame(width: 250)
                    .padding(.top, 46)
                    .enter(appeared, delay: 0.08)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L("schedule.title"))
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.5)
            Spacer(minLength: 8)
            Text(weekLabel)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .contentTransition(.numericText())
            if offset != 0 {
                Button(L("schedule.thisWeek")) { withAnimation(Theme.ease) { offset = 0 } }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 26))
                    .transition(.opacity)
            }
            IconButton(systemName: "chevron.left", label: L("schedule.previous")) { withAnimation(Theme.ease) { offset -= 1 } }
            IconButton(systemName: "chevron.right", label: L("schedule.next")) { withAnimation(Theme.ease) { offset += 1 } }
        }
    }

    private var monday: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let back = model.schedule.isoWeekday(of: today) - 1
        return calendar.date(byAdding: .day, value: offset * 7 - back, to: today) ?? today
    }

    /// Monday to Friday, and the weekend when a course meets then.
    private var days: [ScheduleDay] {
        let calendar = Calendar.current
        let weekend = model.courses.contains { $0.slots.contains { $0.weekday >= 6 && $0.isValid } }
        return (1...(weekend ? 7 : 5)).compactMap { weekday in
            guard let date = calendar.date(byAdding: .day, value: weekday - 1, to: monday) else { return nil }
            let lectures = model.courses.flatMap { course in
                course.slots.enumerated().filter { $0.element.weekday == weekday && $0.element.isValid }.map { index, slot in
                    // a second recording that day joins the same session, so every slot of the day shows it
                    ScheduleDay.Lecture(id: "\(course.id)-\(index)", course: course, slot: slot,
                                        session: model.sessions.first { $0.courseID == course.id && calendar.isDate($0.date, inSameDayAs: date) })
                }
            }
            return ScheduleDay(weekday: weekday, date: date, lectures: lectures)
        }
    }

    /// "6. hafta · 26 - 30 Ekim", to Sunday when the grid shows the weekend
    private var weekLabel: String {
        let calendar = Calendar.current
        let last = days.last?.date ?? monday
        let sameMonth = calendar.isDate(monday, equalTo: last, toGranularity: .month)
        let first = sameMonth ? monday.formatted(.dateTime.day()) : monday.formatted(.dateTime.day().month(.wide))
        let range = "\(first) - \(last.formatted(.dateTime.day().month(.wide)))"
        guard let semester = model.library.settings().semester, monday >= calendar.startOfDay(for: semester.start) else { return range }
        return "\(L("session.week", model.schedule.week(of: monday, semester: semester))) · \(range)"
    }
}

struct ScheduleDay: Identifiable {
    struct Lecture: Identifiable {
        /// The course and the slot's place in its list; two equal slots stay two.
        let id: String
        let course: Course
        let slot: ScheduleSlot
        let session: Session?
    }

    let weekday: Int
    let date: Date
    let lectures: [Lecture]
    var id: Int { weekday }
    var isToday: Bool { Calendar.current.isDateInToday(date) }
}

private struct WeekGrid: View {
    let days: [ScheduleDay]
    private let hourHeight: CGFloat = 46

    var body: some View {
        let (first, last) = hours
        let height = CGFloat(last - first) * hourHeight + 12
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 0) {
                Color.clear.frame(width: 38, height: 22)
                ZStack(alignment: .topTrailing) {
                    ForEach(first...last, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .offset(y: CGFloat(hour - first) * hourHeight - 1)
                    }
                }
                .frame(width: 38, height: height, alignment: .topTrailing)
            }
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Text(verbatim: "\(RelativeTime.weekday(day.weekday)) \(day.date.formatted(.dateTime.day()))")
                        .font(.system(size: 12, weight: day.isToday ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(day.isToday ? Color(hex: 0xB91C1C) : Theme.tertiary)
                        .frame(height: 16)
                    DayColumn(day: day, first: first, last: last, hourHeight: hourHeight)
                        .frame(height: height)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// From the earliest lecture's hour to the latest one's end, at least 09 to 17.
    private var hours: (Int, Int) {
        let slots = days.flatMap(\.lectures).map(\.slot)
        let first = min(9, slots.map(\.start.hour).min() ?? 9)
        let last = max(17, slots.map { $0.end.minute > 0 ? $0.end.hour + 1 : $0.end.hour }.max() ?? 17)
        return (first, min(24, last))
    }
}

private struct DayColumn: View {
    @Environment(AppModel.self) private var model
    let day: ScheduleDay
    let first: Int
    let last: Int
    let hourHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(day.isToday ? Color(hex: 0xFFF7F7) : Color(hex: 0xF7F7F7))
            ForEach(day.lectures) { lecture in
                let top = y(lecture.slot.start)
                let height = max(40, y(lecture.slot.end) - top)
                LectureBlock(lecture: lecture, height: height)
                    .padding(.horizontal, 4)
                    .offset(y: top)
            }
            if day.isToday {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let now = Calendar.current.dateComponents([.hour, .minute], from: context.date)
                    let minutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
                    let line = y(ClockTime(hour: now.hour ?? 0, minute: now.minute ?? 0))
                    // only while the day's hours are on the grid
                    if minutes >= first * 60, minutes <= last * 60 {
                        Capsule()
                            .fill(Theme.record)
                            .frame(height: 2)
                            .padding(.horizontal, -2)
                            .offset(y: line)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func y(_ time: ClockTime) -> CGFloat {
        CGFloat(time.minutes - first * 60) / 60 * hourHeight + 6
    }
}

private struct LectureBlock: View {
    @Environment(AppModel.self) private var model
    let lecture: ScheduleDay.Lecture
    let height: CGFloat

    var body: some View {
        Button {
            if let session = lecture.session { model.open(session) } else { model.go(to: .archive(.course(lecture.course.id))) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if height >= 110 {
                    GeometryReader { proxy in
                        CoverView(course: lecture.course, width: proxy.size.width, height: 44, radius: 0)
                    }
                    .frame(height: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(lecture.course.shortName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(height >= 80 ? 2 : 1)
                    Text(verbatim: "\(lecture.slot.start) - \(lecture.slot.end)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                    if lecture.session != nil, height >= 70 {
                        Text(L("schedule.recorded"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0x047857))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .top)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle())
        .help(lecture.course.name)
    }
}

/// Dates said in lectures waiting for a decision, then the exams and deadlines of every course.
private struct DatesColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dates = CourseDate.upcoming(in: model.courses, from: Calendar.current.startOfDay(for: Date()), days: 120)
        let mentioned = model.mentionedDates
        VStack(alignment: .leading, spacing: 8) {
            if !mentioned.isEmpty {
                Text(L("dates.said"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                ForEach(mentioned, id: \.date.id) { item in
                    MentionCard(session: item.session, date: item.date)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Color.clear.frame(height: 6)
            }
            Text(L("home.upcoming"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            if dates.isEmpty {
                Text(L("schedule.noDates"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
            }
            ForEach(dates.prefix(8), id: \.date.id) { item in
                DateRow(course: item.course, date: item.date)
            }
        }
    }
}

/// A date the lecturer gave: the words, where in the lecture, and whether to keep it.
private struct MentionCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let date: MentionedDate

    var body: some View {
        let course = model.course(session.courseID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DateBadge(date: date.date, exam: date.kind == .exam)
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.title.isEmpty ? L("course.kind.\(date.kind.rawValue)") : date.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Button { model.play(date, in: session) } label: {
                        HStack(spacing: 3) {
                            // the moment first, so a long course name is what gets cut
                            if let at = date.at {
                                Image(systemName: "play.fill").font(.system(size: 7))
                                Text(at.clock).monospacedDigit()
                                Text(verbatim: "·")
                            }
                            Text(verbatim: course?.shortName ?? "")
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("dates.listen"))
                }
                Spacer(minLength: 0)
            }
            if !date.quote.isEmpty {
                Text(verbatim: "“\(date.quote)”")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x3F3F3F))
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0xF6F6F6)))
            }
            HStack(spacing: 4) {
                Button(L("dates.add")) { model.decide(date, in: session, add: true) }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                Button(L("dates.ignore")) { model.decide(date, in: session, add: false) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 26))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }
}

/// The month and day in a small tile, red for an exam.
private struct DateBadge: View {
    let date: Date
    let exam: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(exam ? Color(hex: 0xB91C1C) : Theme.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
        }
        .frame(width: 38, height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(exam ? Color(hex: 0xFFF1F1) : Color(hex: 0xF4F4F4)))
    }
}

private struct DateRow: View {
    @Environment(AppModel.self) private var model
    let course: Course
    let date: CourseDate

    var body: some View {
        Button { model.edit(course) } label: {
            HStack(spacing: 10) {
                DateBadge(date: date.date, exam: date.kind == .exam)
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.title.isEmpty ? L("course.kind.\(date.kind.rawValue)") : date.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: "\(course.shortName) · \(RelativeTime.until(date.date))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle())
    }
}
