import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore

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

    private(set) var isBaking = false
    private(set) var isReady = false
    private(set) var currentProgress: CGFloat = 0

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

    /// Bakes the sharp root grid once into the offscreen texture.
    func bake(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        boundsSize: CGSize,
        scale: CGFloat,
        renderPass: (MTLCommandBuffer, MTLTexture) -> Void
    ) {
        isBaking = true
        defer { isBaking = false }

        self.device = device
        self.commandQueue = commandQueue
        self.currentScale = scale

        let pixelWidth = max(1, Int((boundsSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((boundsSize.height * scale).rounded()))

        guard let rawTex = ensureTexture(
            device: device,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Render the root grid (excluding the opening folder) into rawTex
        renderPass(commandBuffer, rawTex)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

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

        if renderBlur(progress: 0.0) {
            isReady = true
            isHidden = false
        } else {
            isReady = false
            isHidden = true
        }
    }

    @discardableResult
    private func renderBlur(progress: Float) -> Bool {
        guard let device,
              let commandQueue,
              let rawTex = rawTexture else {
            isReady = false
            return false
        }

        guard let drawable = metalLayer.nextDrawable() else {
            isReady = false
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            isReady = false
            return false
        }

        let blurRadiusPoints: Float = 16.0
        let sigma = blurRadiusPoints * Float(currentScale) * progress

        if sigma < 0.2 {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                return false
            }
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
        } else {
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.encode(commandBuffer: commandBuffer, sourceTexture: rawTex, destinationTexture: drawable.texture)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
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

    var currentSinkTransform: CATransform3D {
        containerLayer.transform
    }

    /// Updates the depth backdrop animation progress (0 = fully closed/resting root, 1 = fully open folder).
    func updateProgress(_ progress: CGFloat) {
        currentProgress = progress
        guard !isHidden else { return }

        let local = min(max(progress, 0), 1)

        // Progressive Gaussian blur matching the folder baseplates
        renderBlur(progress: Float(local))

        let sink = Self.sinkTransform(progress: progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.transform = sink.transform
        // Icons remain 100% solid, full-screen dim overlay handles background darkening uniformly.
        containerLayer.opacity = 1.0
        CATransaction.commit()
    }

    /// Dismisses the backdrop when the folder is fully closed.
    func dismiss() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        isReady = false
        currentProgress = 0
        containerLayer.transform = CATransform3DIdentity
        containerLayer.opacity = 1.0
        CATransaction.commit()
    }

    /// Releases cached textures on memory pressure or when quality changes.
    func purgeTextures() {
        cachedPixelSize = .zero
        rawTexture = nil
        isReady = false
    }
}
