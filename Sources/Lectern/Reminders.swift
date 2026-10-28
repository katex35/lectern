import AppKit
import LecternCore
import UserNotifications

/// A notice a few minutes before each lecture, with a button that starts recording it.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    static let category = "lecture"
    static let recordAction = "record"
    static let enabledKey = "reminders.on"
    static let leadKey = "reminders.lead"

    weak var model: AppModel?

    static var lead: Int {
        let minutes = UserDefaults.standard.integer(forKey: leadKey)
        return minutes > 0 ? minutes : 10
    }

    /// Notifications come from Lectern.app; a binary started with `swift run` has no bundle to post them from.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    var isAvailable: Bool { center != nil }

    func start(_ model: AppModel) {
        self.model = model
        guard let center else { return }
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: L("reminder.record"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [record],
                                                                 intentIdentifiers: [])])
        Task { await plan() }
    }

    /// Asks macOS for permission; it does so once, when reminders are turned on.
    func enable() async -> Bool {
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await plan()
        return granted
    }

    /// Replaces the waiting notices with the lectures of the coming week.
    func plan() async {
        guard let center, let model else { return }
        let waiting = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("lecture.") }
        center.removePendingNotificationRequests(withIdentifiers: waiting)
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let lead = TimeInterval(Self.lead * 60)
        let lectures = model.schedule.upcoming(from: Date().addingTimeInterval(lead), days: 7, courses: model.courses,
                                               semester: model.library.settings().semester)
        for lecture in lectures {
            let content = UNMutableNotificationContent()
            content.title = lecture.match.course.shortName
            content.body = lecture.match.slot.room.map { L("reminder.bodyRoom", Self.lead, $0) } ?? L("reminder.body", Self.lead)
            content.categoryIdentifier = Self.category
            content.userInfo = ["course": lecture.match.course.id]
            content.sound = .default
            let fire = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                       from: lecture.start.addingTimeInterval(-lead))
            let id = "lecture.\(lecture.match.course.id).\(Int(lecture.start.timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false)))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let courseID = response.notification.request.content.userInfo["course"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            guard action == Reminders.recordAction, let model = self.model, let course = model.course(courseID),
                  !model.recorder.isActive else { return }
            model.record(course)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
