private final class DelayedDrawableLayer: CAMetalLayer {
    let acquisitionGate = DispatchSemaphore(value: 0)
    private var firstRequest = true

    override func nextDrawable() -> CAMetalDrawable? {
        if firstRequest {
            firstRequest = false
            acquisitionGate.wait()
        }
        return super.nextDrawable()
    }
}

final class BackdropGenerationFixture: @unchecked Sendable {
    static let shared = BackdropGenerationFixture()
    private let lock = NSLock()
    private var gates: [UInt64: MTLSharedEvent] = [:]
    private var submissions: [UInt64] = []
    private var completions: [UInt64] = []

    func configure(_ generation: UInt64, event: MTLSharedEvent) {
        lock.lock()
        gates[generation] = event
        lock.unlock()
    }

    func gate(_ command: MTLCommandBuffer, generation: UInt64) {
        lock.lock()
        let event = gates[generation]
        submissions.append(generation)
        lock.unlock()
        if let event { command.encodeWaitForEvent(event, value: 1) }
    }

    func completed(_ generation: UInt64) {
        lock.lock()
        completions.append(generation)
        lock.unlock()
    }

    func completionCount(_ generation: UInt64? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation.map { value in completions.filter { $0 == value }.count } ?? completions.count
    }

    func submittedGenerations() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return submissions
    }
}

extension BackdropBlurWorker {
    func fixtureIsInFlight() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.isBlurInFlight) }
        }
    }
}

@main
struct FolderSchedulingRegression {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    @MainActor
    static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            await pause(0.005)
        }
        return false
    }

    @MainActor
    static func makeSurface(device: MTLDevice, layer: CAMetalLayer = CAMetalLayer()) -> (NSPanel, CAMetalLayer) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.wantsLayer = true
        let surface = layer
        surface.device = device
        surface.pixelFormat = .bgra8Unorm
        surface.framebufferOnly = false
        surface.frame = view.bounds
        surface.drawableSize = view.bounds.size
        view.layer?.addSublayer(surface)
        let window = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 128, height: 128),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        CATransaction.flush()
        return (window, surface)
    }

    @MainActor
    static func testBackdrop(device: MTLDevice, queue: MTLCommandQueue) async -> [String: Any] {
        guard let first = device.makeSharedEvent(), let second = device.makeSharedEvent() else {
            return ["pass": false, "error": "Metal shared events unavailable"]
        }
        let (window, surface) = makeSurface(device: device)
        defer { window.orderOut(nil); window.close() }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return ["pass": false, "error": "Texture unavailable"]
        }
        var pixels = [UInt8](repeating: 128, count: 128 * 128 * 4)
        pixels.withUnsafeMutableBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 128 * 4
            )
        }
        let worker = BackdropBlurWorker()
        let fixture = BackdropGenerationFixture.shared
        fixture.configure(1, event: first)
        fixture.configure(2, event: second)
        worker.reset(generation: 1)
        worker.schedule(
            progress: 0, generation: 1, scale: 1, rawTex: texture,
            metalLayer: surface, device: device, commandQueue: queue
        )
        let firstSubmitted = await waitFor { fixture.submittedGenerations().count >= 1 }
        worker.reset(generation: 2)
        worker.schedule(
            progress: 0.5, generation: 2, scale: 1, rawTex: texture,
            metalLayer: surface, device: device, commandQueue: queue
        )
        let secondSubmitted = await waitFor { fixture.submittedGenerations().count >= 2 }
        first.signaledValue = 1
        let oldCompleted = await waitFor { fixture.completionCount(1) == 1 }
        let busyAfterOldCompletion = await worker.fixtureIsInFlight()
        worker.schedule(
            progress: 0.75, generation: 2, scale: 1, rawTex: texture,
            metalLayer: surface, device: device, commandQueue: queue
        )
        await pause(0.05)
        let beforeRelease = fixture.submittedGenerations()
        second.signaledValue = 1
        let drained = await waitFor { fixture.completionCount() >= 3 }
        return [
            "pass": firstSubmitted && secondSubmitted && oldCompleted && drained && busyAfterOldCompletion && beforeRelease == [1, 2],
            "newGenerationStillBusy": busyAfterOldCompletion,
            "submissionsBeforeNewGenerationReleased": beforeRelease,
            "allSubmissions": fixture.submittedGenerations()
        ]
    }

    @MainActor
    static func testDrawables(device: MTLDevice) async -> [String: Any] {
        let delayedLayer = DelayedDrawableLayer()
        let (window, surface) = makeSurface(device: device, layer: delayedLayer)
        defer {
            delayedLayer.acquisitionGate.signal()
            window.orderOut(nil)
            window.close()
        }
        let provider = FolderDrawableProvider()
        var callbacks = 0
        let started = CACurrentMediaTime()
        let immediate = provider.takeOrRequest(from: surface) { callbacks += 1 }
        let returnedMs = (CACurrentMediaTime() - started) * 1000
        await pause(0.05)
        let mainActorRanWhileBlocked = immediate == nil && callbacks == 0
        provider.invalidate()
        delayedLayer.acquisitionGate.signal()
        let oldFinished = await waitFor { callbacks >= 1 }
        let stale = provider.takeOrRequest(from: surface) { callbacks += 1 }
        let resumed = await waitFor { callbacks >= 2 }
        let current = provider.takeOrRequest(from: surface) { callbacks += 1 }
        surface.drawableSize = CGSize(width: 64, height: 64)
        let afterResize = provider.takeOrRequest(from: surface) { callbacks += 1 }
        let resizeFinished = await waitFor { callbacks >= 3 }
        let resized = provider.takeOrRequest(from: surface) { callbacks += 1 }
        let correctSize = resized?.texture.width == 64 && resized?.texture.height == 64
        _ = provider.takeOrRequest(from: surface) { callbacks += 1 }
        let oldLayerReady = await waitFor { callbacks >= 4 }
        let (otherWindow, otherSurface) = makeSurface(device: device)
        defer { otherWindow.orderOut(nil); otherWindow.close() }
        otherSurface.drawableSize = CGSize(width: 64, height: 64)
        let switched = provider.takeOrRequest(from: otherSurface) { callbacks += 1 }
        let switchedReady = await waitFor { callbacks >= 5 }
        let fromNewLayer = provider.takeOrRequest(from: otherSurface) { callbacks += 1 }
        let correctLayer = fromNewLayer?.layer === otherSurface
        provider.invalidate()
        return [
            "pass": returnedMs < 200 && mainActorRanWhileBlocked && oldFinished && stale == nil
                && resumed && current != nil && afterResize == nil && resizeFinished && correctSize
                && oldLayerReady && switched == nil && switchedReady && correctLayer,
            "takeReturnedMs": returnedMs,
            "mainActorRanWhileAcquisitionDelayed": mainActorRanWhileBlocked,
            "staleResultDiscarded": stale == nil,
            "reacquired": current != nil,
            "resizedResultMatches": correctSize,
            "replacedLayerMatches": correctLayer
        ]
    }

    @MainActor
    static func run() async {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("FAIL: Metal device unavailable")
            return
        }
        let backdrop = await testBackdrop(device: device, queue: queue)
        let drawables = await testDrawables(device: device)
        let passed = backdrop["pass"] as? Bool == true && drawables["pass"] as? Bool == true
        let result: [String: Any] = ["pass": passed, "backdrop": backdrop, "drawables": drawables]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(passed ? "PASS" : "FAIL", result)
    }
}
