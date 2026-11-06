import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Dedicated worker that executes Gaussian blur and CAMetalLayer presentation
/// on a private serial queue so drawable waits never block the main thread.
private final class BackdropBlurWorker: @unchecked Sendable {
    private struct PendingBlur {
        let progress: Float
        let materialProgress: Float
    }

    private struct MaskPipelineKey: Hashable {
        let deviceID: ObjectIdentifier
        let pixelFormat: MTLPixelFormat
    }

    private static let maskShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MaskVertexOut {
        float4 position [[position]];
        float2 localPosPt;
        float2 sizePt;
        float smoothT;
        float featherPt;
    };

    vertex MaskVertexOut ql_backdrop_mask_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        device const float4 *rects [[buffer(0)]],
        constant float4 &uniforms [[buffer(1)]])
    {
        const float2 corners[6] = {
            float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
            float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
        };
        float2 c = corners[vid];
        float4 r = rects[iid];
        float2 sizePt = max(r.zw - r.xy, float2(1.0));
        float2 posPt = r.xy + c * sizePt;
        float2 viewport = max(uniforms.xy, float2(1.0));
        float2 ndc = float2(
            posPt.x / viewport.x * 2.0 - 1.0,
            1.0 - posPt.y / viewport.y * 2.0
        );
        MaskVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.localPosPt = c * sizePt;
        out.sizePt = sizePt;
        out.smoothT = uniforms.z;
        out.featherPt = uniforms.w;
        return out;
    }

    fragment float4 ql_backdrop_mask_fragment(MaskVertexOut in [[stage_in]]) {
        float dist = min(
            min(in.localPosPt.x, in.sizePt.x - in.localPosPt.x),
            min(in.localPosPt.y, in.sizePt.y - in.localPosPt.y)
        );
        float w = smoothstep(0.0, max(in.featherPt, 0.5), dist);
        float factor = mix(1.0, in.smoothT, w);
        return float4(0.0, 0.0, 0.0, factor);
    }
    """

    private let queue = DispatchQueue(label: "com.qzrzz.qlaunchpad.backdrop-blur", qos: .userInteractive)
    private var isBlurInFlight = false
    private var pendingBlur: PendingBlur?
    private var blurKernels: [Int: MPSImageGaussianBlur] = [:]
    private var maskPipelines: [MaskPipelineKey: MTLRenderPipelineState] = [:]
    private var activeGeneration: UInt64 = 0

    private struct PrewarmKey: Equatable {
        let deviceID: ObjectIdentifier
        let scale: CGFloat
        let pixelFormat: MTLPixelFormat
    }
    private var lastPrewarmKey: PrewarmKey?

    func reset(generation: UInt64) {
        queue.async {
            self.activeGeneration = generation
            self.pendingBlur = nil
            self.isBlurInFlight = false
        }
    }

    func purgeKernels() {
        queue.async {
            self.blurKernels.removeAll(keepingCapacity: true)
            self.maskPipelines.removeAll(keepingCapacity: true)
            self.lastPrewarmKey = nil
        }
    }

    private func maskPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = MaskPipelineKey(deviceID: ObjectIdentifier(device), pixelFormat: pixelFormat)
        if let cached = maskPipelines[key] {
            return cached
        }
        guard let library = try? device.makeLibrary(source: Self.maskShaderSource, options: nil),
              let vertex = library.makeFunction(name: "ql_backdrop_mask_vertex"),
              let fragment = library.makeFunction(name: "ql_backdrop_mask_fragment") else {
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .zero
        desc.colorAttachments[0].destinationRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .zero
        desc.colorAttachments[0].destinationAlphaBlendFactor = .sourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        maskPipelines[key] = pipeline
        return pipeline
    }

    func prewarmKernels(
        device: MTLDevice,
        commandQueue: MTLCommandQueue? = nil,
        scale: CGFloat,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) {
        let key = PrewarmKey(
            deviceID: ObjectIdentifier(device),
            scale: scale,
            pixelFormat: pixelFormat
        )
        queue.async { [weak self] in
            guard let self else { return }
            if self.lastPrewarmKey == key && !self.blurKernels.isEmpty {
                return
            }
            self.lastPrewarmKey = key
            _ = self.maskPipeline(device: device, pixelFormat: pixelFormat)

            let blurRadius: Float = 16.0
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
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
        materialProgress: Float = 1.0,
        generation: UInt64,
        scale: CGFloat,
        boundsSize: CGSize = .zero,
        folderMaskQuads: [SIMD4<Float>] = [],
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
                self.pendingBlur = PendingBlur(progress: progress, materialProgress: materialProgress)
                onSubmission?(generation, false)
                return
            }
            self.isBlurInFlight = true
            self.executeBlur(
                progress: progress,
                materialProgress: materialProgress,
                generation: generation,
                scale: scale,
                boundsSize: boundsSize,
                folderMaskQuads: folderMaskQuads,
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
        materialProgress: Float,
        generation: UInt64,
        scale: CGFloat,
        boundsSize: CGSize,
        folderMaskQuads: [SIMD4<Float>],
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
            pendingBlur = nil
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

        let clampedMat = min(max(materialProgress, 0.0), 1.0)
        if clampedMat < 0.9999, !folderMaskQuads.isEmpty,
           let pipeline = maskPipeline(device: device, pixelFormat: drawable.texture.pixelFormat) {
            let smoothT = clampedMat * clampedMat * (3.0 - 2.0 * clampedMat)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                var uniforms = SIMD4<Float>(
                    Float(max(boundsSize.width, 1.0)),
                    Float(max(boundsSize.height, 1.0)),
                    smoothT,
                    3.0
                )
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                let maxInlineQuads = 64
                var offset = 0
                while offset < folderMaskQuads.count {
                    let count = min(maxInlineQuads, folderMaskQuads.count - offset)
                    folderMaskQuads.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        encoder.setVertexBytes(
                            base.advanced(by: offset),
                            length: count * MemoryLayout<SIMD4<Float>>.stride,
                            index: 0
                        )
                    }
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
                    offset += count
                }
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            onSubmission?(generation, true)
            guard let self else { return }
            self.queue.async {
                guard generation == self.activeGeneration else { return }
                self.isBlurInFlight = false
                if let next = self.pendingBlur {
                    self.pendingBlur = nil
                    self.isBlurInFlight = true
                    self.executeBlur(
                        progress: next.progress,
                        materialProgress: next.materialProgress,
                        generation: generation,
                        scale: scale,
                        boundsSize: boundsSize,
                        folderMaskQuads: folderMaskQuads,
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
    private var currentBoundsSize: CGSize = .zero
    private var folderMaskQuads: [SIMD4<Float>] = []

    var onReadyChange: (@MainActor (Bool) -> Void)?
    private(set) var isReady = false
    private(set) var isBaking = false
    private(set) var bakeFailed = false

    private let worker = BackdropBlurWorker()
    private var generation: UInt64 = 0

    private struct BackdropPrewarmKey: Equatable {
        let deviceID: ObjectIdentifier
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat
        let pixelFormat: MTLPixelFormat
    }
    private var lastPrewarmKey: BackdropPrewarmKey?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func currentQualityUsesUnorm8() -> Bool {
        let raw = UserDefaults.standard.string(forKey: "iconRenderQuality")
        return raw != "quality"
    }

    private func targetPixelFormat() -> MTLPixelFormat {
        currentQualityUsesUnorm8() ? .bgra8Unorm : .rgba16Float
    }

    private func targetColorSpace() -> CGColorSpace? {
        CGColorSpace(
            name: currentQualityUsesUnorm8()
                ? CGColorSpace.displayP3
                : CGColorSpace.extendedLinearDisplayP3
        )
    }

    private func applyLayerConfiguration() {
        let format = targetPixelFormat()
        if metalLayer.pixelFormat != format {
            metalLayer.pixelFormat = format
        }
        metalLayer.colorspace = targetColorSpace()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        containerLayer.masksToBounds = false
        containerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        metalLayer.isOpaque = false
        applyLayerConfiguration()
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
        applyLayerConfiguration()
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

    /// Allocates or reuses the texture matching the exact Retina framebuffer dimensions and pixel format.
    private func ensureTexture(
        device: MTLDevice,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> MTLTexture? {
        let format = targetPixelFormat()
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        if cachedPixelSize == size, let raw = rawTexture, raw.pixelFormat == format {
            return raw
        }

        cachedPixelSize = size
        rawTexture = nil

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
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
        let pixelWidth = max(1, Int((boundsSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((boundsSize.height * scale).rounded()))
        let format = targetPixelFormat()
        let key = BackdropPrewarmKey(
            deviceID: ObjectIdentifier(device),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale,
            pixelFormat: format
        )
        if lastPrewarmKey == key, rawTexture != nil {
            return
        }
        lastPrewarmKey = key

        self.device = device
        self.commandQueue = commandQueue
        self.currentScale = scale
        applyLayerConfiguration()
        _ = ensureTexture(device: device, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        metalLayer.device = device
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)
        worker.prewarmKernels(
            device: device,
            commandQueue: commandQueue,
            scale: scale,
            pixelFormat: format
        )
    }

    func setFolderMaskRects(_ rects: [CGRect]) {
        folderMaskQuads = rects.compactMap { rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            let outsetSideTop = rect.width * 0.22
            let outsetBottom = rect.height * 0.11 + 4.5
            return SIMD4<Float>(
                Float(rect.minX - outsetSideTop),
                Float(rect.minY - outsetSideTop),
                Float(rect.maxX + outsetSideTop),
                Float(rect.maxY + outsetBottom)
            )
        }
    }

    /// Bakes the sharp root grid once into the offscreen texture.
    func bake(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        boundsSize: CGSize,
        scale: CGFloat,
        initialProgress: CGFloat = 0.0,
        initialMaterialProgress: CGFloat = 0.0,
        renderPass: (MTLCommandBuffer, MTLTexture) -> Void
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.currentScale = scale
        self.currentBoundsSize = boundsSize
        self.folderMaskQuads = []
        applyLayerConfiguration()
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

        let clampedInitProgress = Float(min(max(initialProgress, 0), 1))
        let clampedInitMaterial = Float(min(max(initialMaterialProgress, 0), 1))
        worker.schedule(
            progress: clampedInitProgress,
            materialProgress: clampedInitMaterial,
            generation: currentGen,
            scale: scale,
            boundsSize: boundsSize,
            folderMaskQuads: folderMaskQuads,
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
    func updateProgress(_ progress: CGFloat, materialProgress: CGFloat = 1.0) {
        guard isReady || isBaking else { return }

        let local = min(max(progress, 0), 1)
        let localMaterial = min(max(materialProgress, 0), 1)
        let effectiveBoundsSize = currentBoundsSize.width >= 1 ? currentBoundsSize : bounds.size

        if let rawTex = rawTexture, let device, let commandQueue {
            worker.schedule(
                progress: Float(local),
                materialProgress: Float(localMaterial),
                generation: generation,
                scale: currentScale,
                boundsSize: effectiveBoundsSize,
                folderMaskQuads: folderMaskQuads,
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
