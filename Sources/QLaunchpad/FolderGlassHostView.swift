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
}

/// Cache for CPU-rendered 3×3 mini-icon preview images.
@MainActor
final class FolderPreviewImageCache {
    private var cache: [String: NSImage] = [:]
    private var lruKeys: [String] = []
    private let maxCacheCount: Int = 64
    private let iconCache = AppIconCache()

    func previewImage(
        folderID: String,
        members: [AppInfo],
        padSize: CGFloat,
        iconSize: CGFloat
    ) -> NSImage? {
        guard !members.isEmpty, padSize >= 8 else { return nil }

        // Quantize iconSize and padSize into 32pt buckets to prevent continuous CoreGraphics
        // redraw churn during hover bounce (1.0 -> 1.08) or canvas zooming animations.
        // AppKit / CoreAnimation scales the resulting layer smoothly on the GPU.
        let quantizedIconSize = max(64, (iconSize / 32.0).rounded() * 32)
        let quantizedPadSize = max(52, (quantizedIconSize * 0.8125).rounded())

        let memberIDs = members.prefix(FolderPreviewLayout.capacity).map(\.id).joined(separator: ",")
        let cacheKey = "\(folderID)|\(memberIDs)|\(Int(quantizedPadSize))|\(Int(quantizedIconSize))"
        if let existing = cache[cacheKey] {
            if let index = lruKeys.firstIndex(of: cacheKey) {
                lruKeys.remove(at: index)
                lruKeys.append(cacheKey)
            }
            return existing
        }

        let image = NSImage(size: NSSize(width: quantizedPadSize, height: quantizedPadSize), flipped: true) { [iconCache] rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high
            let folderSize = quantizedIconSize
            let miniSize = FolderPreviewLayout.miniSize(in: folderSize)
            let folderCenter = CGPoint(x: quantizedPadSize * 0.5, y: quantizedPadSize * 0.5)

            // Soft contact shadow for each mini app icon against the dynamic glass
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
            shadow.shadowOffset = NSSize(width: 0, height: 1.0 * (folderSize / 128.0))
            shadow.shadowBlurRadius = 2.0 * (folderSize / 128.0)
            shadow.set()

            for (index, app) in members.prefix(FolderPreviewLayout.capacity).enumerated() {
                let center = FolderPreviewLayout.miniCenter(
                    index: index,
                    folderCenter: folderCenter,
                    folderSize: folderSize,
                    yIncreasesDown: true
                )
                let iconRect = NSRect(
                    x: center.x - miniSize * 0.5,
                    y: center.y - miniSize * 0.5,
                    width: miniSize,
                    height: miniSize
                )
                iconCache.image(for: app, size: miniSize).draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            }
            return true
        }

        if lruKeys.count >= maxCacheCount, !lruKeys.isEmpty {
            let oldest = lruKeys.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[cacheKey] = image
        lruKeys.append(cacheKey)
        return image
    }

    func clear() {
        cache.removeAll(keepingCapacity: true)
        lruKeys.removeAll(keepingCapacity: true)
    }
}

/// An individual folder glass plate item.
///
/// On macOS 26+: uses genuine system `NSGlassEffectView` with `.regular` style
/// and embeds the 3×3 mini-icon preview in `contentView`.
/// On macOS 14/15: uses `NSVisualEffectView` fallback.
@MainActor
final class FolderGlassPlateItemView: NSView {
    private var glassEffectView: NSView?
    private let previewImageView = NSImageView()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewImageView.imageScaling = .scaleAxesIndependently

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            glass.contentView = previewImageView
            addSubview(glass)
            glassEffectView = glass
        } else {
            let visual = NSVisualEffectView(frame: bounds)
            visual.blendingMode = .withinWindow
            visual.material = .hudWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerCurve = .continuous
            visual.layer?.masksToBounds = true
            visual.addSubview(previewImageView)
            addSubview(visual)
            glassEffectView = visual
            updateFallbackAppearance()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glassEffectView?.frame = bounds
        previewImageView.frame = bounds
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
        previewImage: NSImage?,
        previewVisible: Bool
    ) {
        frame = rect
        glassEffectView?.frame = bounds
        previewImageView.frame = bounds
        if previewImageView.image !== previewImage {
            previewImageView.image = previewImage
        }
        previewImageView.isHidden = !previewVisible
        alphaValue = CGFloat(alpha)

        if #available(macOS 26.0, *), let glass = glassEffectView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let visual = glassEffectView as? NSVisualEffectView {
            visual.layer?.cornerRadius = cornerRadius
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
    private let previewCache = FolderPreviewImageCache()

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
            let previewImage = plate.previewVisible
                ? previewCache.previewImage(
                    folderID: plate.id,
                    members: plate.members,
                    padSize: plate.rect.width,
                    iconSize: plate.iconSize
                )
                : nil

            item.update(
                rect: plate.rect,
                cornerRadius: cornerRadius,
                alpha: plate.alpha,
                previewImage: previewImage,
                previewVisible: plate.previewVisible
            )
            item.isHidden = false
        }

        for (id, item) in itemsByID where !activeIDs.contains(id) {
            item.isHidden = true
        }

        CATransaction.commit()
    }

    func clearCache() {
        previewCache.clear()
    }

    func removeAllPlates() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, item) in itemsByID {
            item.removeFromSuperview()
        }
        itemsByID.removeAll()
        previewCache.clear()
        CATransaction.commit()
    }
}
