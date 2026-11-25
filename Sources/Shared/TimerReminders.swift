import OSLog
import SwiftUI
import UserNotifications

@MainActor
final class TimerReminders: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private var issue: Issue?

    nonisolated private static let identifier = "pomodoro.timer.finish"
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.pomodorotimer.apricot", category: "reminders")
    private let audio: TimerAudio
    private var lastChimeID: UUID?
    private var authorizationRefreshID: UUID?
    private var checkedAuthorization = false
    private var checkedPendingRequests = false
    private var notificationSoundEnabled = false
    private var chimeEnabled = true
    private var desiredDelivery: Delivery?
    private var scheduledDelivery: Delivery?
    private var inFlightDelivery: Delivery?
    private var cancelInFlightDelivery = false
    private var scheduling: Task<Void, Never>?

    init(audio: TimerAudio) {
        self.audio = audio
    }

    private struct Delivery: Equatable {
        let deadline: Date
        let monotonicDeadline: TimeInterval
        let mode: TimerMode
        let sound: Bool

        var identifier: String {
            TimerReminders.requestIdentifier(for: deadline)
        }
    }

    private enum Issue {
        case authorization, scheduling

        var message: String {
            switch self {
            case .authorization: "Couldn't request notification permission. Please try again."
            case .scheduling: "Couldn't schedule an alert for this session."
            }
        }
    }

    var errorMessage: String? { issue?.message }

    var authorized: Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func refreshAuthorization() async {
        let refreshID = UUID()
        authorizationRefreshID = refreshID
        let settings = await center.notificationSettings()
        guard authorizationRefreshID == refreshID else { return }
        checkedAuthorization = true
        if desiredDelivery != nil || status != settings.authorizationStatus {
            checkedPendingRequests = false
        }
        notificationSoundEnabled = settings.soundSetting == .enabled && settings.authorizationStatus != .provisional
        if status != settings.authorizationStatus { status = settings.authorizationStatus }
        if status != .notDetermined, issue == .authorization {
            issue = nil
        }
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            if issue == .authorization { issue = nil }
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
            issue = .authorization
        }
        await refreshAuthorization()
    }

    func sync(deadline: Date?, mode: TimerMode, sound: Bool) {
        chimeEnabled = sound
        guard checkedAuthorization || deadline == nil else { return }
        let delivery = authorized ? deadline.map { date in
            let elapsed = desiredDelivery?.deadline == date ? desiredDelivery?.monotonicDeadline : nil
            return Delivery(
                deadline: date,
                monotonicDeadline: elapsed ?? monotonicTime() + date.timeIntervalSinceNow,
                mode: mode,
                sound: sound
            )
        } : nil
        if let previous = desiredDelivery, previous.identifier != delivery?.identifier {
            // A naturally expired request can still be waiting for the system to deliver it.
            if previous.monotonicDeadline > monotonicTime() {
                center.removePendingNotificationRequests(withIdentifiers: [previous.identifier])
                if inFlightDelivery?.identifier == previous.identifier {
                    cancelInFlightDelivery = true
                }
            }
            scheduledDelivery = nil
        }
        desiredDelivery = delivery
        if (delivery == nil || delivery == scheduledDelivery), issue == .scheduling {
            issue = nil
        }
        guard scheduling == nil, !checkedPendingRequests || scheduledDelivery != delivery else { return }
        scheduling = Task { [weak self] in await self?.applyDesiredDelivery() }
    }

    func playChime(for completion: TimerCompletion) {
        guard completion.id != lastChimeID, chimeEnabled else { return }
        lastChimeID = completion.id
        guard notificationSoundEnabled else {
            audio.playChime()
            return
        }
        let requestID = Self.requestIdentifier(for: completion.notificationDeadline ?? completion.at)
        Task { [weak self] in
            guard let self else { return }
            let alreadyDelivered = await center.deliveredNotifications().contains {
                $0.request.identifier == requestID && $0.request.content.sound != nil
            }
            guard !alreadyDelivered, chimeEnabled, lastChimeID == completion.id else { return }
            audio.playChime()
        }
    }

    private func applyDesiredDelivery() async {
        defer { scheduling = nil }

        while true {
            if !checkedPendingRequests {
                checkedPendingRequests = true
                let pending = await center.pendingNotificationRequests()
                guard checkedPendingRequests else { continue }
                removeObsoleteRequests(pending)
                if let scheduledDelivery,
                   !pending.contains(where: { $0.identifier == scheduledDelivery.identifier }) {
                    self.scheduledDelivery = nil
                }
            }

            guard let delivery = desiredDelivery, delivery != scheduledDelivery else { return }
            let delay = delivery.monotonicDeadline - monotonicTime()
            guard delay > 0 else { return }
            let request = makeRequest(for: delivery, delay: delay)
            inFlightDelivery = delivery
            defer { finishScheduling(delivery) }

            do {
                try await center.add(request)
                if delivery.identifier == desiredDelivery?.identifier {
                    scheduledDelivery = delivery
                }
                if delivery == desiredDelivery, issue == .scheduling { issue = nil }
            } catch {
                logger.error("Notification scheduling failed: \(error.localizedDescription)")
                if delivery == desiredDelivery {
                    issue = .scheduling
                    return
                }
            }
        }
    }

    private func finishScheduling(_ delivery: Delivery) {
        if cancelInFlightDelivery, delivery.identifier != desiredDelivery?.identifier {
            // The first removal can run before the system has accepted the request.
            center.removePendingNotificationRequests(withIdentifiers: [delivery.identifier])
        }
        inFlightDelivery = nil
        cancelInFlightDelivery = false
    }

    private func removeObsoleteRequests(_ pending: [UNNotificationRequest]) {
        let prefix = Self.identifier + "."
        let desiredID = desiredDelivery?.identifier
        let instant = Date.now
        let obsoleteIDs = pending.compactMap { request -> String? in
            let identifier = request.identifier
            if identifier == Self.identifier {
                let nextFire = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                return (nextFire ?? .distantFuture) > instant ? identifier : nil
            }
            guard identifier != desiredID, identifier.hasPrefix(prefix),
                  let bits = UInt64(identifier.dropFirst(prefix.count)) else { return nil }
            let deadline = Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
            return deadline > instant ? identifier : nil
        }
        guard !obsoleteIDs.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: obsoleteIDs)
    }

    nonisolated private static func requestIdentifier(for deadline: Date) -> String {
        "\(identifier).\(deadline.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private func makeRequest(for delivery: Delivery, delay: TimeInterval) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = delivery.mode.completionTitle
        content.body = delivery.mode.completionBody
        content.threadIdentifier = Self.identifier
        if delivery.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("FocusChime.wav"))
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(identifier: delivery.identifier, content: content, trigger: trigger)
    }

}
