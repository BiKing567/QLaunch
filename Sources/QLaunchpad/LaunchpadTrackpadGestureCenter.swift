import AppKit
import Foundation
import QLaunchpadCore

@_silgen_name("notify_post")
private func bsd_notify_post(_ name: UnsafePointer<CChar>) -> UInt32

public enum TrackpadGesturePreferences {
    public static let enabledKey = "launchpadTrackpadPinchEnabled"
    public static let defaultEnabled: Bool = true

    public static let takeOverSystemGestureKey = "launchpadTakeOverSystemTrackpadGesture"
    public static let defaultTakeOverSystemGesture: Bool = true

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static var isTakeOverEnabled: Bool {
        UserDefaults.standard.object(forKey: takeOverSystemGestureKey) as? Bool ?? defaultTakeOverSystemGesture
    }

    private static let trackpadDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    private static let gestureKeys = [
        "TrackpadFourFingerPinchGesture",
        "TrackpadFiveFingerPinchGesture"
    ]
    private static let backupKey = "launchpadOriginalSystemGestureBackup"

    /// Check whether macOS system Launchpad gesture is active in System Settings.
    public static var isSystemLaunchpadGestureEnabled: Bool {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        let key = "TrackpadFourFingerPinchGesture" as CFString
        if let val = CFPreferencesCopyAppValue(key, domain) {
            if let num = val as? NSNumber {
                return num.intValue != 0
            }
        }
        return false
    }

    /// Programmatically take over macOS system pinch gesture.
    /// Saves current values before setting TrackpadFourFingerPinchGesture and TrackpadFiveFingerPinchGesture to 0.
    @discardableResult
    public static func takeOverSystemPinchGesture() -> Bool {
        if UserDefaults.standard.dictionary(forKey: backupKey) == nil {
            var backup: [String: [String: Int]] = [:]
            for domain in trackpadDomains {
                var domainBackup: [String: Int] = [:]
                for key in gestureKeys {
                    if let val = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber, val.intValue > 0 {
                        domainBackup[key] = val.intValue
                    } else {
                        domainBackup[key] = 2 // standard macOS gesture value
                    }
                }
                backup[domain] = domainBackup
            }
            UserDefaults.standard.set(backup, forKey: backupKey)
        }

        for domain in trackpadDomains {
            CFPreferencesSetAppValue("TrackpadFourFingerPinchGesture" as CFString, 0 as CFNumber, domain as CFString)
            CFPreferencesSetAppValue("TrackpadFiveFingerPinchGesture" as CFString, 0 as CFNumber, domain as CFString)
            _ = CFPreferencesAppSynchronize(domain as CFString)
        }
        postTrackpadSettingsChangeNotifications()
        return true
    }

    /// Restore macOS system pinch gesture back to saved original values (or 2 if no backup).
    public static func restoreSystemPinchGesture() {
        let backup = UserDefaults.standard.dictionary(forKey: backupKey) as? [String: [String: Int]]
        for domain in trackpadDomains {
            let domainBackup = backup?[domain]
            for key in gestureKeys {
                if let originalValue = domainBackup?[key], originalValue > 0 {
                    CFPreferencesSetAppValue(key as CFString, originalValue as CFNumber, domain as CFString)
                } else {
                    CFPreferencesSetAppValue(key as CFString, 2 as CFNumber, domain as CFString)
                }
            }
            _ = CFPreferencesAppSynchronize(domain as CFString)
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        postTrackpadSettingsChangeNotifications()
    }

    public static func postTrackpadSettingsChangeNotifications() {
        let dnc = DistributedNotificationCenter.default()
        let notifNames = [
            "com.apple.AppleMultitouchTrackpadDomainDidChangeNotification",
            "com.apple.AppleMenuGesturesDidChangeNotification",
            "com.apple.preference.trackpad"
        ]
        for name in notifNames {
            dnc.postNotificationName(NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
        }
        _ = bsd_notify_post("com.apple.AppleMultitouchTrackpadDomainDidChangeNotification")
        _ = bsd_notify_post("com.apple.preference.trackpad")
    }

    /// Open macOS Trackpad Settings pane in System Settings.
    public static func openSystemTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Notification.Name {
    static let qlaunchpadTrackpadGestureChanged = Notification.Name("QLaunchpadTrackpadGestureChanged")
}

private final class UnfairLock: @unchecked Sendable {
    private var lock = os_unfair_lock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return try body()
    }
}

final class LaunchpadTrackpadGestureCenter: @unchecked Sendable {
    static let shared = LaunchpadTrackpadGestureCenter()

    public enum InteractivePinchEvent: Sendable {
        case began(isOpening: Bool)
        case changed(isOpening: Bool, progress: CGFloat)
        case ended(isOpening: Bool, completed: Bool)
        case cancelled(isOpening: Bool)
    }

    var onPinchIn: (@MainActor () -> Void)?
    var onPinchOut: (@MainActor () -> Void)?

    private var _onInteractiveEvent: (@MainActor (InteractivePinchEvent) -> Void)?
    var onInteractiveEvent: (@MainActor (InteractivePinchEvent) -> Void)? {
        get { lock.withLock { _onInteractiveEvent } }
        set { lock.withLock { _onInteractiveEvent = newValue } }
    }

    private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private struct Functions {
        let createList: CreateListFn
        let register: RegisterFn
        let unregister: RegisterFn
        let start: StartFn
        let stop: StopFn
    }

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            return nil
        }
        guard let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else {
            return nil
        }
        return Functions(
            createList: unsafeBitCast(createList, to: CreateListFn.self),
            register: unsafeBitCast(register, to: RegisterFn.self),
            unregister: unsafeBitCast(unregister, to: RegisterFn.self),
            start: unsafeBitCast(start, to: StartFn.self),
            stop: unsafeBitCast(stop, to: StopFn.self)
        )
    }()

    private struct Devices {
        var list: CFMutableArray?
        var refs: [UnsafeMutableRawPointer] = []
    }

    private struct Tracking {
        var active = false
        var fingers = 0
        var baseline: Double = 0
        var originX: Double = 0
        var originY: Double = 0
        var intent = TrackpadPinchIntent()
        var lastTime: Double = 0
        var triggeredInSession = false
        var interactiveStarted = false
        var interactiveIsOpening = false
        var currentProgress: CGFloat = 0
    }

    private let lock = UnfairLock()
    private var devices = Devices()
    private var tracking = Tracking()
    private var lastActionTime: Double = 0
    private var isListening = false
    private var sessionGeneration: UInt = 0

    var isAvailable: Bool { Self.functions != nil }

    private static let touchStride = 96
    private static let aspect = 1.6
    private static let sessionGap = 0.35

    private init() {}

    func install() {
        reloadPreference()
    }

    func uninstall() {
        stop()
        if TrackpadGesturePreferences.isTakeOverEnabled {
            TrackpadGesturePreferences.restoreSystemPinchGesture()
        }
    }

    func reloadPreference() {
        stop()
        if TrackpadGesturePreferences.isEnabled {
            let started = start()
            if started && TrackpadGesturePreferences.isTakeOverEnabled {
                _ = TrackpadGesturePreferences.takeOverSystemPinchGesture()
            }
        } else {
            if TrackpadGesturePreferences.isTakeOverEnabled {
                TrackpadGesturePreferences.restoreSystemPinchGesture()
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        lock.withLock {
            guard !isListening else { return true }
            guard let fn = Self.functions, let list = fn.createList()?.takeRetainedValue() else { return false }
            var refs: [UnsafeMutableRawPointer] = []
            let count = CFArrayGetCount(list)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let device = UnsafeMutableRawPointer(mutating: raw)
                fn.register(device, Self.callback)
                _ = fn.start(device, 0)
                refs.append(device)
            }
            guard !refs.isEmpty else {
                devices = Devices()
                isListening = false
                return false
            }
            devices = Devices(list: list, refs: refs)
            isListening = true
            sessionGeneration &+= 1
            return true
        }
    }

    func stop() {
        var eventToDeliver: InteractivePinchEvent?
        var gen: UInt = 0
        lock.withLock {
            guard isListening else { return }
            sessionGeneration &+= 1
            gen = sessionGeneration
            if tracking.interactiveStarted {
                let isOpening = tracking.interactiveIsOpening
                eventToDeliver = .cancelled(isOpening: isOpening)
            }
            if let fn = Self.functions {
                for device in devices.refs {
                    fn.unregister(device, Self.callback)
                    _ = fn.stop(device)
                }
            }
            devices = Devices()
            tracking = Tracking()
            isListening = false
        }
        if let eventToDeliver {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let shouldDeliver = self.lock.withLock {
                    self.sessionGeneration == gen
                }
                guard shouldDeliver else { return }
                self.onInteractiveEvent?(eventToDeliver)
            }
        }
    }

    private static let callback: ContactCallback = { _, touches, count, timestamp, _ in
        LaunchpadTrackpadGestureCenter.shared.process(touches: touches, count: Int(count), timestamp: timestamp)
        return 0
    }

    private func process(touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        // Three or more fingers required (supports 3-finger pinch and classic 4-finger pinch)
        guard count >= 3, let touches else {
            var eventsToDeliver: [InteractivePinchEvent] = []
            let gen: UInt = lock.withLock {
                if tracking.interactiveStarted {
                    let isOpening = tracking.interactiveIsOpening
                    let completed = tracking.currentProgress >= 0.35
                    eventsToDeliver = [.ended(isOpening: isOpening, completed: completed)]
                    tracking.interactiveStarted = false
                }
                if count == 0 {
                    tracking = Tracking()
                } else if timestamp - tracking.lastTime > Self.sessionGap {
                    tracking = Tracking()
                }
                tracking.lastTime = timestamp
                return sessionGeneration
            }
            if !eventsToDeliver.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let shouldDeliver = self.lock.withLock {
                        self.isListening && self.sessionGeneration == gen
                    }
                    guard shouldDeliver else { return }
                    for event in eventsToDeliver {
                        self.onInteractiveEvent?(event)
                    }
                }
            }
            return
        }

        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(count)
        ys.reserveCapacity(count)

        for index in 0..<count {
            let base = touches + index * Self.touchStride
            let state = base.load(fromByteOffset: 20, as: Int32.self)
            // 3 = contact began, 4 = contact moving
            guard state == 3 || state == 4 else { continue }
            xs.append(Double(base.load(fromByteOffset: 32, as: Float.self)) * Self.aspect)
            ys.append(Double(base.load(fromByteOffset: 36, as: Float.self)))
        }

        let fingers = xs.count
        guard fingers >= 3 else {
            var eventsToDeliver: [InteractivePinchEvent] = []
            let gen: UInt = lock.withLock {
                if tracking.interactiveStarted {
                    let isOpening = tracking.interactiveIsOpening
                    let completed = tracking.currentProgress >= 0.35
                    eventsToDeliver = [.ended(isOpening: isOpening, completed: completed)]
                    tracking.interactiveStarted = false
                }
                if timestamp - tracking.lastTime > Self.sessionGap {
                    tracking = Tracking()
                }
                tracking.lastTime = timestamp
                return sessionGeneration
            }
            if !eventsToDeliver.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let shouldDeliver = self.lock.withLock {
                        self.isListening && self.sessionGeneration == gen
                    }
                    guard shouldDeliver else { return }
                    for event in eventsToDeliver {
                        self.onInteractiveEvent?(event)
                    }
                }
            }
            return
        }

        let spread = Self.spread(xs: xs, ys: ys)
        let cx = xs.reduce(0, +) / Double(fingers)
        let cy = ys.reduce(0, +) / Double(fingers)

        enum TriggerAction {
            case pinchIn
            case pinchOut
        }
        var actionToTrigger: TriggerAction?
        var eventsToDeliver: [InteractivePinchEvent] = []

        let gen: UInt = lock.withLock {
            if timestamp - tracking.lastTime > Self.sessionGap {
                if tracking.interactiveStarted {
                    let isOpening = tracking.interactiveIsOpening
                    let completed = tracking.currentProgress >= 0.35
                    eventsToDeliver.append(.ended(isOpening: isOpening, completed: completed))
                    tracking.interactiveStarted = false
                }
                tracking = Tracking()
            }
            tracking.lastTime = timestamp

            if !tracking.active || fingers != tracking.fingers {
                if tracking.interactiveStarted {
                    let isOpening = tracking.interactiveIsOpening
                    let completed = tracking.currentProgress >= 0.35
                    eventsToDeliver.append(.ended(isOpening: isOpening, completed: completed))
                    tracking.interactiveStarted = false
                }
                tracking.active = true
                tracking.fingers = fingers
                tracking.baseline = spread
                tracking.originX = cx
                tracking.originY = cy
                tracking.intent = TrackpadPinchIntent()
                return sessionGeneration
            }

            guard tracking.baseline > 0.01 else { return sessionGeneration }
            let ratio = spread / tracking.baseline
            let dx = cx - tracking.originX
            let dy = cy - tracking.originY
            let travel = (dx * dx + dy * dy).squareRoot() / tracking.baseline

            let isPinch = tracking.intent.update(ratio: ratio, travel: travel)
            guard isPinch else { return sessionGeneration }

            if _onInteractiveEvent != nil {
                if !tracking.interactiveStarted {
                    if ratio <= 0.96 {
                        tracking.interactiveStarted = true
                        tracking.interactiveIsOpening = true
                        let p = (0.96 - ratio) / 0.18
                        let progress = min(1.0, max(0.0, CGFloat(p)))
                        tracking.currentProgress = progress
                        eventsToDeliver.append(.began(isOpening: true))
                        eventsToDeliver.append(.changed(isOpening: true, progress: progress))
                    } else if ratio >= 1.05 {
                        tracking.interactiveStarted = true
                        tracking.interactiveIsOpening = false
                        let p = (ratio - 1.05) / 0.18
                        let progress = min(1.0, max(0.0, CGFloat(p)))
                        tracking.currentProgress = progress
                        eventsToDeliver.append(.began(isOpening: false))
                        eventsToDeliver.append(.changed(isOpening: false, progress: progress))
                    }
                } else {
                    if tracking.interactiveIsOpening {
                        let p = (0.96 - ratio) / 0.18
                        let progress = min(1.0, max(0.0, CGFloat(p)))
                        tracking.currentProgress = progress
                        eventsToDeliver.append(.changed(isOpening: true, progress: progress))
                    } else {
                        let p = (ratio - 1.05) / 0.18
                        let progress = min(1.0, max(0.0, CGFloat(p)))
                        tracking.currentProgress = progress
                        eventsToDeliver.append(.changed(isOpening: false, progress: progress))
                    }
                }
            } else {
                guard !tracking.triggeredInSession else { return sessionGeneration }
                let now = CACurrentMediaTime()
                guard now - lastActionTime > 0.35 else { return sessionGeneration }

                // Pinch in threshold: natural contraction (ratio <= 0.82)
                if ratio <= 0.82 {
                    tracking.triggeredInSession = true
                    lastActionTime = now
                    actionToTrigger = .pinchIn
                } else if ratio >= 1.20 {
                    // Pinch out threshold: natural expansion (ratio >= 1.20)
                    tracking.triggeredInSession = true
                    lastActionTime = now
                    actionToTrigger = .pinchOut
                }
            }
            return sessionGeneration
        }

        if !eventsToDeliver.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let shouldDeliver = self.lock.withLock {
                    self.isListening && self.sessionGeneration == gen
                }
                guard shouldDeliver else { return }
                for event in eventsToDeliver {
                    self.onInteractiveEvent?(event)
                }
            }
        }

        if let actionToTrigger {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let shouldDeliver = self.lock.withLock {
                    self.isListening && self.sessionGeneration == gen
                }
                guard shouldDeliver else { return }
                switch actionToTrigger {
                case .pinchIn:
                    self.onPinchIn?()
                case .pinchOut:
                    self.onPinchOut?()
                }
            }
        }
    }

    private static func spread(xs: [Double], ys: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let cx = xs.reduce(0, +) / Double(xs.count)
        let cy = ys.reduce(0, +) / Double(ys.count)
        var total = 0.0
        for (x, y) in zip(xs, ys) {
            let dx = x - cx
            let dy = y - cy
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total / Double(xs.count)
    }
}
