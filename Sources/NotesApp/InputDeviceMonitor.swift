import SwiftUI
#if os(macOS)
import AppKit
import IOKit.hid
#endif

/// Presence comes from read-only HID metadata; activity comes from app-local
/// tablet/touch events. This never captures global input or opens HID devices.
@MainActor
final class InputDeviceMonitor: ObservableObject {
    @Published private(set) var tabletNames: [String] = []
    @Published private(set) var activity: String?
    @Published private(set) var penInRange = false
    #if os(macOS)
    private var manager: IOHIDManager?
    private var eventMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    #endif

    var status: String {
        if let activity { return activity }
        if let tablet = tabletNames.first { return "\(tablet) connected" }
        #if os(macOS)
        return "Ready for pen tablet"
        #else
        return "Ready for Apple Pencil"
        #endif
    }

    var detected: Bool { activity != nil || !tabletNames.isEmpty }

    init() {
        #if os(macOS)
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid
        IOHIDManagerSetDeviceMatching(hid, [kIOHIDDeviceUsagePageKey: 0x0D] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let devicesChanged: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak monitor] in monitor?.refresh() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(hid, devicesChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, devicesChanged, context)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        refresh()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletPoint, .tabletProximity, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
            self?.observe(event)
            return event
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        #endif
    }

    func report(_ source: String) {
        guard !source.isEmpty else { return }
        // A mouse gesture must not be presented as positive stylus detection.
        if source.localizedCaseInsensitiveContains("pencil") || source.localizedCaseInsensitiveContains("tablet") || source.localizedCaseInsensitiveContains("stylus") {
            if activity != source { activity = source }
        }
    }

    func refresh() {
        #if os(macOS)
        let previouslyConnected = !tabletNames.isEmpty
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            tabletNames = []
            if previouslyConnected { activity = nil; penInRange = false }
            return
        }
        tabletNames = Array(Set(devices.compactMap { device -> String? in
            let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
            let penCapable = pairs.contains { pair in
                let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue
                let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
                return page == 0x0D && [1, 2, 3, 6].contains(usage ?? -1)
            }
            guard penCapable else { return nil }
            return IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Pen tablet"
        })).sorted()
        if previouslyConnected && tabletNames.isEmpty { activity = nil; penInRange = false }
        #endif
    }

    #if os(macOS)
    private func observe(_ event: NSEvent) {
        if event.type == .tabletProximity || event.subtype == .tabletProximity {
            if penInRange != event.isEnteringProximity { penInRange = event.isEnteringProximity }
            if event.isEnteringProximity {
                let label = event.pointingDeviceType == .eraser ? "Tablet eraser detected" : "Pen tablet detected"
                if activity != label { activity = label }
            } else if activity != nil { activity = "Pen tablet ready" }
        } else if event.type == .tabletPoint || event.subtype == .tabletPoint {
            // Tablet points can arrive hundreds of times per second. Publish a
            // state transition once, so tracking a pen does not rebuild the UI.
            if !penInRange { penInRange = true }
            if activity != "Pen tablet active" { activity = "Pen tablet active" }
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }
    #endif
}
