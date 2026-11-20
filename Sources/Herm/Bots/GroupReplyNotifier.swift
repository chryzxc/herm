import AppKit
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// A group reply banner was clicked; `userInfo` carries the room and event.
    static let hermOpenGroupRoom = Notification.Name("hermOpenGroupRoom")
}

/// The banner for a member reply that lands while its room is off screen:
/// the member's face, "Name in Room", and the reply's first line.
@MainActor
enum GroupReplyNotifier {
    nonisolated static let roomKey = "herm.group-room"
    nonisolated static let eventKey = "herm.group-event"

    static func post(room: GroupRoom, event: GroupRoomEvent, defaults: UserDefaults = .standard) {
        guard case .member(let memberID) = event.kind, HermesAppRuntime.supportsUserNotifications else { return }
        let member = room.member(memberID)
        let notice = HermNotice(
            kind: .completion, source: .activity, profileID: member?.profile, sourceID: room.id, eventID: event.id)
        guard HermNotificationPreferences.allows(notice, defaults: defaults) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(member?.displayName ?? memberID) in \(room.name)"
        content.body = String(firstLine(GenerativeUIIntegration.plainText(event.text)).prefix(240))
        content.sound = HermNotificationPreferences.sound(defaults: defaults)
        content.threadIdentifier = "group:\(room.id)"
        content.userInfo = [roomKey: room.id, eventKey: event.id]
        if let member, let attachment = faceAttachment(for: member.profile) { content.attachments = [attachment] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "group:\(room.id):\(event.id)", content: content, trigger: nil))
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Routes a clicked banner to the room; false when it isn't a group banner.
    static func open(userInfo: [AnyHashable: Any]) -> Bool {
        guard let roomID = userInfo[roomKey] as? String else { return false }
        NotificationCenter.default.post(
            name: .hermOpenGroupRoom, object: nil, userInfo: [roomKey: roomID, eventKey: userInfo[eventKey] ?? ""])
        return true
    }

    /// The member's stored avatar, else its happy Herm face, as a PNG the system can attach.
    private static func faceAttachment(for profile: String) -> UNNotificationAttachment? {
        let png: Data?
        if let data = BotMentions.avatar(profile), !BotAvatarView.showsHermFace(data, id: profile) {
            png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        } else {
            let renderer = ImageRenderer(content: BotFaceMark(id: profile, size: 96, animated: false, mood: .happy))
            renderer.scale = 2
            png = renderer.nsImage
                .flatMap { $0.tiffRepresentation }
                .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        guard let png else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-group-face-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "face", url: url)
    }
}
