import LecternCore
import SwiftUI

/// A course as the sheet edits it; `existingID` is set for a course that already has a folder.
struct CourseDraft: Identifiable {
    struct Slot: Identifiable {
        let id = UUID()
        var weekday: Int
        var start: Date
        var end: Date
        var room: String
    }

    let id = UUID()
    var existingID: String?
    var code = ""
    var name = ""
    /// Empty lets transcription detect the language.
    var language = appLanguage
    var instructor = ""
    var colorHex: String?
    var slots: [Slot] = []

    init() {}

    init(_ course: Course) {
        existingID = course.id
        code = course.id
        name = course.name
        language = course.language
        instructor = course.instructor ?? ""
        colorHex = course.colorHex
        slots = course.slots.map {
            Slot(weekday: $0.weekday, start: Self.date($0.start), end: Self.date($0.end), room: $0.room ?? "")
        }
    }

    static func date(_ time: ClockTime) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    static func time(_ date: Date) -> ClockTime {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return ClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// The course to save; a new one gets a folder name no other course has.
    func course(taken: Set<String>) -> Course {
        let id = existingID ?? Course.newID(code: code, name: name, taken: taken)
        return Course(id: id, name: name.trimmingCharacters(in: .whitespaces), language: language,
                      slots: slots.map {
                          ScheduleSlot(weekday: $0.weekday, start: Self.time($0.start), end: Self.time($0.end),
                                       room: $0.room.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.room)
                      },
                      instructor: instructor.trimmingCharacters(in: .whitespaces).isEmpty ? nil : instructor,
                      colorHex: colorHex)
    }
}

struct CourseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: CourseDraft
    @State private var error: String?

    var body: some View {
        let course = draft.course(taken: Set(model.courses.map(\.id)))
        let clashes = ScheduleClash.find(for: course, among: model.courses)
        let invalid = course.slots.contains { !$0.isValid }
        VStack(spacing: 0) {
            Text(draft.existingID == nil ? L("course.new") : L("course.edit"))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                Section {
                    TextField(L("course.name"), text: $draft.name, prompt: Text(verbatim: "Computer Vision"))
                    TextField(L("course.code"), text: $draft.code, prompt: Text(verbatim: "CSE5217"))
                        .disabled(draft.existingID != nil)
                    TextField(L("course.instructor"), text: $draft.instructor)
                    Picker(L("course.language"), selection: $draft.language) {
                        ForEach(languages, id: \.self) { code in
                            Text(code.isEmpty ? L("course.language.auto") : languageName(code)).tag(code)
                        }
                    }
                    LabeledContent(L("course.color")) { colors }
                }

                Section {
                    ForEach($draft.slots) { $slot in
                        HStack(spacing: 8) {
                            Picker(L("course.day"), selection: $slot.weekday) {
                                ForEach(1...7, id: \.self) { Text(weekdayName($0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(width: 118, alignment: .leading)
                            DatePicker(L("course.start"), selection: $slot.start, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                            DatePicker(L("course.end"), selection: $slot.end, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            TextField(L("course.room"), text: $slot.room, prompt: Text(L("course.room")))
                                .labelsHidden()
                            IconButton(systemName: "minus.circle", label: L("course.removeSlot"), size: 24) {
                                draft.slots.removeAll { $0.id == slot.id }
                            }
                        }
                    }
                    Button(L("course.addSlot")) { addSlot() }
                } header: {
                    Text(L("course.slots"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if invalid { Text(L("course.invalidSlot")) }
                        ForEach(Array(clashes.enumerated()), id: \.offset) { _, clash in
                            Text(L("course.clash", clash.other.shortName, weekdayName(clash.slot.weekday),
                                   clash.otherSlot.start.description))
                        }
                        if let error { Text(error) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.record)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 6) {
                Spacer()
                Button(L("course.cancel")) { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .outline))
                    .keyboardShortcut(.cancelAction)
                Button(L("course.save")) { save(course) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(course.name.isEmpty || invalid)
                    .opacity(course.name.isEmpty || invalid ? 0.4 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 620, height: 580)
    }

    private var colors: some View {
        HStack(spacing: 8) {
            ForEach([nil] + Theme.paletteHex.map { Optional($0) }, id: \.self) { hex in
                let selected = draft.colorHex == hex
                Button { draft.colorHex = hex } label: {
                    Circle()
                        .fill(hex.flatMap { UInt32($0.dropFirst(), radix: 16) }.map { Color(hex: $0) } ?? Theme.field)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0))
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(selected ? 1 : 0), lineWidth: 1).padding(-2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hex ?? L("course.color.auto"))
            }
        }
    }

    /// The common lecture languages, and the course's own when it is another one.
    private var languages: [String] {
        let common = ["", "tr", "en", "de", "fr", "es", "it", "ar", "ru"]
        return common.contains(draft.language) ? common : common + [draft.language]
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    private func weekdayName(_ iso: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        // ISO counts from Monday, the formatter from Sunday
        return formatter.standaloneWeekdaySymbols[iso % 7].localizedCapitalized
    }

    /// A new slot an hour and a half long, the day after the last one.
    private func addSlot() {
        let previous = draft.slots.last
        let start = previous?.start ?? CourseDraft.date(ClockTime(hour: 9, minute: 0))
        draft.slots.append(CourseDraft.Slot(weekday: previous.map { $0.weekday % 7 + 1 } ?? 1, start: start,
                                            end: previous?.end ?? start.addingTimeInterval(90 * 60), room: ""))
    }

    private func save(_ course: Course) {
        do {
            try model.library.save(course)
            model.reload()
            Task { await Reminders.shared.plan() }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
