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
@MainActor
final class AppIconImageProvider {
    static let shared = AppIconImageProvider()
    private var cache = NSCache<NSString, CGImage>()

    func cgImage(for app: AppInfo) -> CGImage? {
        let key = app.url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        // Request 256pt (512px on Retina) to ensure razor-sharp rendering in preview layers
        image.size = NSSize(width: 256, height: 256)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        cache.setObject(cg, forKey: key)
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

/// An individual folder glass plate item using native CALayer architecture.
///
/// On macOS 26+: uses genuine system `NSGlassEffectView` with `.regular` style
/// and embeds the 3×3 mini-icon preview in `contentView` on top of the glass plate.
/// Preview mini-icons are rendered as independent GPU `CALayer`s inside `contentView`,
/// completely eliminating CPU CoreGraphics bitmap drawing, cache churn, and scale blur.
private final class FolderGlassPlateItemView: NSView {
    private var glassEffectView: NSView?
    private let contentView = FlippedContainerView()
    private var previewLayers: [CALayer] = []
    private(set) var memberIDs: [String] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        contentView.frame = bounds
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        contentView.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            glass.autoresizingMask = [.width, .height]
            glass.contentView = contentView
            addSubview(glass)
            glassEffectView = glass
        } else {
            let visual = NSVisualEffectView(frame: bounds)
            visual.wantsLayer = true
            visual.autoresizingMask = [.width, .height]
            visual.blendingMode = .withinWindow
            visual.material = .hudWindow
            visual.state = .active
            visual.layer?.cornerCurve = .continuous
            visual.layer?.masksToBounds = true
            visual.addSubview(contentView)
            addSubview(visual)
            glassEffectView = visual
            updateFallbackAppearance()
        }

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glassEffectView?.frame = bounds
        contentView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackAppearance()
    }

    private func updateFallbackAppearance() {
        guard let visual = glassEffectView as? NSVisualEffectView else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            visual.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            visual.layer?.borderColor = NSColor.separatorColor.cgColor
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
        glassEffectView?.frame = bounds
        contentView.frame = bounds
        alphaValue = CGFloat(alpha)

        if #available(macOS 26.0, *), let glass = glassEffectView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let visual = glassEffectView as? NSVisualEffectView {
            visual.layer?.cornerRadius = cornerRadius
        }

        guard previewVisible, !members.isEmpty else {
            memberIDs = []
            for layer in previewLayers { layer.isHidden = true }
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        let side = min(bounds.width, bounds.height)
        let folderCenter = CGPoint(x: side * 0.5, y: side * 0.5)
        let effectiveIconSize = iconSize > 0 ? iconSize : (side / 0.8125)
        let miniSize = FolderPreviewLayout.miniSize(in: effectiveIconSize)

        let displayMembers = Array(members.prefix(FolderPreviewLayout.capacity))
        memberIDs = displayMembers.map(\.id)

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

                if let cgImage = AppIconImageProvider.shared.cgImage(for: app) {
                    layer.contents = cgImage
                    layer.isHidden = false
                } else {
                    layer.isHidden = true
                }
            } else {
                layer.isHidden = true
            }
        }
    }

    /// Draws the visible mini-icons directly into a flipped CGContext without CPU shadow overhead.
    func drawPreview(in ctx: CGContext) {
        for layer in previewLayers where !layer.isHidden {
            guard let contents = layer.contents,
                  CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { continue }
            let cgImage = contents as! CGImage
            let frame = layer.frame
            ctx.saveGState()
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: frame.size))
            ctx.restoreGState()
        }
    }

    private static let filterName = "plateBlur"
    private var blurFilter: CIFilter?

    /// Smoothly blurs the entire folder plate (liquid glass baseplate + borders + mini-icons)
    /// using a named CIGaussianBlur filter updated via layer keypath, matching the background icons.
    func updateBlur(progress: CGFloat) {
        let local = min(max(progress, 0), 1)
        let blurRadius = 16.0 * local

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if blurRadius > 0.05 {
            if layer?.filters == nil || layer?.filters?.isEmpty == true {
                let filter = blurFilter ?? CIFilter(name: "CIGaussianBlur")
                blurFilter = filter
                filter?.name = Self.filterName
                filter?.setValue(blurRadius, forKey: kCIInputRadiusKey)
                if let filter {
                    layer?.filters = [filter]
                }
            } else {
                layer?.setValue(blurRadius, forKeyPath: "filters.\(Self.filterName).inputRadius")
            }
        } else {
            if layer?.filters != nil {
                layer?.setValue(0.0, forKeyPath: "filters.\(Self.filterName).inputRadius")
                layer?.filters = nil
            }
        }

        CATransaction.commit()
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
    private let hostView = FlippedContainerView()
    private var itemsByID: [String: FolderGlassPlateItemView] = [:]
    private var currentRawSinkTransform: CATransform3D?

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

    func update(plates: [FolderPlateModel], removeUnused: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var activeIDs = Set<String>()
        for plate in plates {
            guard plate.rect.width >= 1, plate.rect.height >= 1, plate.alpha > 0.005 else {
                continue
            }
            activeIDs.insert(plate.id)
            let item: FolderGlassPlateItemView
            if let existing = itemsByID[plate.id] {
                item = existing
            } else {
                item = FolderGlassPlateItemView(frame: plate.rect)
                hostView.addSubview(item)
                itemsByID[plate.id] = item
            }

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

    /// Applies the shared depth backdrop sink transform (scale and translateY) and blurs 9-grid previews.
    func applySinkTransform(_ transform: CATransform3D, progress: CGFloat) {
        currentRawSinkTransform = transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.layer?.sublayerTransform = centeredTransform(for: transform, in: bounds)
        for item in itemsByID.values {
            item.updateBlur(progress: progress)
        }
        CATransaction.commit()
    }

    /// Resets the sink transform to identity and clears 9-grid blur filters.
    func resetSinkTransform() {
        currentRawSinkTransform = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.layer?.sublayerTransform = CATransform3DIdentity
        for item in itemsByID.values {
            item.updateBlur(progress: 0)
        }
        CATransaction.commit()
    }

    func removeAllPlates() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, item) in itemsByID {
            item.updateBlur(progress: 0)
            item.removeFromSuperview()
        }
        itemsByID.removeAll()
        currentRawSinkTransform = nil
        hostView.layer?.sublayerTransform = CATransform3DIdentity
        AppIconImageProvider.shared.clear()
        CATransaction.commit()
    }

    func clearCache() {
        AppIconImageProvider.shared.clear()
    }
}
