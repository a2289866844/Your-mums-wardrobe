import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let identifier: UInt32
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        identifier = Self.nextID
        Self.nextID += 1
        Self.actions[identifier] = action
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == OSType(0x5445_4E44) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { HotKey.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5445_4E44), id: identifier)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Self.actions[identifier] = nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[identifier] = nil
    }
}
