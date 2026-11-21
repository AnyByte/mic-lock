// MicLock: keeps the built-in MacBook microphone as the default input at full volume.
// macOS makes every newly connected headset the input device (and drops Bluetooth
// headphones into the low-quality headset profile); MicLock switches straight back.
//
// Lives in the menu bar; the icon can be hidden in Settings, and opening the app again
// (Finder, Spotlight, Launchpad) brings the Settings window back. miclock://toggle, on, off
// switch the lock from Shortcuts / Control Center.
import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

// MARK: - CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func readUInt32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
    var addr = addr, value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func allDevices() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasInput(_ device: AudioObjectID) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
}

func transport(_ device: AudioObjectID) -> UInt32? { readUInt32(device, address(kAudioDevicePropertyTransportType)) }

func deviceName(_ device: AudioObjectID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return "Unknown" }
    return name.takeRetainedValue() as String
}

func builtInMic() -> AudioObjectID? {
    allDevices().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
}

func defaultInput() -> AudioObjectID? { readUInt32(systemObject, address(kAudioHardwarePropertyDefaultInputDevice)) }

func setDefaultInput(_ device: AudioObjectID) {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice), value = device
    AudioObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
}

// Input volume lives on the main element on some devices and per channel on others.
let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

func maximizeInputVolume(_ device: AudioObjectID) {
    for element in volumeElements {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
        var current: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current)
        if current < 1.0 {
            var full: Float32 = 1.0
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, &full)
        }
    }
}

func inputVolume(_ device: AudioObjectID) -> Float32? {
    for element in volumeElements {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr { return value }
    }
    return nil
}

// MARK: - State

final class Model: ObservableObject {
    private let defaults = UserDefaults.standard
    weak var controller: Controller?

    @Published var lockEnabled: Bool { didSet { save("enabled", lockEnabled); controller?.lockChanged() } }
    @Published var fullVolume: Bool { didSet { save("fullVolume", fullVolume); controller?.enforce() } }
    @Published var showInMenuBar: Bool { didSet { save("showInMenuBar", showInMenuBar); controller?.updateStatusItem() } }
    @Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { if !syncingLogin && openAtLogin != oldValue { controller?.setOpenAtLogin(openAtLogin) } }
    }
    private var syncingLogin = false

    // Reflect the real login item state (the user can change it in System Settings) without re-registering.
    func syncOpenAtLogin() {
        syncingLogin = true
        openAtLogin = SMAppService.mainApp.status == .enabled
        syncingLogin = false
    }
    @Published var currentInput = ""
    @Published var currentVolume: Int?

    init() {
        // "enabled" is the key used by MicLock before the settings window existed.
        lockEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        fullVolume = defaults.object(forKey: "fullVolume") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
    }

    private func save(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
}

// MARK: - App

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let showSettingsNote = Notification.Name("org.anybyte.miclock.show-settings")

    let model = Model()
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var watchedMic: AudioObjectID?
    var displaced: AudioObjectID?  // input MicLock replaced, handed back when the lock goes off
    var enforcePending = false
    var hud: NSPanel?
    var hudTimer: Timer?
    var launchedAtLogin = false

    func applicationWillFinishLaunching(_ note: Notification) {
        // Read here: the launch Apple event is gone by didFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:_:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // One instance only: a second copy (another build, the release zip) wakes the
        // running one and quits, so URLs and reopen always reach the same process.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) {
            DistributedNotificationCenter.default().postNotificationName(
                Controller.showSettingsNote, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettings), name: Controller.showSettingsNote, object: nil)

        model.controller = self
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main) { [weak self] _, _ in self?.scheduleEnforce() }
        }
        updateStatusItem()
        enforce()
        // install.sh passes this so a local install starts at login like the old LaunchAgent did.
        if CommandLine.arguments.contains("--enable-login-item"), SMAppService.mainApp.status != .enabled {
            setOpenAtLogin(true)
        }
        // Hidden icon and started by hand: the window is the only sign the app is running.
        if !model.showInMenuBar && !launchedAtLogin { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Lock

    func lockChanged() {
        if model.lockEnabled { enforce() } else { restoreExternalInput() }
        updateStatusItem()
    }

    // CoreAudio fires several notifications per device change (a Bluetooth connect sends a burst).
    func scheduleEnforce() {
        guard !enforcePending else { return }
        enforcePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enforcePending = false
            self?.enforce()
        }
    }

    func enforce() {
        if model.lockEnabled, let mic = builtInMic() {
            watchVolume(mic)
            if let current = defaultInput(), current != mic {
                displaced = current
                setDefaultInput(mic)
            }
            if model.fullVolume { maximizeInputVolume(mic) }
        }
        refreshInputInfo()
    }

    // Zoom, Teams and others lower the input gain on their own; while the lock is on, put it back.
    func watchVolume(_ mic: AudioObjectID) {
        guard watchedMic != mic else { return }
        watchedMic = mic
        for element in volumeElements {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            guard AudioObjectHasProperty(mic, &addr) else { continue }
            AudioObjectAddPropertyListenerBlock(mic, &addr, .main) { [weak self] _, _ in self?.scheduleEnforce() }
        }
    }

    // Lock off: give the input back to the headset, as macOS would have done on connect.
    func restoreExternalInput() {
        let mic = builtInMic()
        let inputs = allDevices().filter { hasInput($0) && $0 != mic }
        if let previous = displaced, inputs.contains(previous) {
            setDefaultInput(previous)
        } else {
            // Prefer a Bluetooth headset over USB gear (audio interfaces, DJ controllers); skip virtual devices.
            func rank(_ device: AudioObjectID) -> Int {
                switch transport(device) {
                case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 0
                case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return 9
                default: return 1
                }
            }
            if let best = inputs.filter({ rank($0) < 9 }).min(by: { rank($0) < rank($1) }) { setDefaultInput(best) }
        }
        refreshInputInfo()
    }

    func refreshInputInfo() {
        guard let input = defaultInput() else { return }
        let name = deviceName(input)
        let volume = inputVolume(input).map { Int(($0 * 100).rounded()) }
        if model.currentInput != name { model.currentInput = name }
        if model.currentVolume != volume { model.currentVolume = volume }
    }

    // MARK: URL scheme (Shortcuts, Control Center)

    @objc func handleURL(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let host = URL(string: string)?.host?.lowercased() else { return }
        switch host {
        case "on": model.lockEnabled = true
        case "off": model.lockEnabled = false
        case "toggle": model.lockEnabled.toggle()
        case "settings": showSettings(); return
        default: return
        }
        showHUD()
    }

    // Small icon-only pill under the right end of the menu bar, where the Shortcuts run
    // indicator appears: Control Center shortcut tiles can't show state themselves.
    func showHUD() {
        hud?.orderOut(nil)
        let size = NSSize(width: 44, height: 30)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        let icon = NSImageView(frame: NSRect(x: 10, y: 4, width: 24, height: 22))
        icon.image = NSImage(systemSymbolName: model.lockEnabled ? "mic.fill" : "mic.slash.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = model.lockEnabled ? .systemGreen : .systemGray
        background.addSubview(icon)
        panel.contentView = background
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame  // below the menu bar
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 6))
        }
        panel.orderFrontRegardless()
        hud = panel
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hud?.orderOut(nil)
        }
    }

    // MARK: Menu bar

    func updateStatusItem() {
        guard model.showInMenuBar else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        let image = NSImage(systemSymbolName: model.lockEnabled ? "mic.fill" : "mic.slash",
                            accessibilityDescription: "MicLock")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = model.lockEnabled ? "MicLock: built-in microphone locked" : "MicLock: off"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshInputInfo()
        menu.removeAllItems()
        let input = NSMenuItem(title: "Input: \(model.currentInput)", action: nil, keyEquivalent: "")
        input.isEnabled = false
        menu.addItem(input)
        if let volume = model.currentVolume {
            let level = NSMenuItem(title: "Input volume: \(volume) %", action: nil, keyEquivalent: "")
            level.isEnabled = false
            menu.addItem(level)
        }
        menu.addItem(.separator())
        let lock = NSMenuItem(title: "Lock Built-in Microphone", action: #selector(toggleLock), keyEquivalent: "")
        lock.state = model.lockEnabled ? .on : .off
        lock.target = self
        menu.addItem(lock)
        let volume = NSMenuItem(title: "Keep Input Volume at 100 %", action: #selector(toggleVolume), keyEquivalent: "")
        volume.state = model.fullVolume ? .on : .off
        volume.target = self
        menu.addItem(volume)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit MicLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleLock() { model.lockEnabled.toggle() }
    @objc func toggleVolume() { model.fullVolume.toggle() }

    // MARK: Settings window

    @objc func showSettings() {
        refreshInputInfo()
        model.syncOpenAtLogin()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "MicLock"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // A Dock icon and Cmd-Tab entry while the window is open, back to a pure agent after.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MicLock: login item: %@", error.localizedDescription)
        }
        DispatchQueue.main.async { self.model.syncOpenAtLogin() }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MicLock").font(.title2.weight(.semibold))
                    Text(statusLine).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Form {
                Section {
                    Toggle(isOn: $model.lockEnabled) {
                        Text("Lock built-in microphone")
                        Text("Switch back to the MacBook microphone whenever macOS picks a headset mic.")
                    }
                    Toggle(isOn: $model.fullVolume) {
                        Text("Keep input volume at 100 %")
                        Text("Undo apps that lower the microphone level on their own.")
                    }
                }
                Section {
                    Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                    Toggle("Open at login", isOn: $model.openAtLogin)
                } footer: {
                    Text("With the menu bar icon hidden, open MicLock again from Finder or Spotlight to get back here.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section {
                    Text("Shortcuts can open miclock://toggle, miclock://on or miclock://off. Add such a shortcut to Control Center for a one-tap switch.")
                        .font(.callout).foregroundColor(.secondary)
                } header: {
                    Text("Control Center")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Quit MicLock") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 460)
        .fixedSize()
    }

    var statusLine: String {
        guard model.lockEnabled else { return "Off · input: \(model.currentInput)" }
        let volume = model.currentVolume.map { " · \($0) %" } ?? ""
        return "Locked to \(model.currentInput)\(volume)"
    }
}

// MARK: - Main

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
