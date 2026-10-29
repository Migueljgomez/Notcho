import AppKit
import UserNotifications

/// Task reminders as macOS notifications. One pending notification per task, keyed by the task's id.
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderService()
    var onOpen: (() -> Void)?            // a task reminder was clicked
    var onWrapUp: (() -> Void)?          // the daily wrap-up banner was clicked
    /// While Apple Reminders sync is on, Reminders alerts on Mac and iPhone, so the notch sends none of its own.
    var paused = false
    private var center: UNUserNotificationCenter { .current() }

    func setUp() { center.delegate = self }

    func status(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in DispatchQueue.main.async { done(s.authorizationStatus) } }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    /// Schedules (or replaces) the task's reminder; removes it when there's nothing to remind about.
    func sync(_ task: TaskItem) {
        let id = task.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard !paused, let date = task.reminder, !task.done, date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = "Reminder"
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// A one-off banner right now (break nudges). Not a task reminder, so it ignores `paused`.
    func notifyNow(_ title: String, _ body: String, id: String = "break-\(Date.now.timeIntervalSince1970)") {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func cancelAll() { center.removeAllPendingNotificationRequests() }

    func cancel(_ id: UUID) { center.removePendingNotificationRequests(withIdentifiers: [id.uuidString]) }

    // Show banners even though the app is running.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.identifier
        DispatchQueue.main.async { id == "wrapup" ? self.onWrapUp?() : self.onOpen?() }
        done()
    }
}

/// "9:08 PM" for today, "Oct 28 at 9:08 PM" otherwise.
func reminderLabel(_ date: Date, now: Date = .now) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    return Calendar.current.isDate(date, inSameDayAs: now) ? time : "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
}
