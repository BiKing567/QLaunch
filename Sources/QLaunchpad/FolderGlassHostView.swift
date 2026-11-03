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
    private let queue = DispatchQueue(label: "com.qzrzz.qlaunchpad.preview-load", qos: .userInitiated)
    private var inflightRequests = Set<String>()

    private init() {
        // Budget: ~120 MB (up to ~120-150 512x512 32-bit images)
        cache.totalCostLimit = 120 * 1024 * 1024
        cache.countLimit = 200
    }

    func hasCachedCGImage(for app: AppInfo) -> Bool {
        let key = app.url.path as NSString
        return cache.object(forKey: key) != nil
    }

    func cachedCGImage(for app: AppInfo) -> CGImage? {
        let key = app.url.path as NSString
        return cache.object(forKey: key)
    }

    /// Returns cached image if available. If missing, only creates synchronously
    /// if `allowCreate` is true (non-animation contexts). In animation frames,
    /// pass `allowCreate: false` to avoid blocking the main thread.
    func cgImage(for app: AppInfo, allowCreate: Bool = true) -> CGImage? {
        let key = app.url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard allowCreate else { return nil }
        return createAndCacheImage(for: app)
    }

    @discardableResult
    func prepare(app: AppInfo) -> CGImage? {
        let key = app.url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        return createAndCacheImage(for: app)
    }

    func prepare(apps: [AppInfo]) {
        for app in apps {
            autoreleasepool {
                _ = prepare(app: app)
            }
        }
    }

    func loadAsync(for app: AppInfo, completion: @escaping @MainActor (CGImage?) -> Void) {
        let path = app.url.path
        queue.async { [weak self] in
            guard let self else { return }
            if self.inflightRequests.contains(path) { return }
            self.inflightRequests.insert(path)
            let cg = self.createAndCacheImage(for: app)
            self.inflightRequests.remove(path)
            DispatchQueue.main.async {
                completion(cg)
            }
        }
    }

    private func createAndCacheImage(for app: AppInfo) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        // Request 256pt (512px on Retina) to ensure razor-sharp rendering in preview layers
        image.size = NSSize(width: 256, height: 256)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let cost = cg.bytesPerRow * cg.height
        cache.setObject(cg, forKey: app.url.path as NSString, cost: cost)
        return cg
    }

    func clear() {
        cache.removeAllObjects()
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
    private var lastBlurRadius: CGFloat = -1
    private var lastTransitionProgress: CGFloat = -1
    private var lastMaterialProgress: CGFloat = -1

    private static let filterName = "plateBlur"
    private var blurFilter: CIFilter?

    func resetCachedState() {
        lastBoundsSize = .zero
        lastPreviewBoundsSize = .zero
        lastCornerRadius = -1
        lastAlpha = -1
        lastMemberIDs = []
        lastPreviewVisible = false
        lastIconSize = -1
        lastScale = -1
        lastIncomingDropAppID = nil
        lastBlurRadius = -1
        lastTransitionProgress = -1
        lastMaterialProgress = -1
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

        // Pre-create 9 reusable CALayers for the 3×3 grid
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
            sunkContainerView.layer?.shadowOpacity = 0.03
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassEffectView?.frame = bounds
        sunkContainerView.frame = bounds
        visualEffectView?.frame = bounds
        contentView.frame = bounds
        lastBoundsSize = bounds.size
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackAppearance()
    }

    private func updateFallbackAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let visual = visualEffectView else { return }
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            visual.material = .hudWindow
            if isDark {
                visual.layer?.backgroundColor = NSColor.clear.cgColor
                visual.layer?.borderColor = NSColor(white: 1.0, alpha: 0.02).cgColor
            } else {
                visual.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.025).cgColor
                visual.layer?.borderColor = NSColor(white: 1.0, alpha: 0.05).cgColor
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
        incomingDropAppID: String?
    ) {
        frame = rect
        let currentBounds = bounds
        if currentBounds.size != lastBoundsSize {
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

        if cornerRadius != lastCornerRadius || currentBounds.size != lastBoundsSize {
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
                for layer in previewLayers { layer.isHidden = true }
                lastPreviewVisible = previewVisible
                lastMemberIDs = []
            }
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let displayMembers = Array(members.prefix(FolderPreviewLayout.capacity))
        let memberIDs = displayMembers.map(\.id)

        let contentUnchanged = currentBounds.size == lastPreviewBoundsSize
            && memberIDs == lastMemberIDs
            && previewVisible == lastPreviewVisible
            && iconSize == lastIconSize
            && scale == lastScale
            && incomingDropAppID == lastIncomingDropAppID

        if contentUnchanged {
            return
        }

        lastPreviewBoundsSize = currentBounds.size
        lastMemberIDs = memberIDs
        lastPreviewVisible = previewVisible
        lastIconSize = iconSize
        lastScale = scale
        lastIncomingDropAppID = incomingDropAppID
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

                if let cgImage = AppIconImageProvider.shared.cachedCGImage(for: app) {
                    layer.contents = cgImage
                    layer.isHidden = false
                } else {
                    layer.contents = nil
                    layer.isHidden = true
                    AppIconImageProvider.shared.loadAsync(for: app) { [weak self, weak layer] cgImage in
                        guard let self, let layer, let cgImage else { return }
                        guard self.currentDisplayMemberIDs.indices.contains(index),
                              self.currentDisplayMemberIDs[index] == app.id else { return }
                        layer.contents = cgImage
                        layer.isHidden = false
                    }
                }
            } else {
                layer.isHidden = true
            }
        }
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
                sunkContainerView.layer?.shadowOpacity = 0.03
            }
        } else if localMaterial >= 0.9999 {
            // Sunk / open phase: 100% lightweight plate, native glass completely hidden
            glassEffectView?.alphaValue = 0.0
            glassEffectView?.isHidden = true
            visualEffectView?.alphaValue = 1.0
            visualEffectView?.isHidden = false
            sunkContainerView.layer?.shadowOpacity = 0.03
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
                sunkContainerView.layer?.shadowOpacity = Float(smoothT) * 0.03
            } else {
                visualEffectView?.alphaValue = 1.0
                visualEffectView?.isHidden = false
                sunkContainerView.layer?.shadowOpacity = 0.03
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

    func update(plates: [FolderPlateModel], removeUnused: Bool = true) {
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
            item.update(
                rect: plate.rect,
                cornerRadius: cornerRadius,
                alpha: plate.alpha,
                members: plate.members,
                previewVisible: plate.previewVisible,
                iconSize: plate.iconSize,
                incomingDropAppID: plate.incomingDropAppID
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
            item.setMaterialStyle(.glass)
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

    func clearCache() {
        AppIconImageProvider.shared.clear()
    }
}
