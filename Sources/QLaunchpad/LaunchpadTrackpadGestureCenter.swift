import AppKit
import Foundation
import QLaunchpadCore

public enum TrackpadGesturePreferences {
    public static let enabledKey = "launchpadTrackpadPinchEnabled"
    public static let defaultEnabled: Bool = true

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

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

    var onPinchIn: (@MainActor () -> Void)?
    var onPinchOut: (@MainActor () -> Void)?

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
    }

    private let lock = UnfairLock()
    private var devices = Devices()
    private var tracking = Tracking()
    private var lastActionTime: Double = 0
    private var isListening = false

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
    }

    func reloadPreference() {
        if TrackpadGesturePreferences.isEnabled {
            start()
        } else {
            stop()
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
            devices = Devices(list: list, refs: refs)
            isListening = true
            return !refs.isEmpty
        }
    }

    func stop() {
        lock.withLock {
            guard isListening, let fn = Self.functions else { return }
            for device in devices.refs {
                fn.unregister(device, Self.callback)
                _ = fn.stop(device)
            }
            devices = Devices()
            tracking = Tracking()
            isListening = false
        }
    }

    private static let callback: ContactCallback = { _, touches, count, timestamp, _ in
        LaunchpadTrackpadGestureCenter.shared.process(touches: touches, count: Int(count), timestamp: timestamp)
        return 0
    }

    private func process(touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        // Three or more fingers required (supports 3-finger pinch and classic 4-finger pinch)
        guard count >= 3, let touches else {
            lock.withLock {
                if count == 0 {
                    tracking = Tracking()
                } else if timestamp - tracking.lastTime > Self.sessionGap {
                    tracking.intent = TrackpadPinchIntent()
                    tracking.triggeredInSession = false
                }
                tracking.lastTime = timestamp
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
            lock.withLock {
                if timestamp - tracking.lastTime > Self.sessionGap {
                    tracking.intent = TrackpadPinchIntent()
                    tracking.triggeredInSession = false
                }
                tracking.lastTime = timestamp
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

        lock.withLock {
            if timestamp - tracking.lastTime > Self.sessionGap {
                tracking.intent = TrackpadPinchIntent()
                tracking.triggeredInSession = false
            }
            tracking.lastTime = timestamp

            if !tracking.active {
                tracking.active = true
                tracking.fingers = fingers
                tracking.baseline = spread
                tracking.originX = cx
                tracking.originY = cy
                return
            } else {
                // If fingers are spreading or additional fingers joined before contracting,
                // adapt baseline to the maximum spread so contraction is calculated from peak
                if spread > tracking.baseline {
                    tracking.baseline = spread
                    tracking.originX = cx
                    tracking.originY = cy
                }
            }

            guard tracking.baseline > 0.01 else { return }
            let ratio = spread / tracking.baseline
            let dx = cx - tracking.originX
            let dy = cy - tracking.originY
            let travel = (dx * dx + dy * dy).squareRoot() / tracking.baseline

            let isPinch = tracking.intent.update(ratio: ratio, travel: travel)
            guard isPinch else { return }

            guard !tracking.triggeredInSession else { return }

            let now = CACurrentMediaTime()
            guard now - lastActionTime > 0.35 else { return }

            // Pinch in threshold: natural contraction (ratio <= 0.82)
            if ratio <= 0.82 {
                tracking.triggeredInSession = true
                lastActionTime = now
                actionToTrigger = .pinchIn
            } else if ratio >= 1.22 {
                // Pinch out threshold: natural expansion (ratio >= 1.22)
                tracking.triggeredInSession = true
                lastActionTime = now
                actionToTrigger = .pinchOut
            }
        }

        if let actionToTrigger {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
