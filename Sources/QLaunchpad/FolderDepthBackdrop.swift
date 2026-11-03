import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Dedicated worker that executes Gaussian blur and CAMetalLayer presentation
/// on a private serial queue so drawable waits never block the main thread.
private final class BackdropBlurWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.qzrzz.qlaunchpad.backdrop-blur", qos: .userInteractive)
    private var isBlurInFlight = false
    private var pendingProgress: Float?
    private var blurKernels: [Int: MPSImageGaussianBlur] = [:]
    private var activeGeneration: UInt64 = 0

    func reset(generation: UInt64) {
        queue.async {
            self.activeGeneration = generation
            self.pendingProgress = nil
            self.isBlurInFlight = false
        }
    }

    func purgeKernels() {
        queue.async {
            self.blurKernels.removeAll(keepingCapacity: true)
        }
    }

    func prewarmKernels(device: MTLDevice, commandQueue: MTLCommandQueue? = nil, scale: CGFloat) {
        queue.async {
            let blurRadius: Float = 16.0
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 16,
                height: 16,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            let dummySrc = device.makeTexture(descriptor: desc)
            let dummyDst = device.makeTexture(descriptor: desc)
            let cb = commandQueue?.makeCommandBuffer()

            for step in 1...10 {
                let p = Float(step) / 10.0
                let sigma = blurRadius * Float(scale) * p
                let key = Int((sigma * 10).rounded())
                let blur: MPSImageGaussianBlur
                if let cached = self.blurKernels[key] {
                    blur = cached
                } else {
                    blur = MPSImageGaussianBlur(device: device, sigma: sigma)
                    self.blurKernels[key] = blur
                }
                if let dummySrc, let dummyDst, let cb {
                    blur.encode(commandBuffer: cb, sourceTexture: dummySrc, destinationTexture: dummyDst)
                }
            }
            cb?.commit()
        }
    }

    func schedule(
        progress: Float,
        generation: UInt64,
        scale: CGFloat,
        rawTex: MTLTexture,
        metalLayer: CAMetalLayer,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        onSubmission: (@Sendable (UInt64, Bool) -> Void)? = nil
    ) {
        queue.async {
            guard generation == self.activeGeneration else {
                onSubmission?(generation, false)
                return
            }
            if self.isBlurInFlight {
                self.pendingProgress = progress
                onSubmission?(generation, false)
                return
            }
            self.isBlurInFlight = true
            self.executeBlur(
                progress: progress,
                generation: generation,
                scale: scale,
                rawTex: rawTex,
                metalLayer: metalLayer,
                device: device,
                commandQueue: commandQueue,
                onSubmission: onSubmission
            )
        }
    }

    private func executeBlur(
        progress: Float,
        generation: UInt64,
        scale: CGFloat,
        rawTex: MTLTexture,
        metalLayer: CAMetalLayer,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        onSubmission: (@Sendable (UInt64, Bool) -> Void)? = nil
    ) {
        guard generation == self.activeGeneration else {
            onSubmission?(generation, false)
            return
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            isBlurInFlight = false
            pendingProgress = nil
            onSubmission?(generation, false)
            return
        }

        let blurRadiusPoints: Float = 16.0
        let sigma = blurRadiusPoints * Float(scale) * progress

        if sigma < 0.2 {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: rawTex,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: rawTex.width, height: rawTex.height, depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
        } else {
            let key = Int((sigma * 10).rounded())
            let blur: MPSImageGaussianBlur
            if let cached = blurKernels[key] {
                blur = cached
            } else {
                blur = MPSImageGaussianBlur(device: device, sigma: sigma)
                blurKernels[key] = blur
            }
            blur.encode(commandBuffer: commandBuffer, sourceTexture: rawTex, destinationTexture: drawable.texture)
        }

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            onSubmission?(generation, true)
            guard let self else { return }
            self.queue.async {
                guard generation == self.activeGeneration else { return }
                self.isBlurInFlight = false
                if let next = self.pendingProgress {
                    self.pendingProgress = nil
                    self.isBlurInFlight = true
                    self.executeBlur(
                        progress: next,
                        generation: generation,
                        scale: scale,
                        rawTex: rawTex,
                        metalLayer: metalLayer,
                        device: device,
                        commandQueue: commandQueue
                    )
                }
            }
        }
        commandBuffer.commit()
    }
}

/// Dedicated backdrop view that manages the receding and blurred root icons during folder expansion.
///
/// Hierarchy (bottom to top):
/// 1. DesktopBackgroundView (wallpaper - crisp, untouched)
/// 2. FolderDepthBackdropView (sinking, blurred root icons, folders and labels)
/// 3. FullScreenDimView (uniform dim wash across wallpaper and backdrop icons)
/// 4. FolderGlassHostView (foreground native Liquid Glass card)
/// 5. LaunchpadMetalView (folder internal icons & title in razor-sharp focus)
/// 6. Overlay chrome (search bar, page indicators)
@MainActor
final class FolderDepthBackdropView: NSView {
    private let containerLayer = CALayer()
    private let metalLayer = CAMetalLayer()

    private var rawTexture: MTLTexture?
    private weak var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var cachedPixelSize: CGSize = .zero
    private var currentScale: CGFloat = 2.0

    var onReadyChange: (@MainActor (Bool) -> Void)?
    private(set) var isReady = false
    private(set) var isBaking = false
    private(set) var bakeFailed = false

    private let worker = BackdropBlurWorker()
    private var generation: UInt64 = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        containerLayer.masksToBounds = false
        containerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = false
        metalLayer.masksToBounds = false

        containerLayer.addSublayer(metalLayer)
        layer?.addSublayer(containerLayer)

        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let savedTransform = containerLayer.transform
        containerLayer.transform = CATransform3DIdentity
        containerLayer.bounds = bounds
        containerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        metalLayer.bounds = containerLayer.bounds
        metalLayer.position = CGPoint(x: containerLayer.bounds.midX, y: containerLayer.bounds.midY)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        currentScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        containerLayer.transform = savedTransform
        CATransaction.commit()
    }

    /// Allocates or reuses the texture matching the exact Retina framebuffer dimensions.
    private func ensureTexture(
        device: MTLDevice,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> MTLTexture? {
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        if cachedPixelSize == size, let raw = rawTexture {
            return raw
        }

        cachedPixelSize = size
        rawTexture = nil

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private

        guard let tex = device.makeTexture(descriptor: desc) else {
            return nil
        }

        rawTexture = tex
        return tex
    }

    /// Pre-allocates textures and prewarms Gaussian blur shaders ahead of time.
    func prewarm(device: MTLDevice, commandQueue: MTLCommandQueue, boundsSize: CGSize, scale: CGFloat) {
        self.device = device
        self.commandQueue = commandQueue
        self.currentScale = scale
        let pixelWidth = max(1, Int((boundsSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((boundsSize.height * scale).rounded()))
        _ = ensureTexture(device: device, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        metalLayer.device = device
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
        worker.prewarmKernels(device: device, commandQueue: commandQueue, scale: scale)
    }

    /// Bakes the sharp root grid once into the offscreen texture.
    func bake(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        boundsSize: CGSize,
        scale: CGFloat,
        renderPass: (MTLCommandBuffer, MTLTexture) -> Void
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.currentScale = scale
        generation &+= 1
        let currentGen = generation
        worker.reset(generation: currentGen)

        let pixelWidth = max(1, Int((boundsSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((boundsSize.height * scale).rounded()))

        guard let rawTex = ensureTexture(
            device: device,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else {
            isReady = false
            isHidden = true
            isBaking = false
            bakeFailed = true
            onReadyChange?(false)
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            isReady = false
            isHidden = true
            isBaking = false
            bakeFailed = true
            onReadyChange?(false)
            return
        }

        // Render the root grid (excluding the opening folder) into rawTex
        renderPass(commandBuffer, rawTex)
        commandBuffer.commit()

        metalLayer.device = device
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)

        let targetBounds = CGRect(origin: .zero, size: boundsSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.transform = CATransform3DIdentity
        containerLayer.bounds = targetBounds
        containerLayer.position = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        metalLayer.bounds = targetBounds
        metalLayer.position = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        CATransaction.commit()

        isReady = false
        isHidden = true
        isBaking = true
        bakeFailed = false

        worker.schedule(
            progress: 0.0,
            generation: currentGen,
            scale: scale,
            rawTex: rawTex,
            metalLayer: metalLayer,
            device: device,
            commandQueue: commandQueue,
            onSubmission: { [weak self] gen, success in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard gen == self.generation else { return }
                    self.isBaking = false
                    if success {
                        self.isReady = true
                        self.isHidden = false
                        self.bakeFailed = false
                        self.onReadyChange?(true)
                    } else {
                        self.isReady = false
                        self.isHidden = true
                        self.bakeFailed = true
                        self.onReadyChange?(false)
                    }
                }
            }
        )
    }

    /// Canonical sink transform calculation shared across backdrop and background folder views.
    static func sinkTransform(progress: CGFloat) -> (scale: CGFloat, offsetY: CGFloat, transform: CATransform3D) {
        let local = min(max(progress, 0), 1)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = reduceMotion ? 1.0 : (1.0 - 0.15 * local)
        let offsetY = reduceMotion ? 0.0 : (22.0 * local)
        let transform = CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1.0),
            CATransform3DMakeTranslation(0, offsetY, 0)
        )
        return (scale, offsetY, transform)
    }

    /// Updates the depth backdrop animation progress (0 = fully closed/resting root, 1 = fully open folder).
    func updateProgress(_ progress: CGFloat) {
        guard isReady || isBaking else { return }

        let local = min(max(progress, 0), 1)

        if let rawTex = rawTexture, let device, let commandQueue {
            worker.schedule(
                progress: Float(local),
                generation: generation,
                scale: currentScale,
                rawTex: rawTex,
                metalLayer: metalLayer,
                device: device,
                commandQueue: commandQueue
            )
        }

        let sink = Self.sinkTransform(progress: progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.transform = sink.transform
        containerLayer.opacity = 1.0
        CATransaction.commit()
    }

    /// Synchronously hides the backdrop layers in the current transaction.
    func hideVisuals() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        containerLayer.transform = CATransform3DIdentity
        containerLayer.opacity = 1.0
        CATransaction.commit()
    }

    /// Dismisses the backdrop when the folder is fully closed.
    func dismiss() {
        generation &+= 1
        worker.reset(generation: generation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        isReady = false
        isBaking = false
        bakeFailed = false
        containerLayer.transform = CATransform3DIdentity
        containerLayer.opacity = 1.0
        CATransaction.commit()
        onReadyChange?(false)
    }

    /// Releases cached textures on memory pressure or when quality changes.
    func purgeTextures() {
        generation &+= 1
        worker.reset(generation: generation)
        worker.purgeKernels()
        cachedPixelSize = .zero
        rawTexture = nil
        isReady = false
        isBaking = false
        bakeFailed = false
        onReadyChange?(false)
    }
}
