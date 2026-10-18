import Carbon.HIToolbox
import Foundation

/// System-wide chord that opens the notch composer. `RegisterEventHotKey` needs no Accessibility permission.
enum QuickCaptureChord: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, off

    static let key = "hermes.shortcut.capture"
    static var stored: Self { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .optionSpace }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .off: "Off"
        }
    }
    var modifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .off: nil
        }
    }
}

@MainActor
final class QuickCaptureHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    /// False when another app already owns the chord.
    private(set) var isRegistered = false

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let owner = Unmanaged<QuickCaptureHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private var applied: QuickCaptureChord?

    /// Re-registers when the stored chord changed; cheap enough to run on every defaults change.
    private func apply() {
        let chord = QuickCaptureChord.stored
        guard chord != applied else { return }
        applied = chord
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        isRegistered = false
        guard let modifiers = chord.modifiers else { return }
        let id = EventHotKeyID(signature: OSType(0x4845524D), id: 1) // 'HERM'
        isRegistered = RegisterEventHotKey(UInt32(kVK_Space), modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
}
