import Carbon
import Foundation

/// A system-wide shortcut: ⌃⌥⌘P pauses/resumes recording, ⌃⌥⌘N writes a note. Carbon hot keys need no
/// Accessibility permission.
final class GlobalHotKey {
    static let displayString = "⌃⌥⌘P"
    static let newNoteDisplayString = "⌃⌥⌘N"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let action: @MainActor () -> Void

    init(keyCode: Int = kVK_ANSI_P, id: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Every handler sees every hot key the app registered; each one acts only on its own.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in hotKey.action() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5243_4C4C), id: id) // "RCLL"
        RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | optionKey | controlKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
