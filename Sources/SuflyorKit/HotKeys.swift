import Carbon.HIToolbox
import Foundation

/// Глобальные горячие клавиши через Carbon RegisterEventHotKey: работает без разрешения
/// «Универсальный доступ», в отличие от NSEvent-мониторов.
final class HotKeys {
    struct Key {
        let code: UInt32
        let modifiers: UInt32
        let name: String
        let action: () -> Void
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    /// Клавиши, которые не удалось занять (уже заняты системой или другим приложением).
    private(set) var failed: [String] = []

    /// Регистрирует группу клавиш; занятые другими приложениями попадают в `failed`.
    func register(_ keys: [Key]) {
        installHandlerOnce()
        failed = []
        for k in keys {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(k.code, k.modifiers, EventHotKeyID(signature: OSType(0x5346_4C52), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs[id] = ref
                actions[id] = k.action
            } else {
                failed.append(k.name)
            }
        }
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hk = Unmanaged<HotKeys>.fromOpaque(user).takeUnretainedValue()
            hk.actions[id.id]?()
            return noErr
        }, 1, &spec, me, &handler)
    }

    static let ctrlOpt = UInt32(controlKey | optionKey)
}
