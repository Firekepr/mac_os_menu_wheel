import AppKit
import ApplicationServices
import SwiftUI

private final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class GestureController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsPermission = false
    @Published private(set) var status = "Ative o gesto para usar a roda sobre outros aplicativos."

    private let model = RunningApps()
    private let selection = WheelSelection()
    private var panel: WheelPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private var previewTimer: Timer?
    private var pendingDown: CGEvent?
    private var wheelIsOpen = false
    private var consumeUntilUp = false
    private var selectionOrigin = CGPoint.zero
    private var didMoveForSelection = false
    private let replayMarker: Int64 = 0x415050574845454C

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    func start() {
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            status = "Permita o AppWheel em Acessibilidade e depois clique em Ativar gesto global novamente."
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        let events: [CGEventType] = [.rightMouseDown, .rightMouseUp, .rightMouseDragged, .mouseMoved, .keyDown, .leftMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // The source is attached exclusively to the main run loop.
            return MainActor.assumeIsolated {
                Unmanaged<GestureController>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
            }
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            needsPermission = !AXIsProcessTrusted()
            status = "Não foi possível capturar o mouse. Confira Acessibilidade e tente ativar novamente."
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            status = "Não foi possível iniciar a captura. Tente ativar novamente."
            return
        }
        tap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isEnabled = true
        needsPermission = false
        status = "Gesto ativo · segure o botão direito por 300 ms, aponte e solte."
    }

    func stop() {
        // If a short click is in flight, restore its down before removing the tap.
        if let pendingDown { replay(pendingDown) }
        pendingDown = nil
        cancelHold()
        dismiss()
        consumeUntilUp = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isEnabled = false
        status = "Gesto desativado. O botão direito funciona normalmente."
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func preview() {
        guard pendingDown == nil, !consumeUntilUp else { return }
        show(at: NSEvent.mouseLocation)
        previewTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelForEnvironmentChange()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return unchanged
        }
        guard event.getIntegerValueField(.eventSourceUserData) != replayMarker else { return unchanged }

        switch type {
        case .rightMouseDown:
            dismiss()
            guard let copy = event.copy() else { return unchanged }
            pendingDown = copy
            consumeUntilUp = false
            cancelHold()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let down = self.pendingDown else { return }
                    self.pendingDown = nil
                    self.consumeUntilUp = true
                    self.show(at: self.appKitPoint(down.location))
                }
            }
            return nil

        case .rightMouseDragged:
            if let down = pendingDown, hypot(event.location.x - down.location.x, event.location.y - down.location.y) > 8 {
                // An early drag belongs to the underlying app, including its original down.
                cancelHold()
                pendingDown = nil
                replay(down)
                replay(event)
                return nil
            }
            if pendingDown != nil { return nil }
            if consumeUntilUp {
                if wheelIsOpen { updateSelection(at: appKitPoint(event.location)) }
                return nil
            }
            return unchanged

        case .rightMouseUp:
            cancelHold()
            if let down = pendingDown {
                pendingDown = nil
                // Post the pair together so the up cannot overtake the restored down.
                replay(down)
                replay(event)
                return nil
            }
            if consumeUntilUp {
                if wheelIsOpen { updateSelection(at: appKitPoint(event.location)) }
                let chosen = wheelIsOpen ? model.apps.first { $0.id == selection.id } : nil
                dismiss()
                consumeUntilUp = false
                if let chosen {
                    // Finish consuming the release and closing the panel before
                    // asking Launch Services to activate the selected app.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.model.activate(chosen) { [weak self] error in
                            guard let self, self.isEnabled else { return }
                            self.status = error ?? "Gesto ativo · última seleção: \(chosen.name)."
                        }
                    }
                }
                return nil
            }
            return unchanged

        case .mouseMoved:
            if wheelIsOpen { updateSelection(at: appKitPoint(event.location)) }
            return unchanged

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53,
               pendingDown != nil || wheelIsOpen || consumeUntilUp {
                cancelHold()
                consumeUntilUp = consumeUntilUp || pendingDown != nil
                pendingDown = nil
                dismiss()
                return nil
            }
            return unchanged

        case .leftMouseDown:
            cancelForEnvironmentChange()
            return unchanged

        default:
            return unchanged
        }
    }

    private func replay(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        copy.post(tap: .cgSessionEventTap)
    }

    private func appKitPoint(_ point: CGPoint) -> CGPoint {
        // Quartz uses top-left coordinates on the primary screen; AppKit uses bottom-left.
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func show(at point: CGPoint) {
        dismiss()
        model.refresh()
        guard !model.apps.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        let frame = WheelGeometry.panelFrame(around: point, visibleFrame: screen.visibleFrame)
        if panel == nil {
            let window = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.contentView = NSHostingView(rootView: FloatingWheel(model: model, selection: selection))
            panel = window
        }
        panel?.setFrame(frame, display: true)
        wheelIsOpen = true
        selectionOrigin = point
        didMoveForSelection = false
        selection.id = nil
        panel?.orderFrontRegardless()
    }

    private func updateSelection(at point: CGPoint) {
        guard let panel else { return }
        // Clamping at a display edge can move the wheel's center away from the press.
        // Releasing without moving must still cancel rather than select an app.
        if hypot(point.x - selectionOrigin.x, point.y - selectionOrigin.y) > 12 {
            didMoveForSelection = true
        }
        guard didMoveForSelection else { selection.id = nil; return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let id = WheelGeometry.index(at: local, count: model.apps.count, allowsBeyondEdge: true)
            .map { model.apps[$0].id }
        if selection.id != id { selection.id = id }
    }

    private func dismiss() {
        previewTimer?.invalidate()
        previewTimer = nil
        panel?.orderOut(nil)
        wheelIsOpen = false
        selection.id = nil
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    @objc private func cancelForEnvironmentChange() {
        cancelHold()
        consumeUntilUp = consumeUntilUp || pendingDown != nil
        pendingDown = nil
        dismiss()
    }

    @objc private func willTerminate() { stop() }
}

@MainActor
private final class WheelSelection: ObservableObject {
    @Published var id: pid_t?
}

private struct FloatingWheel: View {
    @ObservedObject var model: RunningApps
    @ObservedObject var selection: WheelSelection

    var body: some View {
        WheelView(model: model, selectedID: selection.id)
            .preferredColorScheme(.dark)
    }
}
