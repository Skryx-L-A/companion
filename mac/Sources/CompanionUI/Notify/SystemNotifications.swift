// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import UserNotifications

/// One message for the notification centre of the operating system.
public struct SystemNotice: Equatable, Sendable {
    /// What macOS files this message under. A second notice with the same identifier replaces
    /// the first, which is what keeps one session that asks twice from stacking up two rows.
    public var identifier: String
    public var title: String
    public var body: String
    /// The session a click leads to, nil for a message that belongs to no session.
    public var sessionId: SessionId?
    /// What a click acknowledges: the `ack` of a world's marked message, nil for every other
    /// message. Opening the banner is reading it.
    public var ack: String?

    public init(
        identifier: String, title: String, body: String, sessionId: SessionId? = nil,
        ack: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.sessionId = sessionId
        self.ack = ack
    }
}

/// The way out into the notification centre.
///
/// Behind a protocol so a test can read what would have been posted without a single banner
/// appearing on the screen of the person at the machine
/// (`regeln/tests-und-eingriffe.md`).
@MainActor
public protocol SystemNotifying: AnyObject {
    /// Whether this way exists in this run at all. False for a bare binary without an app
    /// bundle, where `UNUserNotificationCenter` has nothing to register a message against.
    var isAvailable: Bool { get }
    func post(_ notice: SystemNotice)
}

/// Posts through `UNUserNotificationCenter`.
///
/// Two things about that class shape this file. It needs a bundle identifier: called from a
/// bare binary — which is how this shell is run in development and in every smoke test —
/// `UNUserNotificationCenter.current()` raises an exception rather than returning nil, and an
/// exception in the report path would take the whole shell down over a banner. So nothing here
/// touches it before `Bundle.main.bundleIdentifier` says there is a bundle, and a run without
/// one says so once in the notice log instead.
///
/// And it asks the person for permission the first time something is posted. That question is
/// asked once per run, at the first message that would actually go out rather than at start:
/// a person who never switches the channel on is never asked. A refusal is taken quietly —
/// one line in the log, and the other channels carry on.
@MainActor
public final class UserNotificationBridge: NSObject, SystemNotifying {
    /// The key the session id travels under in the message's `userInfo`. Read in the delegate
    /// callback, which macOS calls on no actor of ours, so it is nonisolated.
    nonisolated static let sessionKey = "companion.session"
    /// The key the acknowledgement of a world's message travels under.
    nonisolated static let ackKey = "companion.ack"

    /// Says something to the notice log the chat panel shows. Set by the shell.
    public var onNotice: ((String) -> Void)?
    /// A click on a message. Carries the session it was about, nil for a message about none.
    public var onOpen: ((SessionId?) -> Void)?
    /// A click on a message that carried an acknowledgement.
    public var onAcknowledge: ((String) -> Void)?

    public let isAvailable: Bool
    /// What the permission question answered, nil while it has not been asked in this run.
    private var isAuthorized: Bool?
    /// True while the question is out, so a second report does not ask a second time.
    private var isAsking = false
    /// Messages that arrived while the question was out. They go once the answer is there,
    /// rather than being dropped: the first report is usually the one that mattered.
    private var waiting: [SystemNotice] = []
    /// Whether the missing bundle has already been said. It would otherwise be said again for
    /// every single report of a whole day of work.
    private var hasSaidThereIsNoBundle = false

    private let center: UNUserNotificationCenter?

    public override init() {
        // Read before anything of `UserNotifications` is touched. See the class comment: the
        // call below is the one that raises without a bundle.
        isAvailable = Bundle.main.bundleIdentifier != nil
        center = isAvailable ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    public func post(_ notice: SystemNotice) {
        guard let center else {
            guard !hasSaidThereIsNoBundle else { return }
            hasSaidThereIsNoBundle = true
            onNotice?("""
                System-Mitteilungen brauchen die gebaute App. Dieser Lauf ist ein nacktes \
                Programm ohne Bundle, deshalb bleibt der Weg über die Mitteilungszentrale \
                zu. Die Figur und der Ton melden sich weiter.
                """)
            return
        }
        switch isAuthorized {
        case .some(true):
            send(notice, through: center)
        case .some(false):
            // Said once when the refusal came in. Nothing more to say per message.
            return
        case .none:
            waiting.append(notice)
            askForPermission(center)
        }
    }

    private func askForPermission(_ center: UNUserNotificationCenter) {
        guard !isAsking else { return }
        isAsking = true
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.permissionAnswered(granted: granted, failure: message)
            }
        }
    }

    private func permissionAnswered(granted: Bool, failure: String?) {
        isAsking = false
        isAuthorized = granted
        let waiting = self.waiting
        self.waiting.removeAll()
        guard granted else {
            if let failure {
                onNotice?("Die Mitteilungszentrale hat die Anfrage abgelehnt: \(failure)")
            } else {
                onNotice?("""
                    System-Mitteilungen sind für den Companion nicht erlaubt. Der Kanal bleibt \
                    eingeschaltet und still; erlauben lässt es sich in der Systemeinstellung \
                    "Mitteilungen".
                    """)
            }
            return
        }
        guard let center else { return }
        for notice in waiting { send(notice, through: center) }
    }

    private func send(_ notice: SystemNotice, through center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        // No sound of its own: the tone is its own channel with its own switch, and a message
        // that brought a second sound along would go off twice for anybody who has both on.
        content.sound = nil
        var userInfo: [String: String] = [:]
        if let sessionId = notice.sessionId { userInfo[Self.sessionKey] = sessionId }
        if let ack = notice.ack { userInfo[Self.ackKey] = ack }
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let request = UNNotificationRequest(
            identifier: notice.identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.onNotice?("Eine System-Mitteilung ging nicht raus: \(message)")
            }
        }
    }
}

extension UserNotificationBridge: UNUserNotificationCenterDelegate {
    /// What a message does while this shell is the app in front.
    ///
    /// Without this, macOS drops a message of the running app on the floor. The companion is
    /// an accessory app whose panel never activates, so "in front" is a state it can be in
    /// while the person is looking at an editor — and a report that is silently dropped there
    /// is the failure this whole file exists to fix.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// A click on a message. The session id is read out here, where it is still a plain
    /// string, and the window work happens on the main actor.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo[UserNotificationBridge.sessionKey] as? String
        let ack = userInfo[UserNotificationBridge.ackKey] as? String
        Task { @MainActor [weak self] in
            if let ack { self?.onAcknowledge?(ack) }
            self?.onOpen?(sessionId)
        }
        completionHandler()
    }
}
