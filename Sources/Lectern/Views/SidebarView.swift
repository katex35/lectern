import LecternCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // room for the window's traffic lights
                Color.clear.frame(width: 62, height: 1)
                LogoMark(size: 20)
                Text(verbatim: "Lectern")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(-0.3)
                Spacer(minLength: 0)
                IconButton(systemName: "square.and.pencil", label: L("sidebar.new")) { model.goHome() }
            }
            .frame(height: 52)
            .padding(.trailing, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NextLectureCard()
                        .padding(.bottom, 10)

                    if !model.courses.isEmpty {
                        SectionLabel(text: L("sidebar.courses"))
                        ForEach(model.courses) { course in
                            CourseRow(course: course)
                        }
                    }

                    let recent = Array(model.sessions.prefix(8))
                    if !recent.isEmpty {
                        SectionLabel(text: L("sidebar.recent"))
                        ForEach(recent, id: \.id) { session in
                            SessionRow(session: session)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            UserRow()
                .padding(8)
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

private struct NextLectureCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let next = model.nextLecture {
            Button { model.record(next.course) } label: {
                HStack(spacing: 10) {
                    CoverView(course: next.course, width: 36, height: 36, radius: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.course.shortName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(RelativeTime.dayAndTime(next.start))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.ink))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .accessibilityLabel(L("sidebar.recordNext", next.course.name))
        }
    }
}

private struct CourseRow: View {
    @Environment(AppModel.self) private var model
    let course: Course

    var body: some View {
        let count = model.sessions.filter { $0.courseID == course.id }.count
        Button {
            if let latest = model.sessions.first(where: { $0.courseID == course.id }) { model.open(latest) }
        } label: {
            HStack(spacing: 10) {
                CoverView(course: course, width: 26, height: 26, radius: 8)
                Text(course.shortName)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let selected = model.screen == .session(SessionRef(session))
        Button { model.open(session) } label: {
            HStack(spacing: 10) {
                Text(SessionText.shortTitle(session, model: model))
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.totalDuration > 0 {
                    Text(session.totalDuration.hoursMinutes)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected))
    }
}

private struct UserRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        HStack(spacing: 10) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.ink))
            Text(name)
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle(radius: 8))
            .accessibilityLabel(L("sidebar.settings"))
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }
}

/// Titles and dates shown for sessions.
@MainActor
enum SessionText {
    /// The first heading of the notes, else "Week 6" or the meeting title.
    static func title(_ session: Session, model: AppModel) -> String {
        if let notes = model.text("notes.md", in: session),
           let heading = notes.split(separator: "\n").first(where: { $0.hasPrefix("#") }) {
            let text = heading.drop(while: { $0 == "#" || $0 == " " })
            if !text.isEmpty { return String(text) }
        }
        if session.kind == .meeting {
            // an untitled meeting is named after its folder, "2026-09-22-1552"; the time tells two on one day apart
            let untitled = session.title.first?.isNumber == true && session.title.contains("-")
            return untitled ? "\(L("session.meeting")) · \(RelativeTime.dayAndTime(session.date))" : session.title
        }
        return session.week.map { L("session.week", $0) } ?? session.title
    }

    static func shortTitle(_ session: Session, model: AppModel) -> String {
        let title = title(session, model: model)
        if session.kind == .meeting || title != session.title { return title }
        return session.week.map { L("session.week", $0) } ?? title
    }

    static func meta(_ session: Session, model: AppModel) -> String {
        var parts: [String] = []
        if let course = model.course(session.courseID) { parts.append(course.shortName) } else { parts.append(L("session.meeting")) }
        parts.append(RelativeTime.day(session.date))
        if session.totalDuration > 0 { parts.append(RelativeTime.duration(session.totalDuration)) }
        return parts.joined(separator: " · ")
    }
}

enum RelativeTime {
    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)) \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L("time.today") }
        if calendar.isDateInTomorrow(date) { return L("time.tomorrow") }
        if calendar.isDateInYesterday(date) { return L("time.yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func until(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// "1 sa 42 dk", "42 dk", "35 sn"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return L("time.seconds", total) }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L("time.minutes", minutes) }
        return L("time.hoursMinutes", minutes / 60, minutes % 60)
    }
}
