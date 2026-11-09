import AppKit
import ImageIO
import Metal
import QLaunchpadCore
import QuartzCore

/// Caches pre-rendered 3×3 mini-icon composites (with drop shadows) and complete
/// sunk folder textures (outer shadow + sunk baseplate + 3×3 mini-icons) so folder
/// open/close transitions do not recompute 9 mini-icon CALayer shadows and
/// per-folder CIGaussianBlur filters on every frame.
@MainActor
final class FolderPreviewCompositeCache {
    static let shared = FolderPreviewCompositeCache()

    struct MemberKey: Hashable, Sendable {
        let id: String
        let sourcePath: String
        let iconRevision: UInt64
    }

    struct PreviewKey: Hashable, Sendable {
        let members: [MemberKey]
        let appearanceName: String
        let boundsPixelWidth: Int
        let boundsPixelHeight: Int
        let iconPixelSize: Int
        let scaleMilli: Int
        let incomingDropAppID: String?
    }

    struct BaseplateKey: Hashable, Sendable {
        let scaleMilli: Int
        let cornerRadiusMilli: Int
        let isDark: Bool
    }

    struct SunkTextureKey: Hashable, Sendable {
        let previewKey: PreviewKey
        let cornerRadiusMilli: Int
        let isDark: Bool
        let isFloat16: Bool
        let deviceID: ObjectIdentifier
    }

    struct SunkFolderTextureEntry {
        let texture: MTLTexture
        let totalSizePt: CGFloat
    }

    private static let canonicalPlatePt: CGFloat = 104.0
    private static let canonicalIconPt: CGFloat = 128.0

    private static let linearDisplayP3: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
    }()

    private static let displayP3: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
    }()

    private var previewCache: [PreviewKey: CGImage] = [:]
    private var baseplateCache: [BaseplateKey: CGImage] = [:]
    private var sunkTextureCache: [SunkTextureKey: SunkFolderTextureEntry] = [:]
    private let maxEntries = 128

    private init() {}

    func clear() {
        previewCache.removeAll(keepingCapacity: true)
        baseplateCache.removeAll(keepingCapacity: true)
        sunkTextureCache.removeAll(keepingCapacity: true)
    }

    func cachedPreviewComposite(forKey key: PreviewKey) -> CGImage? {
        previewCache[key]
    }

    func invalidate(appearanceName: String) {
        previewCache = previewCache.filter { $0.key.appearanceName != appearanceName }
        sunkTextureCache = sunkTextureCache.filter { $0.key.previewKey.appearanceName != appearanceName }
    }

    func invalidate(for appID: String) {
        previewCache = previewCache.filter { key, _ in
            !key.members.contains(where: { $0.id == appID })
        }
        sunkTextureCache = sunkTextureCache.filter { key, _ in
            !key.previewKey.members.contains(where: { $0.id == appID })
        }
    }

    func makePreviewKey(
        boundsSize: CGSize,
        iconSize: CGFloat,
        scale: CGFloat,
        displayMembers: [AppInfo],
        incomingDropAppID: String?,
        appearanceName: String
    ) -> PreviewKey {
        let pxW = max(1, Int((Self.canonicalPlatePt * scale).rounded()))
        let pxH = pxW
        let iconPx = max(1, Int((Self.canonicalIconPt * scale).rounded()))
        let scaleMilli = Int((scale * 1000).rounded())
        let memberKeys = displayMembers.map {
            MemberKey(
                id: $0.id,
                sourcePath: $0.resourceSourcePath,
                iconRevision: CustomIconStore.shared.iconRevision(for: $0)
            )
        }
        return PreviewKey(
            members: memberKeys,
            appearanceName: appearanceName,
            boundsPixelWidth: pxW,
            boundsPixelHeight: pxH,
            iconPixelSize: iconPx,
            scaleMilli: scaleMilli,
            incomingDropAppID: incomingDropAppID
        )
    }

    func previewCompositeImage(
        boundsSize: CGSize,
        iconSize: CGFloat,
        scale: CGFloat,
        displayMembers: [AppInfo],
        incomingDropAppID: String?,
        appearanceName: String,
        imagesByID: [String: CGImage]
    ) -> CGImage? {
        guard !displayMembers.isEmpty, boundsSize.width >= 1, boundsSize.height >= 1 else {
            return nil
        }
        let key = makePreviewKey(
            boundsSize: boundsSize,
            iconSize: iconSize,
            scale: scale,
            displayMembers: displayMembers,
            incomingDropAppID: incomingDropAppID,
            appearanceName: appearanceName
        )
        if let cached = previewCache[key] {
            return cached
        }

        // Strict verification: only generate and cache if all required members have images.
        for app in displayMembers {
            if let incomingDropAppID, app.id == incomingDropAppID {
                continue
            }
            guard imagesByID[app.id] != nil else {
                return nil
            }
        }

        let pxW = key.boundsPixelWidth
        let pxH = key.boundsPixelHeight
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: Self.displayP3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high

        let side = Self.canonicalPlatePt
        let folderCenter = CGPoint(x: side * 0.5, y: side * 0.5)
        let effectiveIconSize = Self.canonicalIconPt
        let miniSize = FolderPreviewLayout.miniSize(in: effectiveIconSize)

        let shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
        let shadowOffsetY = -1.0 * (side / 128.0) * scale
        let shadowBlur = 1.5 * (side / 128.0) * scale
        ctx.setShadow(
            offset: CGSize(width: 0, height: shadowOffsetY),
            blur: shadowBlur,
            color: shadowColor
        )

        for (index, app) in displayMembers.enumerated() {
            if let incomingDropAppID, app.id == incomingDropAppID {
                continue
            }
            guard let cgImage = imagesByID[app.id] else {
                continue
            }
            let center = FolderPreviewLayout.miniCenter(
                index: index,
                folderCenter: folderCenter,
                folderSize: effectiveIconSize,
                yIncreasesDown: true
            )
            let originX = ((center.x - miniSize * 0.5) * scale).rounded()
            let originYTop = ((center.y - miniSize * 0.5) * scale).rounded()
            let snappedPx = (miniSize * scale).rounded()
            let originYBottom = CGFloat(pxH) - originYTop - snappedPx
            let drawRect = CGRect(x: originX, y: originYBottom, width: snappedPx, height: snappedPx)
            ctx.draw(cgImage, in: drawRect)
        }

        guard let image = ctx.makeImage() else { return nil }
        if previewCache.count >= maxEntries {
            previewCache.removeAll(keepingCapacity: true)
        }
        previewCache[key] = image
        return image
    }

    private func sunkBaseplateTemplateImage(
        totalPx: Int,
        platePx: Int,
        outsetPx: Int,
        scale: CGFloat,
        scaleMilli: Int,
        cornerRadiusPt: CGFloat,
        cornerRadiusMilli: Int,
        isDark: Bool
    ) -> CGImage? {
        let key = BaseplateKey(
            scaleMilli: scaleMilli,
            cornerRadiusMilli: cornerRadiusMilli,
            isDark: isDark
        )
        if let cached = baseplateCache[key] {
            return cached
        }

        let bytesPerComponent = MemoryLayout<Float16>.size
        let bytesPerRow = totalPx * 4 * bytesPerComponent
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: totalPx,
            height: totalPx,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: Self.linearDisplayP3,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: totalPx, height: totalPx))
        ctx.interpolationQuality = .high

        let plateRect = CGRect(x: outsetPx, y: outsetPx, width: platePx, height: platePx)
        let maxRadius = min(plateRect.width, plateRect.height) * 0.5
        let radiusPx = min(maxRadius, max(0, cornerRadiusPt * scale))
        let platePath = CGPath(
            roundedRect: plateRect,
            cornerWidth: radiusPx,
            cornerHeight: radiusPx,
            transform: nil
        )

        // 1. Outer shadow matching sunkContainerView.layer (shadowOpacity = 0.18, offset = (0, -2), radius = 8.0)
        let shadowOffsetY = -2.0 * scale
        let shadowBlur = 8.0 * scale
        let offscreenShiftY = CGFloat(totalPx * 2)
        var shiftTransform = CGAffineTransform(translationX: 0, y: offscreenShiftY)
        if let shiftedPath = platePath.copy(using: &shiftTransform) {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -offscreenShiftY + shadowOffsetY),
                blur: shadowBlur,
                color: NSColor.black.withAlphaComponent(0.18).cgColor
            )
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(shiftedPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Sunk baseplate fill & inner 0.5pt border matching sunkPlateView.layer
        ctx.saveGState()
        ctx.addPath(platePath)
        ctx.clip()

        let fillColor = isDark
            ? NSColor(white: 0.34, alpha: 0.40).cgColor
            : NSColor(white: 1.0, alpha: 0.42).cgColor
        ctx.setFillColor(fillColor)
        ctx.addPath(platePath)
        ctx.fillPath()

        let borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 1.0, alpha: 0.45).cgColor
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(1.0 * scale)
        ctx.addPath(platePath)
        ctx.strokePath()
        ctx.restoreGState()

        guard let img = ctx.makeImage() else { return nil }
        baseplateCache[key] = img
        return img
    }

    func sunkFolderTexture(
        device: MTLDevice,
        plate: FolderPlateModel,
        scale: CGFloat,
        appearanceName: String,
        isDark: Bool,
        isFloat16: Bool,
        fallbackImages: [String: CGImage]? = nil,
        allowCreateMissingIcons: Bool = true
    ) -> SunkFolderTextureEntry? {
        let plateSizePt = min(plate.rect.width, plate.rect.height)
        guard plateSizePt >= 1 else { return nil }

        let displayMembers = Array(plate.members.prefix(FolderPreviewLayout.capacity))
        let canonicalSizePt = Self.canonicalPlatePt
        let platePx = max(1, Int((canonicalSizePt * scale).rounded()))
        let outsetPx = max(4, Int((18.0 * scale).rounded()))
        let totalPx = platePx + outsetPx * 2
        let totalToPlateRatio = CGFloat(totalPx) / CGFloat(max(platePx, 1))
        let totalSizePt = plateSizePt * totalToPlateRatio
        let canonicalBoundsSize = CGSize(width: canonicalSizePt, height: canonicalSizePt)
        let cornerRadiusRatio = (plate.customCornerRadius ?? (plateSizePt * 0.225)) / max(plateSizePt, 1.0)
        let canonicalCornerRadiusPt = canonicalSizePt * cornerRadiusRatio
        let cornerRadiusMilli = Int((canonicalCornerRadiusPt * 1000).rounded())

        let previewKey = makePreviewKey(
            boundsSize: canonicalBoundsSize,
            iconSize: Self.canonicalIconPt,
            scale: scale,
            displayMembers: displayMembers,
            incomingDropAppID: plate.incomingDropAppID,
            appearanceName: appearanceName
        )
        let sunkKey = SunkTextureKey(
            previewKey: previewKey,
            cornerRadiusMilli: cornerRadiusMilli,
            isDark: isDark,
            isFloat16: isFloat16,
            deviceID: ObjectIdentifier(device)
        )
        if let cached = sunkTextureCache[sunkKey] {
            return SunkFolderTextureEntry(texture: cached.texture, totalSizePt: totalSizePt)
        }

        var previewImage: CGImage? = previewCache[previewKey]
        if previewImage == nil, plate.previewVisible, !displayMembers.isEmpty {
            var imagesByID: [String: CGImage] = [:]
            for app in displayMembers {
                if let incoming = plate.incomingDropAppID, app.id == incoming {
                    continue
                }
                if let img = AppIconImageProvider.shared.cachedCGImage(
                    for: app,
                    appearanceName: appearanceName,
                    allowFallback: false
                ) ?? fallbackImages?[app.id] ?? (
                    allowCreateMissingIcons
                        ? AppIconImageProvider.shared.cgImage(for: app, appearanceName: appearanceName, allowCreate: true)
                        : nil
                ) {
                    imagesByID[app.id] = img
                } else if !allowCreateMissingIcons {
                    return nil
                }
            }
            previewImage = previewCompositeImage(
                boundsSize: canonicalBoundsSize,
                iconSize: Self.canonicalIconPt,
                scale: scale,
                displayMembers: displayMembers,
                incomingDropAppID: plate.incomingDropAppID,
                appearanceName: appearanceName,
                imagesByID: imagesByID
            )
        }

        let bytesPerComponent = MemoryLayout<Float16>.size
        let bytesPerRow = totalPx * 4 * bytesPerComponent
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: totalPx,
            height: totalPx,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: Self.linearDisplayP3,
            bitmapInfo: bitmapInfo
        ), let data = ctx.data else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: totalPx, height: totalPx))
        ctx.interpolationQuality = .high

        if let baseplateImage = sunkBaseplateTemplateImage(
            totalPx: totalPx,
            platePx: platePx,
            outsetPx: outsetPx,
            scale: scale,
            scaleMilli: previewKey.scaleMilli,
            cornerRadiusPt: canonicalCornerRadiusPt,
            cornerRadiusMilli: cornerRadiusMilli,
            isDark: isDark
        ) {
            ctx.draw(baseplateImage, in: CGRect(x: 0, y: 0, width: totalPx, height: totalPx))
        }

        let plateRect = CGRect(x: outsetPx, y: outsetPx, width: platePx, height: platePx)
        // 3. Cached 3x3 mini-icon + drop shadow composite
        if let previewImage, plate.previewVisible {
            ctx.draw(previewImage, in: plateRect)
        }

        let texture: MTLTexture?
        if isFloat16 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: totalPx,
                height: totalPx,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: descriptor) else { return nil }
            tex.replace(
                region: MTLRegionMake2D(0, 0, totalPx, totalPx),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: bytesPerRow
            )
            texture = tex
        } else {
            let pixelCount = totalPx * totalPx
            var unorm = [UInt8](repeating: 0, count: pixelCount * 4)
            data.withMemoryRebound(to: Float16.self, capacity: pixelCount * 4) { src in
                var pixel = 0
                while pixel < pixelCount {
                    let base = pixel * 4
                    unorm[base]     = Self.encodeLinearToSRGB8(Float(src[base]))
                    unorm[base + 1] = Self.encodeLinearToSRGB8(Float(src[base + 1]))
                    unorm[base + 2] = Self.encodeLinearToSRGB8(Float(src[base + 2]))
                    let alpha = min(max(Float(src[base + 3]), 0), 1)
                    unorm[base + 3] = UInt8(alpha * 255.0 + 0.5)
                    pixel += 1
                }
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: totalPx,
                height: totalPx,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: descriptor) else { return nil }
            unorm.withUnsafeBytes { raw in
                tex.replace(
                    region: MTLRegionMake2D(0, 0, totalPx, totalPx),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: totalPx * 4
                )
            }
            texture = tex
        }

        guard let texture else { return nil }
        let entry = SunkFolderTextureEntry(texture: texture, totalSizePt: totalSizePt)
        if sunkTextureCache.count >= maxEntries {
            sunkTextureCache.removeAll(keepingCapacity: true)
        }
        sunkTextureCache[sunkKey] = entry
        return entry
    }

    private static func encodeLinearToSRGB8(_ linear: Float) -> UInt8 {
        let x = min(max(linear, 0), 1)
        let encoded: Float
        if x <= 0.0031308 {
            encoded = x * 12.92
        } else {
            encoded = 1.055 * pow(x, 1.0 / 2.4) - 0.055
        }
        return UInt8(encoded * 255.0 + 0.5)
    }
}

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

    private func parseCacheKey(_ key: String) -> (path: String, appearanceName: String, revision: UInt64)? {
        let parts = key.split(separator: "|")
        guard parts.count >= 3 else { return nil }
        let revStr = parts.last!
        let rev = UInt64(revStr) ?? 0
        let appName = String(parts[parts.count - 2])
        let path = parts[0..<(parts.count - 2)].joined(separator: "|")
        return (path, appName, rev)
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
            } else if let parsed = parseCacheKey(k), parsed.appearanceName == name {
                readyPaths.insert(parsed.path)
            }
        }
        for k in staleKeys {
            cachedKeys.remove(k)
        }

        let toRemove = cachedKeys.filter { k in
            guard let parsed = parseCacheKey(k) else { return false }
            guard parsed.appearanceName != name else { return false }
            return readyPaths.contains(parsed.path)
        }
        for k in toRemove {
            cache.removeObject(forKey: k as NSString)
            cachedKeys.remove(k)
        }
        inflightCallbacks.removeAll()
        lock.unlock()
    }

    private func cacheKey(for app: AppInfo, appearanceName: String) -> NSString {
        let rev = CustomIconStore.shared.iconRevision(for: app)
        return "\(app.url.path)|\(appearanceName)|\(rev)" as NSString
    }

    func hasCachedCGImage(for app: AppInfo, appearanceName: String? = nil) -> Bool {
        cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: false) != nil
    }

    func cachedCGImage(
        for app: AppInfo,
        appearanceName: String? = nil,
        allowFallback: Bool = true
    ) -> CGImage? {
        let name = appearanceName ?? currentAppearanceName
        let key = cacheKey(for: app, appearanceName: name)
        lock.lock()
        if let exact = cache.object(forKey: key) {
            lock.unlock()
            return exact
        }
        lock.unlock()

        if let custom = CustomIconStore.shared.cgImage(for: app) {
            lock.lock()
            let cost = custom.bytesPerRow * custom.height
            cache.setObject(custom, forKey: key, cost: cost)
            cachedKeys.insert(key as String)
            lock.unlock()
            return custom
        }

        guard allowFallback else { return nil }
        lock.lock()
        defer { lock.unlock() }
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
    func cgImage(for app: AppInfo, appearanceName: String? = nil, allowCreate: Bool = true) -> CGImage? {
        let name = appearanceName ?? currentAppearanceName
        let key = cacheKey(for: app, appearanceName: name)
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached
        }
        let appGen = appearanceGeneration
        let appAppearance = (appearanceName != nil ? NSAppearance(named: NSAppearance.Name(name)) : nil) ?? currentAppearance
        lock.unlock()

        if let custom = CustomIconStore.shared.cgImage(for: app) {
            lock.lock()
            let cost = custom.bytesPerRow * custom.height
            cache.setObject(custom, forKey: key, cost: cost)
            cachedKeys.insert(key as String)
            lock.unlock()
            return custom
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
        if let custom = CustomIconStore.shared.cgImage(for: app) {
            cg = custom
        } else {
            appearance.performAsCurrentDrawingAppearance {
                let image = NSWorkspace.shared.icon(forFile: app.url.path)
                // Request 256pt (512px on Retina) to ensure razor-sharp rendering in preview layers
                image.size = NSSize(width: 256, height: 256)
                var proposedRect = CGRect(origin: .zero, size: image.size)
                cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            }
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
    private let sunkPlateView = FlippedContainerView()
    private var currentMaterialStyle: FolderPlateMaterialStyle = .glass
    private let sunkContainerView = FlippedContainerView()
    private let contentView = FlippedContainerView()
    private let compositePreviewLayer = CALayer()
    private var previewLayers: [CALayer] = []
    private var crossfadePreviewLayers: [CALayer] = []
    private var currentDisplayMemberIDs: [String] = []
    private var loadedMemberImages: [String: CGImage] = [:]

    var usesUnifiedBackdropBlur: Bool = false {
        didSet {
            guard usesUnifiedBackdropBlur != oldValue else { return }
            lastTransitionProgress = -1
            lastMaterialProgress = -1
        }
    }

    private var lastBoundsSize: CGSize = .zero
    private var lastPreviewBoundsSize: CGSize = .zero
    private var lastCornerRadius: CGFloat = -1
    private var lastAlpha: Float = -1
    private var lastMemberIDs: [String] = []
    private var lastMemberRevisions: [UInt64] = []
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
        loadedMemberImages.removeAll(keepingCapacity: true)
        compositePreviewLayer.contents = nil
        compositePreviewLayer.isHidden = true
        lastBoundsSize = .zero
        lastPreviewBoundsSize = .zero
        lastCornerRadius = -1
        lastAlpha = -1
        lastMemberIDs = []
        lastMemberRevisions = []
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
            if let image = loadedMemberImages[id] {
                result[id] = image
            } else if i < previewLayers.count, let image = previewLayers[i].contents {
                result[id] = (image as! CGImage)
            }
        }
        return result
    }

    var hasReadyPreviews: Bool {
        guard currentPreviewVisible, !currentDisplayMemberIDs.isEmpty else { return false }
        for (i, id) in currentDisplayMemberIDs.enumerated() {
            if let incoming = currentIncomingDropAppID, id == incoming {
                continue
            }
            if loadedMemberImages[id] != nil {
                continue
            }
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
        } else {
            let visual = NSVisualEffectView(frame: bounds)
            visual.wantsLayer = true
            visual.autoresizingMask = [.width, .height]
            visual.blendingMode = .withinWindow
            visual.material = .hudWindow
            visual.state = .active
            visual.layer?.cornerCurve = .continuous
            visual.layer?.masksToBounds = true
            visual.isHidden = (materialStyle == .regular)
            addSubview(visual, positioned: .below, relativeTo: sunkContainerView)
            glassEffectView = visual
        }

        sunkPlateView.frame = bounds
        sunkPlateView.wantsLayer = true
        sunkPlateView.autoresizingMask = [.width, .height]
        sunkPlateView.layer?.cornerCurve = .continuous
        sunkPlateView.layer?.masksToBounds = true
        sunkPlateView.isHidden = (materialStyle == .glass && glassEffectView != nil)
        sunkContainerView.addSubview(sunkPlateView)
        updateFallbackAppearance()

        contentView.frame = bounds
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        contentView.autoresizingMask = [.width, .height]
        sunkContainerView.addSubview(contentView, positioned: .above, relativeTo: sunkPlateView)

        compositePreviewLayer.frame = bounds
        compositePreviewLayer.contentsGravity = .resizeAspect
        compositePreviewLayer.masksToBounds = false
        compositePreviewLayer.shadowOpacity = 0.0
        compositePreviewLayer.isHidden = true
        contentView.layer?.addSublayer(compositePreviewLayer)

        // Pre-create 9 reusable CALayers for fallback / crossfade without live per-icon CALayer drop shadows
        for _ in 0..<FolderPreviewLayout.capacity {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
            layer.shadowOpacity = 0.0
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 1.5
            layer.isHidden = true
            contentView.layer?.addSublayer(layer)
            previewLayers.append(layer)

            let crossLayer = CALayer()
            crossLayer.contentsGravity = .resizeAspect
            crossLayer.masksToBounds = false
            crossLayer.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
            crossLayer.shadowOpacity = 0.0
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
            sunkPlateView.alphaValue = 1.0
            sunkPlateView.isHidden = false
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
        sunkPlateView.frame = currentBounds
        contentView.frame = currentBounds
        compositePreviewLayer.frame = currentBounds
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
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                sunkPlateView.layer?.backgroundColor = NSColor(white: 0.34, alpha: 0.40).cgColor
                sunkPlateView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
            } else {
                sunkPlateView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.42).cgColor
                sunkPlateView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.45).cgColor
            }
            sunkPlateView.layer?.borderWidth = 0.5

            if let visual = glassEffectView as? NSVisualEffectView {
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
    }

    private func applyPreviewCompositeOrFallback(
        displayMembers: [AppInfo],
        boundsSize: CGSize,
        iconSize: CGFloat,
        scale: CGFloat,
        incomingDropAppID: String?,
        appearanceName: String
    ) {
        let key = FolderPreviewCompositeCache.shared.makePreviewKey(
            boundsSize: boundsSize,
            iconSize: iconSize,
            scale: scale,
            displayMembers: displayMembers,
            incomingDropAppID: incomingDropAppID,
            appearanceName: appearanceName
        )

        // 1. If we already have a cached composite for this exact key, use it directly.
        if let cached = FolderPreviewCompositeCache.shared.cachedPreviewComposite(forKey: key) {
            useComposite(cached, boundsSize: boundsSize, scale: scale)
            return
        }

        // 2. Only generate composite if ALL target images are ready for appearanceName
        var allTargetImagesReady = true
        var targetImagesByID: [String: CGImage] = [:]

        for app in displayMembers {
            if let incomingDropAppID, app.id == incomingDropAppID {
                continue
            }
            if let exact = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: false) {
                targetImagesByID[app.id] = exact
                loadedMemberImages[app.id] = exact
            } else {
                allTargetImagesReady = false
                break
            }
        }

        if allTargetImagesReady,
           let composite = FolderPreviewCompositeCache.shared.previewCompositeImage(
               boundsSize: boundsSize,
               iconSize: iconSize,
               scale: scale,
               displayMembers: displayMembers,
               incomingDropAppID: incomingDropAppID,
               appearanceName: appearanceName,
               imagesByID: targetImagesByID
           ) {
            useComposite(composite, boundsSize: boundsSize, scale: scale)
        } else {
            useIndividualLayers(displayMembers: displayMembers, incomingDropAppID: incomingDropAppID)
        }
    }

    private func useComposite(_ composite: CGImage, boundsSize: CGSize, scale: CGFloat) {
        compositePreviewLayer.frame = CGRect(origin: .zero, size: boundsSize)
        compositePreviewLayer.contentsScale = scale
        compositePreviewLayer.contents = composite
        compositePreviewLayer.opacity = 1.0
        compositePreviewLayer.isHidden = false
        for layer in previewLayers {
            layer.isHidden = true
        }
        for crossLayer in crossfadePreviewLayers {
            crossLayer.isHidden = true
            crossLayer.contents = nil
        }
    }

    private func useIndividualLayers(displayMembers: [AppInfo], incomingDropAppID: String?) {
        compositePreviewLayer.isHidden = true
        compositePreviewLayer.contents = nil
        for (index, layer) in previewLayers.enumerated() {
            if index < displayMembers.count {
                let app = displayMembers[index]
                if let incomingDropAppID, app.id == incomingDropAppID {
                    layer.isHidden = true
                    continue
                }
                if let img = loadedMemberImages[app.id] {
                    layer.contents = img
                    layer.opacity = 1.0
                    layer.isHidden = false
                } else {
                    layer.isHidden = true
                    layer.contents = nil
                }
            } else {
                layer.isHidden = true
                layer.contents = nil
            }
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
            sunkPlateView.frame = currentBounds
            contentView.frame = currentBounds
            compositePreviewLayer.frame = currentBounds
            lastBoundsSize = currentBounds.size
        }
        if alpha != lastAlpha {
            alphaValue = CGFloat(alpha)
            lastAlpha = alpha
        }

        if cornerRadius != lastCornerRadius || sizeChanged {
            if #available(macOS 26.0, *), let glass = glassEffectView as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            } else if let visual = glassEffectView as? NSVisualEffectView {
                visual.layer?.cornerRadius = cornerRadius
            }
            sunkPlateView.layer?.cornerRadius = cornerRadius
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
                loadedMemberImages.removeAll(keepingCapacity: true)
                compositePreviewLayer.isHidden = true
                compositePreviewLayer.contents = nil
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

        let isCompositeActive = !compositePreviewLayer.isHidden && compositePreviewLayer.contents != nil
        let boundsMatch = isCompositeActive || (
            abs(currentBounds.width - lastPreviewBoundsSize.width) < 0.05
                && abs(currentBounds.height - lastPreviewBoundsSize.height) < 0.05
                && abs(iconSize - lastIconSize) < 0.05
        )
        let currentRevisions = displayMembers.map { CustomIconStore.shared.iconRevision(for: $0) }
        let allTargetImagesReady = displayMembers.allSatisfy { app in
            if let incomingDropAppID, app.id == incomingDropAppID { return true }
            return AppIconImageProvider.shared.hasCachedCGImage(for: app, appearanceName: appearanceName)
        }
        let needsPromotionToComposite = !isCompositeActive && allTargetImagesReady
        let contentUnchanged = !needsPromotionToComposite
            && boundsMatch
            && memberIDs == lastMemberIDs
            && currentRevisions == lastMemberRevisions
            && previewVisible == lastPreviewVisible
            && abs(scale - lastScale) < 0.001
            && incomingDropAppID == lastIncomingDropAppID
            && appearanceName == lastAppearanceName

        if contentUnchanged {
            return
        }

        previewRequestGeneration &+= 1
        let requestGen = previewRequestGeneration

        let previousDisplayMemberIDs = currentDisplayMemberIDs
        let previousAppearanceName = lastAppearanceName
        let previousLoadedImages = loadedMemberImages
        let canRetainExistingImages = previousDisplayMemberIDs == memberIDs
            && previousAppearanceName == appearanceName
            && lastMemberRevisions == currentRevisions

        lastPreviewBoundsSize = currentBounds.size
        lastMemberIDs = memberIDs
        lastMemberRevisions = currentRevisions
        lastPreviewVisible = previewVisible
        lastIconSize = iconSize
        lastScale = scale
        lastIncomingDropAppID = incomingDropAppID
        lastAppearanceName = appearanceName
        currentDisplayMemberIDs = memberIDs
        loadedMemberImages.removeAll(keepingCapacity: true)

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

                let canRetainExistingImage = (canRetainExistingImages || (index < previousDisplayMemberIDs.count && previousDisplayMemberIDs[index] == app.id && previousAppearanceName == appearanceName)) && previousLoadedImages[app.id] != nil

                let isTargetImageCached = AppIconImageProvider.shared.hasCachedCGImage(for: app, appearanceName: appearanceName)

                if isTargetImageCached,
                   let exact = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: false) {
                    loadedMemberImages[app.id] = exact
                    layer.contents = exact
                    layer.opacity = 1.0
                    layer.isHidden = false
                } else {
                    // Target image is not yet cached for this appearance.
                    // Temporary display: fallback image / seed / retained image to avoid flashing blank
                    if let fallback = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: appearanceName, allowFallback: true) {
                        loadedMemberImages[app.id] = fallback
                        layer.contents = fallback
                        layer.opacity = 1.0
                        layer.isHidden = false
                    } else if let seed = seedImages?[app.id] {
                        loadedMemberImages[app.id] = seed
                        layer.contents = seed
                        layer.opacity = 1.0
                        layer.isHidden = false
                    } else if canRetainExistingImage, let retained = previousLoadedImages[app.id] {
                        loadedMemberImages[app.id] = retained
                        layer.contents = retained
                        layer.opacity = 1.0
                        layer.isHidden = false
                    } else {
                        layer.isHidden = true
                        layer.contents = nil
                        loadedMemberImages.removeValue(forKey: app.id)
                    }

                    // Continue loading target theme icon asynchronously
                    let targetApp = effectiveAppearance
                    AppIconImageProvider.shared.loadAsync(for: app, appearance: targetApp) { [weak self, weak layer] cgImage in
                        guard let self, let layer, let cgImage else { return }
                        guard self.previewRequestGeneration == requestGen else { return }
                        guard self.currentPreviewVisible else { return }
                        guard self.currentDisplayMemberIDs.indices.contains(index),
                              self.currentDisplayMemberIDs[index] == app.id else { return }
                        if let incoming = self.currentIncomingDropAppID, incoming == app.id { return }
                        self.loadedMemberImages[app.id] = cgImage
                        layer.contents = cgImage
                        layer.opacity = 1.0
                        layer.isHidden = false
                        let curScale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? self.lastScale
                        let curDisplay = Array(self.currentMembers.prefix(FolderPreviewLayout.capacity))
                        let curAppearanceName = self.effectiveAppearance.name.rawValue

                        let allReady = curDisplay.allSatisfy { member in
                            if let incoming = self.currentIncomingDropAppID, member.id == incoming { return true }
                            return AppIconImageProvider.shared.hasCachedCGImage(for: member, appearanceName: curAppearanceName)
                        }

                        if allReady {
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            self.applyPreviewCompositeOrFallback(
                                displayMembers: curDisplay,
                                boundsSize: self.bounds.size,
                                iconSize: self.lastIconSize,
                                scale: curScale > 0 ? curScale : 2.0,
                                incomingDropAppID: self.currentIncomingDropAppID,
                                appearanceName: curAppearanceName
                            )
                            CATransaction.commit()
                        }
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

        applyPreviewCompositeOrFallback(
            displayMembers: displayMembers,
            boundsSize: currentBounds.size,
            iconSize: iconSize,
            scale: scale,
            incomingDropAppID: incomingDropAppID,
            appearanceName: appearanceName
        )
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
        compositePreviewLayer.isHidden = true

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
        let requestGen = previewRequestGeneration
        for (index, layer) in previewLayers.enumerated() {
            if index < displayMembers.count {
                let app = displayMembers[index]
                if let newImg = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: toName, allowFallback: false) {
                    loadedMemberImages[app.id] = newImg
                    layer.contents = newImg
                } else {
                    if let fallback = AppIconImageProvider.shared.cachedCGImage(for: app, appearanceName: toName, allowFallback: true) {
                        loadedMemberImages[app.id] = fallback
                        layer.contents = fallback
                    }
                    AppIconImageProvider.shared.loadAsync(for: app, appearance: toAppearance) { [weak self, weak layer] cgImage in
                        guard let self, let layer, let cgImage else { return }
                        guard self.previewRequestGeneration == requestGen else { return }
                        guard self.currentPreviewVisible else { return }
                        guard self.currentDisplayMemberIDs.indices.contains(index),
                              self.currentDisplayMemberIDs[index] == app.id else { return }
                        if let incoming = self.currentIncomingDropAppID, incoming == app.id { return }
                        self.loadedMemberImages[app.id] = cgImage
                        layer.contents = cgImage
                        layer.opacity = 1.0
                        layer.isHidden = false

                        let curScale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? self.lastScale
                        let curDisplay = Array(self.currentMembers.prefix(FolderPreviewLayout.capacity))
                        let curAppearanceName = self.effectiveAppearance.name.rawValue
                        let allReady = curDisplay.allSatisfy { member in
                            if let incoming = self.currentIncomingDropAppID, member.id == incoming { return true }
                            return AppIconImageProvider.shared.hasCachedCGImage(for: member, appearanceName: curAppearanceName)
                        }
                        if allReady {
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            self.applyPreviewCompositeOrFallback(
                                displayMembers: curDisplay,
                                boundsSize: self.bounds.size,
                                iconSize: self.lastIconSize,
                                scale: curScale > 0 ? curScale : 2.0,
                                incomingDropAppID: self.currentIncomingDropAppID,
                                appearanceName: curAppearanceName
                            )
                            CATransaction.commit()
                        }
                    }
                }
                layer.opacity = 1.0
            }
            if index < crossfadePreviewLayers.count {
                let crossLayer = crossfadePreviewLayers[index]
                crossLayer.contents = nil
                crossLayer.opacity = 0.0
                crossLayer.isHidden = true
            }
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? (lastScale > 0 ? lastScale : 2.0)
        applyPreviewCompositeOrFallback(
            displayMembers: displayMembers,
            boundsSize: bounds.size,
            iconSize: lastIconSize,
            scale: scale,
            incomingDropAppID: currentIncomingDropAppID,
            appearanceName: toName
        )
        CATransaction.commit()
    }

    /// Updates material cross-fade (driven by materialProgress in [0, 1]) and Gaussian blur (driven by progress in [0, 1]).
    func updateTransitionProgress(progress: CGFloat, materialProgress: CGFloat) {
        let localProgress = min(max(progress, 0), 1)
        let localMaterial = min(max(materialProgress, 0), 1)
        if usesUnifiedBackdropBlur {
            if abs(localMaterial - lastMaterialProgress) < 0.0005 {
                lastTransitionProgress = localProgress
                return
            }
        } else {
            if abs(localProgress - lastTransitionProgress) < 0.001 && abs(localMaterial - lastMaterialProgress) < 0.001 {
                return
            }
        }
        lastTransitionProgress = localProgress
        lastMaterialProgress = localMaterial

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if usesUnifiedBackdropBlur {
            // Sunk baseplate, outer shadow, and blurred 3x3 mini-icons are already rendered
            // in FolderDepthBackdropView's unified Metal blur texture.
            applyBlurRadius(0)
            sunkPlateView.alphaValue = 0.0
            sunkPlateView.isHidden = true
            sunkContainerView.layer?.shadowOpacity = 0.0

            if localMaterial <= 0.0001 {
                glassEffectView?.alphaValue = 1.0
                glassEffectView?.isHidden = (currentMaterialStyle == .regular)
                contentView.alphaValue = 1.0
                contentView.isHidden = false
                sunkContainerView.isHidden = false
            } else if localMaterial >= 0.9999 {
                glassEffectView?.alphaValue = 0.0
                glassEffectView?.isHidden = true
                contentView.alphaValue = 0.0
                contentView.isHidden = true
                sunkContainerView.isHidden = true
            } else {
                let smoothT = localMaterial * localMaterial * (3.0 - 2.0 * localMaterial)
                let glassAlpha = 1.0 - smoothT
                glassEffectView?.alphaValue = glassAlpha
                glassEffectView?.isHidden = (currentMaterialStyle == .regular)
                contentView.alphaValue = glassAlpha
                contentView.isHidden = false
                sunkContainerView.isHidden = false
            }
            CATransaction.commit()
            return
        }

        contentView.alphaValue = 1.0
        contentView.isHidden = false
        sunkContainerView.isHidden = false

        // 1. Cross-fade baseplates strictly driven by materialProgress (0 = 100% glass, 1 = 100% static sunk plate).
        // Overlap duration is limited to <= 80ms by the animation clock with a single Hermite ease.
        if localMaterial <= 0.0001 {
            // Resting desktop state: 100% native glass, static sunk plate hidden
            if glassEffectView != nil {
                glassEffectView?.alphaValue = 1.0
                glassEffectView?.isHidden = false
                sunkPlateView.alphaValue = 0.0
                sunkPlateView.isHidden = true
                sunkContainerView.layer?.shadowOpacity = 0.0
            } else {
                sunkPlateView.alphaValue = 1.0
                sunkPlateView.isHidden = false
                sunkContainerView.layer?.shadowOpacity = 0.18
            }
        } else if localMaterial >= 0.9999 {
            // Sunk / open phase: 100% static sunk plate, native glass completely hidden
            glassEffectView?.alphaValue = 0.0
            glassEffectView?.isHidden = true
            sunkPlateView.alphaValue = 1.0
            sunkPlateView.isHidden = false
            sunkContainerView.layer?.shadowOpacity = 0.18
        } else {
            // Inside handoff: single smooth Hermite cross-fade between glass and static sunk plate.
            let smoothT = localMaterial * localMaterial * (3.0 - 2.0 * localMaterial)
            let plateAlpha = smoothT
            let glassAlpha = 1.0 - smoothT

            if glassEffectView != nil {
                glassEffectView?.alphaValue = glassAlpha
                glassEffectView?.isHidden = false
                sunkPlateView.alphaValue = plateAlpha
                sunkPlateView.isHidden = false
                sunkContainerView.layer?.shadowOpacity = Float(smoothT) * 0.18
            } else {
                sunkPlateView.alphaValue = 1.0
                sunkPlateView.isHidden = false
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
    var usesUnifiedBackdropBlur: Bool = false {
        didSet {
            guard usesUnifiedBackdropBlur != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for item in itemsByID.values {
                item.usesUnifiedBackdropBlur = usesUnifiedBackdropBlur
                if !item.isHidden {
                    item.updateTransitionProgress(
                        progress: currentTransitionProgress,
                        materialProgress: currentMaterialProgress
                    )
                }
            }
            CATransaction.commit()
        }
    }
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
            item.usesUnifiedBackdropBlur = usesUnifiedBackdropBlur
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
            item.usesUnifiedBackdropBlur = usesUnifiedBackdropBlur
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
        guard let item = itemsByID[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !isHidden {
            item.usesUnifiedBackdropBlur = usesUnifiedBackdropBlur
            item.updateTransitionProgress(
                progress: currentTransitionProgress,
                materialProgress: currentMaterialProgress
            )
        }
        item.isHidden = isHidden
        CATransaction.commit()
    }

    func setAllPlatesHidden(_ isHidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in itemsByID.values {
            if !isHidden {
                item.usesUnifiedBackdropBlur = usesUnifiedBackdropBlur
                item.updateTransitionProgress(
                    progress: currentTransitionProgress,
                    materialProgress: currentMaterialProgress
                )
            }
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
        for item in itemsByID.values where !item.isHidden {
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
        usesUnifiedBackdropBlur = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.layer?.sublayerTransform = CATransform3DIdentity
        for item in itemsByID.values {
            item.usesUnifiedBackdropBlur = false
            item.updateTransitionProgress(progress: 0, materialProgress: 0)
        }
        CATransaction.commit()
    }

    func removeAllPlates() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, item) in itemsByID {
            item.usesUnifiedBackdropBlur = false
            item.updateTransitionProgress(progress: 0, materialProgress: 0)
            item.resetCachedState()
            item.removeFromSuperview()
        }
        itemsByID.removeAll()
        currentRawSinkTransform = nil
        currentTransitionProgress = 0
        currentMaterialProgress = 0
        usesUnifiedBackdropBlur = false
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
        FolderPreviewCompositeCache.shared.clear()
        for item in itemsByID.values {
            item.resetCachedState()
        }
    }
}
