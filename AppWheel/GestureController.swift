import AppKit
import ApplicationServices
import SwiftUI
import Combine

extension Notification.Name {
    static let appWheelOpenMainWindow = Notification.Name("AppWheel.openMainWindow")
    static let appWheelToggleMainWindow = Notification.Name("AppWheel.toggleMainWindow")
}

private final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct HoldPreviewTiming: Equatable {
    let startedAt: TimeInterval
    let duration: TimeInterval

    func progress(at uptime: TimeInterval) -> Double {
        min(1, max(0, (uptime - startedAt) / duration))
    }
}

@MainActor
final class GestureController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsPermission = false
    @Published private(set) var status = L10n.text("Ative o gesto para usar a roda sobre outros aplicativos.")
    let preferences: WheelPreferences
    let favorites: AppFavorites
    let exceptions: AppExceptions

    private let model: RunningApps
    private let selection = WheelInteraction()
    private var panel: WheelPanel?
    private var mainWindow: NSWindow?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var movementTap: CFMachPort?
    private var movementSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private var holdPreviewPanel: WheelPanel?
    private var holdPreviewGeneration = 0
    private(set) var holdPreviewTiming: HoldPreviewTiming?
    private var previewTimer: Timer?
    private var pageScrollDelta = 0.0
    private var lastPageScrollTime = -Double.infinity
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
    private let keyboardHotKey = WheelHotKey()
    private var shortcutSubscription: AnyCancellable?
    private var shortcutExceptionsSubscription: AnyCancellable?
    private var registeredKeyboardShortcut: WheelKeyboardShortcut?
    private var keyboardWheelIsOpen = false
    private var keyboardShortcutIsHeld = false

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
        NotificationCenter.default.addObserver(self, selector: #selector(openMainWindow),
                                               name: .appWheelOpenMainWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleMainWindow),
                                               name: .appWheelToggleMainWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreGestureIfNeeded),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelForEnvironmentChange),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidActivate),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        keyboardHotKey.pressed = { [weak self] in self?.keyboardShortcutPressed() }
        keyboardHotKey.released = { [weak self] in self?.keyboardShortcutReleased() }
        shortcutSubscription = preferences.$keyboardShortcut.combineLatest(preferences.$isRecordingKeyboardShortcut)
            .sink { [weak self] _, _ in
                // @Published emits before the new preference is stored.
                DispatchQueue.main.async { self?.configureKeyboardShortcut() }
            }
        shortcutExceptionsSubscription = exceptions.$apps.sink { [weak self] _ in
            DispatchQueue.main.async { self?.configureKeyboardShortcut() }
        }
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
            status = L10n.text("Gesto salvo como ativado. Falta a permissão de Acessibilidade para esta versão do AppWheel.")
            // Restoring a preference must never produce a permission-dialog loop.
            if requestPermission && !didRequestPermission {
                didRequestPermission = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        guard installInputCapture() else { return }
        isEnabled = true
        needsPermission = false
        status = L10n.text("Gesto ativo. As preferências são aplicadas a cada novo gesto.")
    }

    private func installInputCapture() -> Bool {
        if tap != nil { return true }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                     .  rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                     .otherMouseDown, .otherMouseUp, .otherMouseDragged, .keyDown, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // The source is attached exclusively to the main run loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<GestureController>.fromOpaque(context).takeUnretainedValue()
                guard owner.isEnabled || owner.keyboardWheelIsOpen else { return Unmanaged.passUnretained(event) }
                return owner.handle(type, event: event)
            }
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            needsPermission = !AXIsProcessTrusted()
            status = L10n.text("Não foi possível capturar o mouse. Confira Acessibilidade e tente ativar novamente.")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            status = L10n.text("Não foi possível iniciar a captura. Tente ativar novamente.")
            return false
        }
        tap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        defaults.set(false, forKey: enabledPreferenceKey)
        shutDown()
        needsPermission = false
        status = L10n.text("Gesto desativado. O mouse funciona normalmente.")
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
        keyboardWheelIsOpen = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        if let movementTap { CFMachPortInvalidate(movementTap) }
        if let movementSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), movementSource, .commonModes) }
        movementTap = nil
        movementSource = nil
        isEnabled = false
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openMainWindow() {
        cancelForEnvironmentChange()
        // Become a regular app only for the main window, making it available
        // in the Dock and Command-Tab even after another app gains focus.
        NSApplication.shared.setActivationPolicy(.regular)
        if mainWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "AppWheel"
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        guard let window = mainWindow else { return }
        if !selection.isMainWindowOpen {
            window.contentView = NSHostingView(rootView:
                ContentView(preferences: preferences, favorites: favorites).environmentObject(self))
            selection.isMainWindowOpen = true
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Explicit user requests must bring the app forward even when the
        // gesture started in another application.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self, weak window] _, error in
            Task { @MainActor in
                guard let self, let window, self.selection.isMainWindowOpen,
                      window.isVisible, !window.isMiniaturized else { return }
                if let error {
                    self.status = L10n.text("Não foi possível trazer o AppWheel à frente: %@", error.localizedDescription)
                } else {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    @objc func toggleMainWindow() {
        if selection.isMainWindowOpen {
            cancelForEnvironmentChange()
            mainWindow?.close()
        } else {
            openMainWindow()
        }
    }

    func preview() {
        guard pendingDown == nil, !consumeUntilUp, !keyboardWheelIsOpen else { return }
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

        if type == .scrollWheel {
            guard wheelIsOpen, model.pageCount > 1 else { return unchanged }
            handlePageScroll(event)
            return nil
        }

        if keyboardWheelIsOpen {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                cancelForEnvironmentChange()
                return nil
            }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                cancelForEnvironmentChange()
            }
            return unchanged
        }

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
            // Freeze the deadline for both the timer and its visual feedback.
            let delay = preferences.holdDelay
            if preferences.showsHoldPreview {
                beginHoldPreview(at: appKitPoint(copy.location), duration: delay)
            }
            holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let down = self.pendingDown else { return }
                    self.cancelHold()
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
                completeSelection()
                consumeUntilUp = false
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

    private func handlePageScroll(_ event: CGEvent) {
        guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let delta = event.getDoubleValueField(continuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return }

        if continuous {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPageScrollTime >= 0.18 else { return }
            if pageScrollDelta.sign != delta.sign { pageScrollDelta = 0 }
            pageScrollDelta += delta
            guard abs(pageScrollDelta) >= 32 else { return }
            lastPageScrollTime = now
            pageScrollDelta = 0
        }

        guard model.movePage(by: delta < 0 ? 1 : -1) else { return }
        selection.reset()
        selectionOrigin = appKitPoint(event.location)
        didMoveForSelection = false
    }

    private func completeSelection() {
        let shouldToggleMainWindow = wheelIsOpen && selection.isOpenMainWindowHovered
        let closeTarget = wheelIsOpen && selection.isCloseHovered
            ? model.apps.first { $0.id == selection.closeTargetID } : nil
        let chosen = wheelIsOpen ? model.apps.first { $0.id == selection.id } : nil
        dismiss()
        if shouldToggleMainWindow {
            DispatchQueue.main.async { [weak self] in self?.toggleMainWindow() }
        } else if let closeTarget {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let error = self.model.requestQuit(closeTarget)
                self.status = error ?? L10n.text("Encerramento solicitado para %@.", closeTarget.name)
            }
        } else if let chosen {
            // Consume the release and start the exit before activating
            // the selected app; activation does not wait for the fade.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.activate(chosen) { [weak self] error in
                    guard let self else { return }
                    self.status = error ?? L10n.text("Gesto ativo · última seleção: %@.", chosen.name)
                }
            }
        }
    }

    private func configureKeyboardShortcut() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        let suspended = preferences.isRecordingKeyboardShortcut
            || exceptions.contains(bundleIdentifier: frontmostBundleIdentifier())
        let shortcut = suspended ? nil : preferences.keyboardShortcut
        guard shortcut != registeredKeyboardShortcut || preferences.keyboardShortcutError != nil else { return }
        if keyboardWheelIsOpen { cancelForEnvironmentChange() }
        keyboardShortcutIsHeld = false
        let error = keyboardHotKey.configure(shortcut)
        registeredKeyboardShortcut = error == nil ? shortcut : nil
        preferences.keyboardShortcutError = error
    }

    private func keyboardShortcutPressed() {
        guard !keyboardShortcutIsHeld else { return }
        keyboardShortcutIsHeld = true
        guard !preferences.isRecordingKeyboardShortcut, preferences.keyboardShortcut != nil,
              !keyboardWheelIsOpen, pendingDown == nil, !consumeUntilUp,
              !exceptions.contains(bundleIdentifier: frontmostBundleIdentifier()) else { return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            status = L10n.text("Conceda Acessibilidade para usar a roda pelo teclado.")
            openMainWindow()
            return
        }
        guard installInputCapture() else { return }
        needsPermission = false
        keyboardWheelIsOpen = true
        show(at: NSEvent.mouseLocation)
    }

    private func keyboardShortcutReleased() {
        keyboardShortcutIsHeld = false
        guard keyboardWheelIsOpen else { return }
        // Preserve the last pointer selection; opening itself never selects.
        updateSelection(at: NSEvent.mouseLocation)
        keyboardWheelIsOpen = false
        completeSelection()
        releaseInputCaptureIfUnused()
    }

    private func releaseInputCaptureIfUnused() {
        guard !isEnabled, !keyboardWheelIsOpen else { return }
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
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
        model.refresh(capacity: preferences.wheelCapacity)
        pageScrollDelta = 0
        lastPageScrollTime = -Double.infinity
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
            window.contentView = NSHostingView(rootView: FloatingWheel(model: model, selection: selection, preferences: preferences))
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
        enableMovementTracking()
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
        // Releasing without deliberate movement cancels rather than selecting
        // an app, including when the gesture begins at a display edge.
        if hypot(point.x - selectionOrigin.x, point.y - selectionOrigin.y) > 12 {
            didMoveForSelection = true
        }
        guard didMoveForSelection else { selection.select(nil, canRevealClose: false); return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        selection.update(at: local, slots: model.slots, allowsBeyondEdge: true)
    }

    private func dismiss(animated: Bool = true) {
        if let movementTap { CGEvent.tapEnable(tap: movementTap, enable: false) }
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
        holdPreviewGeneration += 1
        holdPreviewTiming = nil
        holdPreviewPanel?.orderOut(nil)
        // Release the TimelineView as well, so no animation runs while hidden.
        holdPreviewPanel?.contentView = nil
    }

    private func beginHoldPreview(at point: CGPoint, duration: TimeInterval) {
        let timing = HoldPreviewTiming(startedAt: ProcessInfo.processInfo.systemUptime, duration: duration)
        holdPreviewTiming = timing
        let generation = holdPreviewGeneration
        // Quick clicks should not flash an overlay. Defer window work outside
        // the mouse callback; the arc still measures from the original press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.pendingDown != nil,
                  self.holdPreviewGeneration == generation,
                  self.holdPreviewTiming == timing,
                  timing.progress(at: ProcessInfo.processInfo.systemUptime) < 1 else { return }
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
            let frame = WheelGeometry.panelFrame(around: point, visibleFrame: screen.visibleFrame, diameter: 64)
            if self.holdPreviewPanel == nil {
                let panel = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .popUpMenu
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                self.holdPreviewPanel = panel
            }
            self.holdPreviewPanel?.contentView = NSHostingView(rootView: HoldPreview(timing: timing))
            self.holdPreviewPanel?.setFrame(frame, display: true)
            self.holdPreviewPanel?.orderFrontRegardless()
        }
    }

    @objc private func cancelForEnvironmentChange() {
        cancelHold()
        consumeUntilUp = consumeUntilUp || pendingDown != nil
        pendingDown = nil
        keyboardWheelIsOpen = false
        dismiss(animated: false)
        releaseInputCaptureIfUnused()
    }

    @objc private func workspaceDidActivate() {
        cancelForEnvironmentChange()
        // Do not reserve the combination while an excluded app has focus.
        configureKeyboardShortcut()
    }

    @objc private func willTerminate() {
        _ = keyboardHotKey.configure(nil)
        shutDown()
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // A retained NSWindow must not retain an invisible SwiftUI preview,
        // its subscriptions, or its memory-sampling task after closing.
        window.contentView = nil
        selection.isMainWindowOpen = false
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func enableMovementTracking() {
        // Held-button motion is already delivered as drag events. Unpressed
        // movement is only useful while the floating preview is visible.
        guard isEnabled || keyboardWheelIsOpen else { return }
        if let movementTap {
            CGEvent.tapEnable(tap: movementTap, enable: true)
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<GestureController>.fromOpaque(context).takeUnretainedValue()
                if type == .mouseMoved, owner.wheelIsOpen {
                    owner.updateSelection(at: owner.appKitPoint(event.location))
                } else if owner.wheelIsOpen,
                          type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
                          let tap = owner.movementTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly,
                                         eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
                                         callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        movementTap = tap
        movementSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

private struct HoldPreview: View {
    let timing: HoldPreviewTiming

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let progress = timing.progress(at: ProcessInfo.processInfo.systemUptime)
            ZStack {
                Circle().stroke(.black.opacity(0.22), lineWidth: 5)
                Circle().stroke(.white.opacity(0.30), lineWidth: 2.5)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .accentColor.opacity(0.35), radius: 3)
            }
            .frame(width: 42, height: 42)
            .frame(width: 64, height: 64)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FloatingWheel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: RunningApps
    @ObservedObject var selection: WheelInteraction
    @ObservedObject var preferences: WheelPreferences

    var body: some View {
        WheelWithActions(model: model, interaction: selection, isActive: selection.isPresented,
                         theme: preferences.theme, isMainWindowOpen: selection.isMainWindowOpen)
            .preferredColorScheme(.dark)
            .scaleEffect(reduceMotion || selection.isPresented ? 1 : 0.90)
            .opacity(selection.isPresented ? 1 : 0)
    }
}
