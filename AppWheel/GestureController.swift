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
    let preferences: WheelPreferences
    let favorites: AppFavorites
    let exceptions: AppExceptions

    private let model: RunningApps
    private let selection = WheelInteraction()
    private var panel: WheelPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private var previewTimer: Timer?
    private var pendingDown: CGEvent?
    private var wheelIsOpen = false
    private var consumeUntilUp = false
    private var bypassTriggerButton = false
    private var activePressButton: MouseTriggerButton?
    private var presentedDiameter: CGFloat = WheelGeometry.size
    private var selectionOrigin = CGPoint.zero
    private var didMoveForSelection = false
    private var presentationGeneration = 0
    private let replayMarker: Int64 = 0x415050574845454C
    private let defaults: UserDefaults
    private let frontmostBundleIdentifier: () -> String?
    private let postEvent: (CGEvent) -> Void
    private let enabledPreferenceKey = "globalGestureEnabled"
    private var didRequestPermission = false

    init(defaults: UserDefaults = .standard,
         frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.defaults = defaults
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.postEvent = postEvent
        let favorites = AppFavorites(defaults: defaults)
        self.favorites = favorites
        self.model = RunningApps(favorites: favorites, observesFavorites: false)
        self.preferences = WheelPreferences(defaults: defaults)
        self.exceptions = AppExceptions(defaults: defaults)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreGestureIfNeeded),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DispatchQueue.main.async { [weak self] in self?.restoreGestureIfNeeded() }
    }

    @objc private func restoreGestureIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              defaults.bool(forKey: enabledPreferenceKey), !isEnabled else { return }
        start(requestPermission: false)
    }

    func start(requestPermission: Bool = true) {
        defaults.set(true, forKey: enabledPreferenceKey)
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            status = "Gesto salvo como ativado. Falta a permissão de Acessibilidade para esta versão do AppWheel."
            // Restoring a preference must never produce a permission-dialog loop.
            if requestPermission && !didRequestPermission {
                didRequestPermission = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                     .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                     .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .keyDown]
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
        status = "Gesto ativo. As preferências são aplicadas a cada novo gesto."
    }

    func stop() {
        defaults.set(false, forKey: enabledPreferenceKey)
        shutDown()
        needsPermission = false
        status = "Gesto desativado. O mouse funciona normalmente."
    }

    /// Release the capture on quit without changing the user's saved choice.
    func shutDown() {
        // If a short click is in flight, restore its down before removing the tap.
        if let pendingDown { replay(pendingDown) }
        pendingDown = nil
        cancelHold()
        dismiss(animated: false)
        consumeUntilUp = false
        bypassTriggerButton = false
        activePressButton = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isEnabled = false
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

    func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelForEnvironmentChange()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return unchanged
        }
        guard event.getIntegerValueField(.eventSourceUserData) != replayMarker else { return unchanged }

        // Freeze the button for a complete press, including an excluded app or
        // an early drag. A preference change must never split a down/up pair.
        let button = activePressButton ?? preferences.triggerButton
        if button.matches(event, type: type, phase: button.down) {
            activePressButton = button
            dismiss()
            cancelHold()
            pendingDown = nil
            consumeUntilUp = false
            bypassTriggerButton = exceptions.contains(bundleIdentifier: frontmostBundleIdentifier())
            // Decide once for the whole press. Excluded apps receive the original
            // down, drags and up immediately, without delaying or replaying them.
            if bypassTriggerButton { return unchanged }
            guard let copy = event.copy() else { return unchanged }
            pendingDown = copy
            holdTimer = Timer.scheduledTimer(withTimeInterval: preferences.holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let down = self.pendingDown else { return }
                    self.pendingDown = nil
                    self.consumeUntilUp = true
                    guard !self.exceptions.contains(bundleIdentifier: self.frontmostBundleIdentifier()) else { return }
                    self.show(at: self.appKitPoint(down.location))
                }
            }
            return nil
        }
        if button.matches(event, type: type, phase: button.drag) {
            if bypassTriggerButton { return unchanged }
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
        }
        if button.matches(event, type: type, phase: button.up) {
            defer { activePressButton = nil }
            if bypassTriggerButton {
                bypassTriggerButton = false
                return unchanged
            }
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
                let closeTarget = wheelIsOpen && selection.isCloseHovered
                    ? model.apps.first { $0.id == selection.closeTargetID } : nil
                let chosen = wheelIsOpen ? model.apps.first { $0.id == selection.id } : nil
                dismiss()
                consumeUntilUp = false
                if let closeTarget {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let error = self.model.requestQuit(closeTarget)
                        self.status = error ?? "Encerramento solicitado para \(closeTarget.name)."
                    }
                } else if let chosen {
                    // Consume the release and start the exit before activating
                    // the selected app; activation does not wait for the fade.
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
        }

        switch type {
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

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancelForEnvironmentChange()
            return unchanged

        default:
            return unchanged
        }
    }

    private func replay(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: replayMarker)
        postEvent(copy)
    }

    private func appKitPoint(_ point: CGPoint) -> CGPoint {
        // Quartz uses top-left coordinates on the primary screen; AppKit uses bottom-left.
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func show(at point: CGPoint) {
        dismiss(animated: false)
        model.refresh()
        guard !model.apps.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        presentedDiameter = WheelActionGeometry.fittingDiameter(CGFloat(preferences.wheelDiameter), available: screen.visibleFrame.size)
        let frame = WheelActionGeometry.panelFrame(around: point, diameter: presentedDiameter, visibleFrame: screen.visibleFrame)
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
        selection.diameter = presentedDiameter
        panel?.setFrame(frame, display: true)
        wheelIsOpen = true
        selectionOrigin = point
        didMoveForSelection = false
        selection.reset()
        // Lay out the compact, transparent state reset by dismiss(). The hosting
        // view is reused, so onAppear alone would not replay the entrance.
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.orderFrontRegardless()
        let generation = presentationGeneration
        // Start after the initial compact, transparent state has been laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wheelIsOpen, self.presentationGeneration == generation else { return }
            let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .easeOut(duration: 0.10) : .spring(duration: 0.22, bounce: 0.12)
            withAnimation(animation) {
                self.selection.isPresented = true
            }
        }
    }

    private func updateSelection(at point: CGPoint) {
        guard let panel else { return }
        // Clamping at a display edge can move the wheel's center away from the press.
        // Releasing without moving must still cancel rather than select an app.
        if hypot(point.x - selectionOrigin.x, point.y - selectionOrigin.y) > 12 {
            didMoveForSelection = true
        }
        guard didMoveForSelection else { selection.select(nil, canRevealClose: false); return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        selection.update(at: local, model: model, allowsBeyondEdge: true)
    }

    private func dismiss(animated: Bool = true) {
        selection.select(selection.id, canRevealClose: false)
        previewTimer?.invalidate()
        previewTimer = nil

        if !animated {
            presentationGeneration += 1
            panel?.orderOut(nil)
            wheelIsOpen = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection.isPresented = false
                selection.reset()
            }
            return
        }

        guard wheelIsOpen else { return }
        wheelIsOpen = false
        presentationGeneration += 1
        let generation = presentationGeneration
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.14
        // Keep the last selection visible during the exit. An earlier completion
        // must never hide a wheel that has already been opened again.
        withAnimation(.easeIn(duration: duration), completionCriteria: .removed) {
            selection.isPresented = false
        } completion: { [weak self] in
            guard let self, self.presentationGeneration == generation, !self.wheelIsOpen else { return }
            self.panel?.orderOut(nil)
            self.selection.reset()
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    @objc private func cancelForEnvironmentChange() {
        cancelHold()
        consumeUntilUp = consumeUntilUp || pendingDown != nil
        pendingDown = nil
        dismiss(animated: false)
    }

    @objc private func willTerminate() { shutDown() }
}

private struct FloatingWheel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: RunningApps
    @ObservedObject var selection: WheelInteraction

    var body: some View {
        WheelWithActions(model: model, interaction: selection)
            .preferredColorScheme(.dark)
            .scaleEffect(reduceMotion || selection.isPresented ? 1 : 0.90)
            .opacity(selection.isPresented ? 1 : 0)
    }
}
