import AppKit
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

    init(
        id: String,
        rect: CGRect,
        alpha: Float,
        members: [AppInfo],
        previewVisible: Bool,
        iconSize: CGFloat,
        incomingDropAppID: String? = nil
    ) {
        self.id = id
        self.rect = rect
        self.alpha = alpha
        self.members = members
        self.previewVisible = previewVisible
        self.iconSize = iconSize
        self.incomingDropAppID = incomingDropAppID
    }
}

/// In-memory image provider that leverages AppKit's system icon cache.
@MainActor
final class AppIconImageProvider {
    static let shared = AppIconImageProvider()
    private var cache = NSCache<NSString, NSImage>()

    func icon(for app: AppInfo) -> NSImage {
        let key = app.url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }
}

/// An individual folder glass plate item, aligned with LaunchOS architecture.
///
/// On macOS 26+: uses genuine system `NSGlassEffectView` for real-time backdrop refraction.
/// Preview mini-icons are rendered as independent GPU `CALayer`s inside `contentView`,
/// completely eliminating CPU CoreGraphics bitmap drawing, cache churn, and scale blur.
private final class FolderGlassPlateItemView: NSView {
    private var glassEffectView: NSView?
    private let contentView = NSView()
    private var previewLayers: [CALayer] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.wantsLayer = true
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            glassEffectView = glass
        } else {
            let visual = NSVisualEffectView(frame: bounds)
            visual.wantsLayer = true
            visual.autoresizingMask = [.width, .height]
            visual.blendingMode = .withinWindow
            visual.state = .active
            addSubview(visual)
            glassEffectView = visual
            updateFallbackAppearance()
        }

        contentView.frame = bounds
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackAppearance()
    }

    private func updateFallbackAppearance() {
        guard let visual = glassEffectView as? NSVisualEffectView else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        visual.material = isDark ? .hudWindow : .popover
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
            for layer in previewLayers { layer.isHidden = true }
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        contentView.layer?.rasterizationScale = scale

        let side = min(bounds.width, bounds.height)
        let folderCenter = CGPoint(x: side * 0.5, y: side * 0.5)
        let miniSize = FolderPreviewLayout.miniSize(in: side)

        let displayMembers = Array(members.prefix(FolderPreviewLayout.capacity))

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
                    folderSize: side,
                    yIncreasesDown: true
                )

                // Pixel snap to avoid retina subpixel blur
                let originX = ((center.x - miniSize * 0.5) * scale).rounded() / scale
                let originY = ((center.y - miniSize * 0.5) * scale).rounded() / scale
                let snappedSize = (miniSize * scale).rounded() / scale

                layer.frame = CGRect(x: originX, y: originY, width: snappedSize, height: snappedSize)
                layer.contentsScale = scale
                layer.shadowOffset = CGSize(width: 0, height: 1.0 * (side / 128.0))
                layer.shadowRadius = 2.0 * (side / 128.0)

                let icon = AppIconImageProvider.shared.icon(for: app)
                layer.contents = icon.layerContents(forContentsScale: scale)
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
    }
}

@available(macOS 26.0, *)
private final class FlippedGlassContainerView: NSGlassEffectContainerView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Host view placed directly behind `LaunchpadMetalView`.
///
/// On macOS 26+: uses `NSGlassEffectContainerView` with `spacing = 0` for batch-rendering
/// eligible glass plates at 120Hz.
/// Manages native glass plates in sync with Metal frame updates.
@MainActor
final class FolderGlassHostView: NSView {
    private var containerView: NSView?
    private let hostView = FlippedContainerView()
    private var itemsByID: [String: FolderGlassPlateItemView] = [:]

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hostView.wantsLayer = true
        hostView.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let container = FlippedGlassContainerView(frame: bounds)
            container.spacing = 0
            container.autoresizingMask = [.width, .height]
            container.contentView = hostView
            addSubview(container)
            containerView = container
        } else {
            addSubview(hostView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        containerView?.frame = bounds
        hostView.frame = bounds
    }

    func update(plates: [FolderPlateModel]) {
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

            let cornerRadius = plate.rect.width * 0.225
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

        for (id, item) in itemsByID where !activeIDs.contains(id) {
            item.isHidden = true
        }

        CATransaction.commit()
    }

    func clearCache() {
        AppIconImageProvider.shared.clear()
    }

    func removeAllPlates() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, item) in itemsByID {
            item.removeFromSuperview()
        }
        itemsByID.removeAll()
        AppIconImageProvider.shared.clear()
        CATransaction.commit()
    }
}