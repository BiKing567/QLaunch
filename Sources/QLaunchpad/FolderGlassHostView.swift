import AppKit
import ImageIO
import QLaunchpadCore
import QuartzCore

/// Geometric and content descriptor for an active folder glass plate on screen.
struct FolderPlateModel: Equatable, Sendable {
    let id: String
    let rect: CGRect
    let alpha: Float
    let members: [AppInfo]
    let previewVisible: Bool
    let iconSize: CGFloat
    let incomingDropAppID: String?
    let isIsolated: Bool
    let customCornerRadius: CGFloat?

    init(
        id: String,
        rect: CGRect,
        alpha: Float,
        members: [AppInfo],
        previewVisible: Bool,
        iconSize: CGFloat,
        incomingDropAppID: String? = nil,
        isIsolated: Bool = false,
        customCornerRadius: CGFloat? = nil
    ) {
        self.id = id
        self.rect = rect
        self.alpha = alpha
        self.members = members
        self.previewVisible = previewVisible
        self.iconSize = iconSize
        self.incomingDropAppID = incomingDropAppID
        self.isIsolated = isIsolated
        self.customCornerRadius = customCornerRadius
    }
}

/// High-resolution image provider that extracts crisp 512x512 retina CGImages directly.
final class AppIconImageProvider: @unchecked Sendable {
    static let shared = AppIconImageProvider()
    private let cache = NSCache<NSString, CGImage>()
    private var cachedKeys = Set<String>()
    private let queue = DispatchQueue(label: "com.qzrzz.qlaunchpad.preview-load", qos: .userInitiated)
    private let lock = NSLock()
    private var inflightCallbacks: [String: [@MainActor (CGImage?) -> Void]] = [:]
    private var currentAppearanceName: String = (NSApp.effectiveAppearance.name).rawValue
    private var currentAppearance: NSAppearance = NSApp.effectiveAppearance
    private var targetAppearance: NSAppearance?
    private var appearanceGeneration: UInt64 = 0

    private init() {
        // Budget: ~120 MB (up to ~120-150 512x512 32-bit images)
        cache.totalCostLimit = 120 * 1024 * 1024
        cache.countLimit = 200
    }

    func setAppearance(_ appearance: NSAppearance) {
        let name = appearance.name.rawValue
        lock.lock()
        guard name != currentAppearanceName else {
            lock.unlock()
            return
        }
        currentAppearanceName = name
        currentAppearance = appearance
        targetAppearance = nil
        appearanceGeneration &+= 1
        inflightCallbacks.removeAll()
        lock.unlock()
    }

    func setTargetAppearance(_ appearance: NSAppearance, generation: UInt64) {
        lock.lock()
        targetAppearance = appearance
        appearanceGeneration = generation
        inflightCallbacks.removeAll()
        lock.unlock()
    }

    func commitAppearanceChange(_ appearance: NSAppearance) {
        let name = appearance.name.rawValue
        lock.lock()
        currentAppearanceName = name
        currentAppearance = appearance
        targetAppearance = nil

        var readyPaths = Set<String>()
        var staleKeys = Set<String>()
        for k in cachedKeys {
            let nsKey = k as NSString
            if cache.object(forKey: nsKey) == nil {
                staleKeys.insert(k)
            } else if k.hasSuffix("|\(name)") {
                if let sep = k.lastIndex(of: "|") {
                    readyPaths.insert(String(k[..<sep]))
                }
            }
        }
        for k in staleKeys {
            cachedKeys.remove(k)
        }

        let toRemove = cachedKeys.filter { k in
            guard !k.hasSuffix("|\(name)") else { return false }
            if let sep = k.lastIndex(of: "|") {
                let path = String(k[..<sep])
                return readyPaths.contains(path)
            }
            return false
        }
        for k in toRemove {
            cache.removeObject(forKey: k as NSString)
            cachedKeys.remove(k)
        }
        inflightCallbacks.removeAll()
        lock.unlock()
    }

    private func cacheKey(for app: AppInfo, appearanceName: String) -> NSString {
        "\(app.url.path)|\(appearanceName)" as NSString
    }

    func hasCachedCGImage(for app: AppInfo, appearanceName: String? = nil) -> Bool {
        cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: false) != nil
    }

    func cachedCGImage(
        for app: AppInfo,
        appearanceName: String? = nil,
        allowFallback: Bool = true
    ) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let name = appearanceName ?? currentAppearanceName
        let key = cacheKey(for: app, appearanceName: name)
        if let exact = cache.object(forKey: key) {
            return exact
        }
        guard allowFallback else { return nil }
        let prefix = "\(app.url.path)|"
        for k in cachedKeys {
            if k.hasPrefix(prefix), let img = cache.object(forKey: k as NSString) {
                return img
            }
        }
        return nil
    }

    /// Returns cached image if available. If missing, only creates synchronously
    /// if `allowCreate` is true (non-animation contexts). In animation frames,
    /// pass `allowCreate: false` to avoid blocking the main thread.
    func cgImage(for app: AppInfo, allowCreate: Bool = true) -> CGImage? {
        lock.lock()
        let key = cacheKey(for: app, appearanceName: currentAppearanceName)
        let appGen = appearanceGeneration
        let appAppearance = currentAppearance
        lock.unlock()
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard allowCreate else { return nil }
        return createAndCacheImage(for: app, key: key, appearance: appAppearance, generation: appGen)
    }

    @discardableResult
    func prepare(app: AppInfo) -> CGImage? {
        cgImage(for: app, allowCreate: true)
    }

    func prepare(
        apps: [AppInfo],
        appearance: NSAppearance? = nil,
        generation: UInt64? = nil
    ) {
        for app in apps {
            loadAsync(for: app, appearance: appearance, generation: generation) { _ in }
        }
    }

    func loadAsync(
        for app: AppInfo,
        appearance: NSAppearance? = nil,
        generation: UInt64? = nil,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        let path = app.url.path
        lock.lock()
        let targetApp = appearance ?? targetAppearance ?? currentAppearance
        let targetName = targetApp.name.rawValue
        let key = cacheKey(for: app, appearanceName: targetName)
        let reqKey = "\(path)|\(targetName)"
        let reqGen = generation ?? appearanceGeneration
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        if var callbacks = inflightCallbacks[reqKey] {
            callbacks.append(completion)
            inflightCallbacks[reqKey] = callbacks
            lock.unlock()
            return
        }
        inflightCallbacks[reqKey] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.appearanceGeneration == reqGen else {
                self.inflightCallbacks.removeValue(forKey: reqKey)
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            let cgImage: CGImage?
            if let cached = self.cache.object(forKey: key) {
                cgImage = cached
            } else {
                cgImage = self.createAndCacheImage(for: app, key: key, appearance: targetApp, generation: reqGen)
            }

            self.lock.lock()
            guard self.appearanceGeneration == reqGen else {
                self.inflightCallbacks.removeValue(forKey: reqKey)
                self.lock.unlock()
                return
            }
            let pending = self.inflightCallbacks.removeValue(forKey: reqKey) ?? []
            self.lock.unlock()

            DispatchQueue.main.async {
                for callback in pending {
                    callback(cgImage)
                }
            }
        }
    }

    private func createAndCacheImage(
        for app: AppInfo,
        key: NSString,
        appearance: NSAppearance,
        generation: UInt64
    ) -> CGImage? {
        var cg: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let image = NSWorkspace.shared.icon(forFile: app.url.path)
            // Request 256pt (512px on Retina) to ensure razor-sharp rendering in preview layers
            image.size = NSSize(width: 256, height: 256)
            var proposedRect = CGRect(origin: .zero, size: image.size)
            cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        }
        guard let cg else { return nil }
        lock.lock()
        guard appearanceGeneration == generation else {
            lock.unlock()
            return nil
        }
        let cost = cg.bytesPerRow * cg.height
        cache.setObject(cg, forKey: key, cost: cost)
        cachedKeys.insert(key as String)
        lock.unlock()
        return cg
    }

    func clear() {
        lock.lock()
        cache.removeAllObjects()
        cachedKeys.removeAll()
        inflightCallbacks.removeAll()
        appearanceGeneration &+= 1
        lock.unlock()
    }
}

/// Simple container view with flipped geometry (y = 0 at the top).
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum FolderPlateMaterialStyle: Sendable {
    case glass
    case regular
}

/// An individual folder glass plate item using native CALayer architecture.
///
/// On macOS 26+: uses genuine system `NSGlassEffectView` with `.regular` style
/// and embeds the 3×3 mini-icon preview in `contentView` on top of the glass plate.
/// Preview mini-icons are rendered as independent GPU `CALayer`s inside `contentView`,
/// completely eliminating CPU CoreGraphics bitmap drawing, cache churn, and scale blur.
private final class FolderGlassPlateItemView: NSView {
    private var glassEffectView: NSView?
    private var visualEffectView: NSVisualEffectView?
    private var currentMaterialStyle: FolderPlateMaterialStyle = .glass
    private let sunkContainerView = FlippedContainerView()
    private let contentView = FlippedContainerView()
    private var previewLayers: [CALayer] = []
    private var crossfadePreviewLayers: [CALayer] = []
    private var currentDisplayMemberIDs: [String] = []

    private var lastBoundsSize: CGSize = .zero
    private var lastPreviewBoundsSize: CGSize = .zero
    private var lastCornerRadius: CGFloat = -1
    private var lastAlpha: Float = -1
    private var lastMemberIDs: [String] = []
    private var lastPreviewVisible: Bool = false
    private var lastIconSize: CGFloat = -1
    private var lastScale: CGFloat = -1
    private var lastIncomingDropAppID: String? = nil
    private var lastAppearanceName: String? = nil
    private var currentMembers: [AppInfo] = []
    private var currentPreviewVisible: Bool = false
    private var currentIncomingDropAppID: String? = nil
    private var previewRequestGeneration: UInt64 = 0
    private var lastBlurRadius: CGFloat = -1
    private var lastTransitionProgress: CGFloat = -1
    private var lastMaterialProgress: CGFloat = -1

    private static let filterName = "plateBlur"
    private var blurFilter: CIFilter?

    func resetCachedState() {
        previewRequestGeneration &+= 1
        currentDisplayMemberIDs = []
        lastBoundsSize = .zero
        lastPreviewBoundsSize = .zero
        lastCornerRadius = -1
        lastAlpha = -1
        lastMemberIDs = []
        lastPreviewVisible = false
        lastIconSize = -1
        lastScale = -1
        lastIncomingDropAppID = nil
        lastAppearanceName = nil
        lastBlurRadius = -1
        lastTransitionProgress = -1
        lastMaterialProgress = -1
    }

    func previewImages() -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for (i, id) in currentDisplayMemberIDs.enumerated() {
            guard i < previewLayers.count else { break }
            if let image = previewLayers[i].contents {
                result[id] = (image as! CGImage)
            }
        }
        return result
    }

    var hasReadyPreviews: Bool {
        guard currentPreviewVisible, !currentDisplayMemberIDs.isEmpty else { return false }
        for i in 0..<currentDisplayMemberIDs.count {
            guard i < previewLayers.count else { return false }
            if previewLayers[i].contents == nil || previewLayers[i].isHidden {
                return false
            }
        }
        return true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(frame: NSRect, materialStyle: FolderPlateMaterialStyle = .glass) {
        currentMaterialStyle = materialStyle
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        sunkContainerView.frame = bounds
        sunkContainerView.wantsLayer = true
        sunkContainerView.layer?.masksToBounds = false
        sunkContainerView.layer?.shadowColor = NSColor.black.cgColor
        sunkContainerView.layer?.shadowOpacity = 0.0
        sunkContainerView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        sunkContainerView.layer?.shadowRadius = 8.0
        sunkContainerView.autoresizingMask = [.width, .height]
        addSubview(sunkContainerView)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            glass.autoresizingMask = [.width, .height]
            glass.isHidden = (materialStyle == .regular)
            addSubview(glass, positioned: .below, relativeTo: sunkContainerView)
            glassEffectView = glass
        }

        let visual = NSVisualEffectView(frame: bounds)
        visual.wantsLayer = true
        visual.autoresizingMask = [.width, .height]
        visual.blendingMode = .withinWindow
        visual.state = .active
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true
        visual.isHidden = (materialStyle == .glass && glassEffectView != nil)
        sunkContainerView.addSubview(visual)
        visualEffectView = visual
        updateFallbackAppearance()

        contentView.frame = bounds
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        contentView.autoresizingMask = [.width, .height]
        sunkContainerView.addSubview(contentView, positioned: .above, relativeTo: visual)

        // Pre-create 9 reusable CALayers for the 3×3 grid plus 9 crossfade overlay layers
        for _ in 0..<FolderPreviewLayout.capacity {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
            layer.shadowOpacity = 1.0
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 1.5
            layer.isHidden = true
            contentView.layer?.addSublayer(layer)
            previewLayers.append(layer)

            let crossLayer = CALayer()
            crossLayer.contentsGravity = .resizeAspect
            crossLayer.masksToBounds = false
            crossLayer.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
            crossLayer.shadowOpacity = 1.0
            crossLayer.shadowOffset = CGSize(width: 0, height: 1)
            crossLayer.shadowRadius = 1.5
            crossLayer.isHidden = true
            crossLayer.opacity = 0.0
            contentView.layer?.addSublayer(crossLayer)
            crossfadePreviewLayers.append(crossLayer)
        }
    }

    convenience override init(frame: NSRect) {
        self.init(frame: frame, materialStyle: .glass)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMaterialStyle(_ style: FolderPlateMaterialStyle) {
        guard style != currentMaterialStyle else { return }
        currentMaterialStyle = style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .glass:
            updateTransitionProgress(
                progress: lastTransitionProgress >= 0 ? lastTransitionProgress : 0,
                materialProgress: lastMaterialProgress >= 0 ? lastMaterialProgress : 0
            )
        case .regular:
            glassEffectView?.alphaValue = 0.0
            glassEffectView?.isHidden = true
            visualEffectView?.alphaValue = 1.0
            visualEffectView?.isHidden = false
            sunkContainerView.layer?.shadowOpacity = 0.18
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let currentBounds = bounds
        glassEffectView?.frame = currentBounds
        sunkContainerView.frame = currentBounds
        visualEffectView?.frame = currentBounds
        contentView.frame = currentBounds
        if currentBounds.size != lastBoundsSize {
            lastBoundsSize = currentBounds.size
            let radius = lastCornerRadius > 0 ? lastCornerRadius : 24.0
            let path = CGPath(
                roundedRect: currentBounds,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            sunkContainerView.layer?.shadowPath = path
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackAppearance()
        // Appearance crossfade is coordinated uniformly via updateAppearanceCrossfade / commitAppearanceCrossfade
    }

    private func updateFallbackAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let visual = visualEffectView else { return }
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            visual.material = .hudWindow
            if isDark {
                visual.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.20).cgColor
                visual.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
            } else {
                visual.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
                visual.layer?.borderColor = NSColor(white: 1.0, alpha: 0.35).cgColor
            }
            visual.layer?.borderWidth = 0.5
        }
    }

    func update(
        rect: CGRect,
        cornerRadius: CGFloat,
        alpha: Float,
        members: [AppInfo],
        previewVisible: Bool,
        iconSize: CGFloat,
        incomingDropAppID: String?,
        seedImages: [String: CGImage]? = nil
    ) {
        currentMembers = members
        currentPreviewVisible = previewVisible
        currentIncomingDropAppID = incomingDropAppID

        frame = rect
        let currentBounds = bounds
        let sizeChanged = currentBounds.size != lastBoundsSize
        if sizeChanged {
            glassEffectView?.frame = currentBounds
            sunkContainerView.frame = currentBounds
            visualEffectView?.frame = currentBounds
            contentView.frame = currentBounds
            lastBoundsSize = currentBounds.size
        }
        if alpha != lastAlpha {
            alphaValue = CGFloat(alpha)
            lastAlpha = alpha
        }

        if cornerRadius != lastCornerRadius || sizeChanged {
            if #available(macOS 26.0, *), let glass = glassEffectView as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            }
            visualEffectView?.layer?.cornerRadius = cornerRadius
            let path = CGPath(
                roundedRect: currentBounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            sunkContainerView.layer?.shadowPath = path
            lastCornerRadius = cornerRadius
        }

        guard previewVisible, !members.isEmpty else {
            if lastPreviewVisible != previewVisible || !lastMemberIDs.isEmpty {
                previewRequestGeneration &+= 1
                for layer in previewLayers {
                    layer.isHidden = true
                    layer.contents = nil
                }
                for layer in crossfadePreviewLayers {
                    layer.isHidden = true
                    layer.contents = nil
                }
                lastPreviewVisible = previewVisible
                lastMemberIDs = []
                currentDisplayMemberIDs = []
            }
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let displayMembers = Array(members.prefix(FolderPreviewLayout.capacity))
        let memberIDs = displayMembers.map(\.id)
        let appearanceName = effectiveAppearance.name.rawValue

        let contentUnchanged = currentBounds.size == lastPreviewBoundsSize
            && memberIDs == lastMemberIDs
            && previewVisible == lastPreviewVisible
            && iconSize == lastIconSize
            && scale == lastScale
            && incomingDropAppID == lastIncomingDropAppID
            && appearanceName == lastAppearanceName

        if contentUnchanged {
            return
        }

        previewRequestGeneration &+= 1
        let requestGen = previewRequestGeneration

        let previousDisplayMemberIDs = currentDisplayMemberIDs
        let previousAppearanceName = lastAppearanceName
        let canRetainExistingImages = previousDisplayMemberIDs == memberIDs && previousAppearanceName == appearanceName

        lastPreviewBoundsSize = currentBounds.size
        lastMemberIDs = memberIDs
        lastPreviewVisible = previewVisible
        lastIconSize = iconSize
        lastScale = scale
        lastIncomingDropAppID = incomingDropAppID
        lastAppearanceName = appearanceName
        currentDisplayMemberIDs = memberIDs

        let side = min(currentBounds.width, currentBounds.height)
        let folderCenter = CGPoint(x: side * 0.5, y: side * 0.5)
        let effectiveIconSize = iconSize > 0 ? iconSize : (side / 0.8125)
        let miniSize = FolderPreviewLayout.miniSize(in: effectiveIconSize)

        for (index, layer) in previewLayers.enumerated() {
            if index < displayMembers.count {
                let app = displayMembers[index]

                // Ghost icon elimination: hide mini icon if this app is actively being dragged over the folder
                if let incomingDropAppID, app.id == incomingDropAppID {
                    layer.isHidden = true
                    if index < crossfadePreviewLayers.count {
                        crossfadePreviewLayers[index].isHidden = true
                    }
                    continue
                }

                let center = FolderPreviewLayout.miniCenter(
                    index: index,
                    folderCenter: folderCenter,
                    folderSize: effectiveIconSize,
                    yIncreasesDown: true
                )

                // Pixel snap to avoid retina subpixel blur
                let originX = ((center.x - miniSize * 0.5) * scale).rounded() / scale
                let originY = ((center.y - miniSize * 0.5) * scale).rounded() / scale
                let snappedSize = (miniSize * scale).rounded() / scale

                layer.frame = CGRect(x: originX, y: originY, width: snappedSize, height: snappedSize)
                layer.contentsScale = scale
                layer.shadowOffset = CGSize(width: 0, height: 1.0 * (side / 128.0))
                layer.shadowRadius = 1.5 * (side / 128.0)

                let canRetainExistingImage = (canRetainExistingImages || (index < previousDisplayMemberIDs.count && previousDisplayMemberIDs[index] == app.id && previousAppearanceName == appearanceName)) && layer.contents != nil

                if let cgImage = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: true) {
                    layer.contents = cgImage
                    layer.isHidden = false
                } else if let seed = seedImages?[app.id] {
                    layer.contents = seed
                    layer.isHidden = false
                } else {
                    if !canRetainExistingImage {
                        layer.isHidden = true
                        layer.contents = nil
                    }
                    AppIconImageProvider.shared.loadAsync(for: app) { [weak self, weak layer] cgImage in
                        guard let self, let layer, let cgImage else { return }
                        guard self.previewRequestGeneration == requestGen else { return }
                        guard self.currentPreviewVisible else { return }
                        guard self.currentDisplayMemberIDs.indices.contains(index),
                              self.currentDisplayMemberIDs[index] == app.id else { return }
                        if let incoming = self.currentIncomingDropAppID, incoming == app.id { return }
                        layer.contents = cgImage
                        layer.isHidden = false
                    }
                }
            } else {
                layer.isHidden = true
                layer.contents = nil
                if index < crossfadePreviewLayers.count {
                    crossfadePreviewLayers[index].isHidden = true
                    crossfadePreviewLayers[index].contents = nil
                }
            }
        }
    }

    private static func blendCrossfadeImages(old: CGImage, new: CGImage, progress: CGFloat) -> CGImage? {
        if old === new { return new }
        let w = max(old.width, new.width)
        let h = max(old.height, new.height)
        guard w > 0, h > 0 else { return new }
        let colorSpace = new.colorSpace ?? old.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return new }

        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setAlpha(1.0 - progress)
        ctx.draw(old, in: rect)
        ctx.setBlendMode(.plusLighter)
        ctx.setAlpha(progress)
        ctx.draw(new, in: rect)
        return ctx.makeImage()
    }

    func updateAppearanceCrossfade(
        progress: CGFloat,
        fromAppearance: NSAppearance,
        toAppearance: NSAppearance
    ) {
        guard currentPreviewVisible, !currentMembers.isEmpty else { return }
        let displayMembers = Array(currentMembers.prefix(FolderPreviewLayout.capacity))
        let toName = toAppearance.name.rawValue
        let fromName = fromAppearance.name.rawValue
        let p = Float(min(1.0, max(0.0, progress)))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, layer) in previewLayers.enumerated() {
            guard index < displayMembers.count, index < crossfadePreviewLayers.count else {
                continue
            }
            let app = displayMembers[index]
            if let incoming = currentIncomingDropAppID, app.id == incoming {
                layer.isHidden = true
                crossfadePreviewLayers[index].isHidden = true
                continue
            }
            let crossLayer = crossfadePreviewLayers[index]
            crossLayer.isHidden = true
            crossLayer.contents = nil
            crossLayer.opacity = 0.0

            let newImg = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: toName, allowFallback: false)
                ?? AppIconImageProvider.shared.cachedCGImage(for: app)
            let oldImg = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: fromName, allowFallback: false)
                ?? AppIconImageProvider.shared.cachedCGImage(for: app, allowFallback: true)

            if let oldImg, let newImg {
                if p <= 0.001 {
                    layer.contents = oldImg
                    layer.opacity = 1.0
                    layer.isHidden = false
                } else if p >= 0.999 {
                    layer.contents = newImg
                    layer.opacity = 1.0
                    layer.isHidden = false
                } else {
                    let blended = Self.blendCrossfadeImages(old: oldImg, new: newImg, progress: CGFloat(p)) ?? newImg
                    layer.contents = blended
                    layer.opacity = 1.0
                    layer.isHidden = false
                }
            } else if let oldImg {
                layer.contents = oldImg
                layer.opacity = Float(1.0 - p)
                layer.isHidden = false
            } else if let newImg {
                layer.contents = newImg
                layer.opacity = Float(p)
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    func commitAppearanceCrossfade(toAppearance: NSAppearance) {
        let toName = toAppearance.name.rawValue
        lastAppearanceName = toName
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let displayMembers = Array(currentMembers.prefix(FolderPreviewLayout.capacity))
        for (index, layer) in previewLayers.enumerated() {
            if index < displayMembers.count {
                let app = displayMembers[index]
                if let newImg = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: toName, allowFallback: true) {
                    layer.contents = newImg
                }
                layer.opacity = 1.0
                layer.isHidden = false
            }
            if index < crossfadePreviewLayers.count {
                let crossLayer = crossfadePreviewLayers[index]
                crossLayer.contents = nil
                crossLayer.opacity = 0.0
                crossLayer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// Updates material cross-fade (driven by materialProgress in [0, 1]) and Gaussian blur (driven by progress in [0, 1]).
    func updateTransitionProgress(progress: CGFloat, materialProgress: CGFloat) {
        let localProgress = min(max(progress, 0), 1)
        let localMaterial = min(max(materialProgress, 0), 1)
        if abs(localProgress - lastTransitionProgress) < 0.001 && abs(localMaterial - lastMaterialProgress) < 0.001 {
            return
        }
        lastTransitionProgress = localProgress
        lastMaterialProgress = localMaterial

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Cross-fade baseplates strictly driven by materialProgress (0 = 100% glass, 1 = 100% lightweight plate).
        // Overlap duration is limited to <= 80ms by the animation clock with a single Hermite ease.
        if localMaterial <= 0.0001 {
            // Resting desktop state: 100% native glass, lightweight plate hidden
            if glassEffectView != nil {
                glassEffectView?.alphaValue = 1.0
                glassEffectView?.isHidden = false
                visualEffectView?.alphaValue = 0.0
                visualEffectView?.isHidden = true
                sunkContainerView.layer?.shadowOpacity = 0.0
            } else {
                visualEffectView?.alphaValue = 1.0
                visualEffectView?.isHidden = false
                sunkContainerView.layer?.shadowOpacity = 0.18
            }
        } else if localMaterial >= 0.9999 {
            // Sunk / open phase: 100% lightweight plate, native glass completely hidden
            glassEffectView?.alphaValue = 0.0
            glassEffectView?.isHidden = true
            visualEffectView?.alphaValue = 1.0
            visualEffectView?.isHidden = false
            sunkContainerView.layer?.shadowOpacity = 0.18
        } else {
            // Inside handoff: single smooth Hermite cross-fade between glass and lightweight plate.
            let smoothT = localMaterial * localMaterial * (3.0 - 2.0 * localMaterial)
            let visualAlpha = smoothT
            let glassAlpha = 1.0 - smoothT

            if glassEffectView != nil {
                glassEffectView?.alphaValue = glassAlpha
                glassEffectView?.isHidden = false
                visualEffectView?.alphaValue = visualAlpha
                visualEffectView?.isHidden = false
                sunkContainerView.layer?.shadowOpacity = Float(smoothT) * 0.18
            } else {
                visualEffectView?.alphaValue = 1.0
                visualEffectView?.isHidden = false
                sunkContainerView.layer?.shadowOpacity = 0.18
            }
        }

        // 2. Continuous depth blur driven by spatial progress
        let blurRadius = 16.0 * localProgress
        applyBlurRadius(blurRadius)

        CATransaction.commit()
    }

    private func applyBlurRadius(_ blurRadius: CGFloat) {
        if abs(blurRadius - lastBlurRadius) < 0.02 {
            return
        }
        lastBlurRadius = blurRadius

        let targetLayer = sunkContainerView.layer
        if blurRadius > 0.05 {
            if targetLayer?.filters == nil || targetLayer?.filters?.isEmpty == true {
                let filter = blurFilter ?? CIFilter(name: "CIGaussianBlur")
                blurFilter = filter
                filter?.name = Self.filterName
                filter?.setValue(blurRadius, forKey: kCIInputRadiusKey)
                if let filter {
                    targetLayer?.filters = [filter]
                }
            } else {
                targetLayer?.setValue(blurRadius, forKeyPath: "filters.\(Self.filterName).inputRadius")
            }
        } else {
            if targetLayer?.filters != nil {
                targetLayer?.setValue(0.0, forKeyPath: "filters.\(Self.filterName).inputRadius")
                targetLayer?.filters = nil
            }
        }
    }
}

/// Host view placed directly behind `LaunchpadMetalView`.
///
/// On macOS 26+: each folder is rendered with genuine system `NSGlassEffectView`
/// as independent glass surfaces without a shared proximity-fusion container.
/// This guarantees:
/// 1. Folders never fuse/melt together into a single liquid blob when dragged near each other.
/// 2. Dragging/reordering is 100% artifact-free with zero ghosting.
@MainActor
final class FolderGlassHostView: NSView {
    var reusableSinglePlateID: String? = nil
    var currentMaterialStyle: FolderPlateMaterialStyle = .glass {
        didSet {
            guard currentMaterialStyle != oldValue else { return }
            for item in itemsByID.values {
                item.setMaterialStyle(currentMaterialStyle)
            }
        }
    }
    private let hostView = FlippedContainerView()
    private var itemsByID: [String: FolderGlassPlateItemView] = [:]
    private var currentRawSinkTransform: CATransform3D?
    private var currentTransitionProgress: CGFloat = 0
    private var currentMaterialProgress: CGFloat = 0

    func setMaterialStyle(_ style: FolderPlateMaterialStyle) {
        currentMaterialStyle = style
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = false
        addSubview(hostView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func centeredTransform(for transform: CATransform3D, in bounds: CGRect) -> CATransform3D {
        guard bounds.width > 0, bounds.height > 0 else { return transform }
        let midX = bounds.midX
        let midY = bounds.midY
        let toOrigin = CATransform3DMakeTranslation(-midX, -midY, 0)
        let fromOrigin = CATransform3DMakeTranslation(midX, midY, 0)
        return CATransform3DConcat(CATransform3DConcat(toOrigin, transform), fromOrigin)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.frame = bounds
        if let raw = currentRawSinkTransform {
            hostView.layer?.sublayerTransform = centeredTransform(for: raw, in: bounds)
        } else {
            hostView.layer?.sublayerTransform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    func prewarmPlate(id: String) {
        if itemsByID[id] == nil {
            let item = FolderGlassPlateItemView(frame: .zero, materialStyle: currentMaterialStyle)
            item.isHidden = true
            item.updateTransitionProgress(progress: currentTransitionProgress, materialProgress: currentMaterialProgress)
            hostView.addSubview(item)
            itemsByID[id] = item
        }
    }

    func previewImages(for id: String) -> [String: CGImage] {
        itemsByID[reusableSinglePlateID ?? id]?.previewImages() ?? itemsByID[id]?.previewImages() ?? [:]
    }

    func hasReadyPreviews(for id: String) -> Bool {
        itemsByID[reusableSinglePlateID ?? id]?.hasReadyPreviews ?? itemsByID[id]?.hasReadyPreviews ?? false
    }

    func update(
        plates: [FolderPlateModel],
        removeUnused: Bool = true,
        seedImagesByID: [String: [String: CGImage]]? = nil
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var activeIDs = Set<String>()
        for plate in plates {
            guard plate.rect.width >= 1, plate.rect.height >= 1, plate.alpha > 0.005 else {
                continue
            }
            let plateID = reusableSinglePlateID ?? plate.id
            activeIDs.insert(plateID)
            let item: FolderGlassPlateItemView
            if let existing = itemsByID[plateID] {
                item = existing
                item.setMaterialStyle(currentMaterialStyle)
            } else {
                item = FolderGlassPlateItemView(frame: plate.rect, materialStyle: currentMaterialStyle)
                hostView.addSubview(item)
                itemsByID[plateID] = item
            }
            item.updateTransitionProgress(progress: currentTransitionProgress, materialProgress: currentMaterialProgress)

            // If an item is being actively dragged, bring it to the front so it floats above stationary folders
            if plate.isIsolated && item.superview === hostView {
                hostView.addSubview(item)
            }

            let cornerRadius = plate.customCornerRadius ?? (plate.rect.width * 0.225)
            let seedImages = seedImagesByID?[plateID] ?? seedImagesByID?[plate.id]
            item.update(
                rect: plate.rect,
                cornerRadius: cornerRadius,
                alpha: plate.alpha,
                members: plate.members,
                previewVisible: plate.previewVisible,
                iconSize: plate.iconSize,
                incomingDropAppID: plate.incomingDropAppID,
                seedImages: seedImages
            )
            item.isHidden = false
        }

        if removeUnused {
            for (id, item) in itemsByID where !activeIDs.contains(id) {
                item.isHidden = true
            }
        }

        CATransaction.commit()
    }

    func setPlateHidden(_ isHidden: Bool, for id: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemsByID[id]?.isHidden = isHidden
        CATransaction.commit()
    }

    func setAllPlatesHidden(_ isHidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in itemsByID.values {
            item.isHidden = isHidden
        }
        CATransaction.commit()
    }

    /// Applies the shared depth backdrop sink transform (scale and translateY) and drives material cross-fade / blur.
    func applySinkTransform(_ transform: CATransform3D, progress: CGFloat, materialProgress: CGFloat) {
        currentRawSinkTransform = transform
        currentTransitionProgress = progress
        currentMaterialProgress = materialProgress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.layer?.sublayerTransform = centeredTransform(for: transform, in: bounds)
        for item in itemsByID.values {
            item.updateTransitionProgress(progress: progress, materialProgress: materialProgress)
        }
        CATransaction.commit()
    }

    /// Resets the sink transform to identity and restores desktop glass state.
    func resetSinkTransform() {
        currentRawSinkTransform = nil
        currentTransitionProgress = 0
        currentMaterialProgress = 0
        currentMaterialStyle = .glass
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.layer?.sublayerTransform = CATransform3DIdentity
        for item in itemsByID.values {
            item.updateTransitionProgress(progress: 0, materialProgress: 0)
        }
        CATransaction.commit()
    }

    func removeAllPlates() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, item) in itemsByID {
            item.updateTransitionProgress(progress: 0, materialProgress: 0)
            item.resetCachedState()
            item.removeFromSuperview()
        }
        itemsByID.removeAll()
        currentRawSinkTransform = nil
        currentTransitionProgress = 0
        currentMaterialProgress = 0
        hostView.layer?.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppIconImageProvider.shared.setAppearance(effectiveAppearance)
        for item in itemsByID.values {
            item.viewDidChangeEffectiveAppearance()
        }
    }

    func updateAppearanceCrossfade(
        progress: CGFloat,
        fromAppearance: NSAppearance,
        toAppearance: NSAppearance
    ) {
        for item in itemsByID.values {
            item.updateAppearanceCrossfade(
                progress: progress,
                fromAppearance: fromAppearance,
                toAppearance: toAppearance
            )
        }
    }

    func commitAppearanceCrossfade(toAppearance: NSAppearance) {
        for item in itemsByID.values {
            item.commitAppearanceCrossfade(toAppearance: toAppearance)
        }
    }

    func clearCache() {
        AppIconImageProvider.shared.clear()
        for item in itemsByID.values {
            item.resetCachedState()
        }
    }
}
