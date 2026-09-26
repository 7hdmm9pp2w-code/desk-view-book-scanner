import Carbon.HIToolbox
import Foundation

/// Globaler Hotkey über Carbon `RegisterEventHotKey`. Die einzige Variante ohne
/// Bedienungshilfen-Freigabe; sie funktioniert auch, wenn Desk View vorn liegt.
@MainActor
final class HotKey {
    static let captureKeyCode = UInt32(kVK_ANSI_S)
    static let captureModifiers = UInt32(cmdKey | optionKey)
    static let captureDisplayName = "⌥⌘S"

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = Array("DVBS".utf8).reduce(0) { ($0 << 8) | OSType($1) }

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private let action: @MainActor () -> Void

    /// `nil`, wenn das System die Kombination verweigert (meist: von einer anderen App belegt).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = Self.nextID
        Self.nextID += 1
        self.action = action
        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { return nil }
        Self.registry[id] = self
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            // Carbon liefert Tastatur-Events auf dem Main-Thread.
            MainActor.assumeIsolated {
                HotKey.registry[id]?.action()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
