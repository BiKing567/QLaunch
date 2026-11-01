import Metal
import QuartzCore

// Only drawable acquisition crosses queues; layer configuration stays on the main actor.
private struct FolderDrawableRequest: @unchecked Sendable {
    let layer: CAMetalLayer

    func nextDrawable() -> CAMetalDrawable? {
        autoreleasepool { layer.nextDrawable() }
    }
}

/// Acquires folder animation drawables without blocking the main run loop.
@MainActor
final class FolderDrawableProvider {
    private let queue = DispatchQueue(
        label: "com.qzrzz.qlaunchpad.folder-drawable",
        qos: .userInteractive
    )
    private var readyDrawable: CAMetalDrawable?
    private var requestInFlight = false
    private var generation: UInt64 = 0
    private var expectedLayer: ObjectIdentifier?
    private var expectedSize: CGSize = .zero
    private var expectedFormat: MTLPixelFormat = .invalid

    func takeOrRequest(
        from layer: CAMetalLayer,
        ready: @escaping @MainActor () -> Void
    ) -> CAMetalDrawable? {
        let size = layer.drawableSize
        let format = layer.pixelFormat
        let identity = ObjectIdentifier(layer)
        if identity != expectedLayer || size != expectedSize || format != expectedFormat {
            invalidate()
            expectedLayer = identity
            expectedSize = size
            expectedFormat = format
        }
        guard size.width >= 1, size.height >= 1 else { return nil }
        if let drawable = readyDrawable {
            readyDrawable = nil
            if drawable.texture.width == Int(size.width.rounded()),
               drawable.texture.height == Int(size.height.rounded()),
               drawable.texture.pixelFormat == format {
                return drawable
            }
        }
        guard !requestInFlight else { return nil }
        requestInFlight = true
        let requestGeneration = generation
        let request = FolderDrawableRequest(layer: layer)
        queue.async { [weak self] in
            let drawable = request.nextDrawable()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.requestInFlight = false
                if requestGeneration == self.generation {
                    self.readyDrawable = drawable
                }
                if drawable != nil { ready() }
            }
        }
        return nil
    }

    func invalidate() {
        guard readyDrawable != nil || expectedLayer != nil else { return }
        // Keep a pending acquisition exclusive until its callback returns.
        generation &+= 1
        readyDrawable = nil
        expectedLayer = nil
        expectedSize = .zero
        expectedFormat = .invalid
    }
}
