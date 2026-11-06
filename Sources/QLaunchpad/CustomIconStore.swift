import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import QLaunchpadCore

extension Notification.Name {
    static let qlaunchpadCustomIconsChanged = Notification.Name("com.qzrzz.qlaunchpad.customIconsChanged")
}

struct CustomIconStagingResult: Sendable {
    let stagedFileURL: URL
    let targetFileName: String
    let image: NSImage
    let cgImage: CGImage
    let targetKey: String
}

final class CustomIconStore: @unchecked Sendable {
    static let shared = CustomIconStore()

    private let domain: String
    private let lock = NSLock()
    private var manifest: CustomIconManifest
    private var revisions: [String: UInt64] = [:]
    private let imageCache = NSCache<NSString, NSImage>()
    private let cgImageCache = NSCache<NSString, CGImage>()
    private let ioQueue = DispatchQueue(label: "com.qzrzz.qlaunchpad.custom-icons.io", qos: .userInitiated)

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    init(domain: String? = nil) {
        let activeDomain = domain
            ?? Bundle.main.bundleIdentifier
            ?? LaunchpadPreferenceStore.releaseDomain
        self.domain = activeDomain
        let loaded = CustomIconManifestStore.loadManifest(domain: activeDomain)
        self.manifest = loaded
        // Initialize initial revision 1 for existing custom icons
        for key in loaded.icons.keys {
            self.revisions[key] = 1
        }
        imageCache.countLimit = 250
        cgImageCache.countLimit = 250
    }

    // MARK: - Query & Resolution

    var customIconsDirectoryURL: URL {
        let dir = CustomIconManifestStore.imagesDirectoryURL(domain: domain)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func customizedKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(manifest.icons.keys)
    }

    func hasCustomIcon(for app: AppInfo) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return CustomIconManifestStore.resolveMatchedKey(
            appID: app.id,
            bundleIdentifier: app.bundleIdentifier,
            in: manifest
        ) != nil
    }

    func iconRevision(for app: AppInfo) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let key = CustomIconManifestStore.resolveMatchedKey(
            appID: app.id,
            bundleIdentifier: app.bundleIdentifier,
            in: manifest
        ) {
            return revisions[key] ?? 1
        }
        return 0
    }

    func image(for app: AppInfo) -> NSImage? {
        lock.lock()
        guard let key = CustomIconManifestStore.resolveMatchedKey(
            appID: app.id,
            bundleIdentifier: app.bundleIdentifier,
            in: manifest
        ), let record = manifest.icons[key] else {
            lock.unlock()
            return nil
        }
        let nsKey = key as NSString
        if let cached = imageCache.object(forKey: nsKey) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fileURL = CustomIconManifestStore.imagesDirectoryURL(domain: domain)
            .appendingPathComponent(record.fileName)
        guard let image = NSImage(contentsOf: fileURL) else { return nil }

        lock.lock()
        imageCache.setObject(image, forKey: nsKey)
        lock.unlock()
        return image
    }

    func cgImage(for app: AppInfo) -> CGImage? {
        lock.lock()
        guard let key = CustomIconManifestStore.resolveMatchedKey(
            appID: app.id,
            bundleIdentifier: app.bundleIdentifier,
            in: manifest
        ), let record = manifest.icons[key] else {
            lock.unlock()
            return nil
        }
        let nsKey = key as NSString
        if let cached = cgImageCache.object(forKey: nsKey) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fileURL = CustomIconManifestStore.imagesDirectoryURL(domain: domain)
            .appendingPathComponent(record.fileName)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        lock.lock()
        cgImageCache.setObject(cg, forKey: nsKey)
        lock.unlock()
        return cg
    }

    // MARK: - Staging & Preparation (Phase 1 of Staging)

    func stageCustomIcon(
        sourceImage: NSImage,
        for app: AppInfo,
        preferAppID: Bool = false,
        completion: @escaping @MainActor @Sendable (Result<CustomIconStagingResult, Error>) -> Void
    ) {
        let targetKey = preferAppID ? app.id : app.bundleIdentifier
        let imagesDir = CustomIconManifestStore.imagesDirectoryURL(domain: domain)

        ioQueue.async {
            do {
                guard let cg = Self.extractBestCGImage(from: sourceImage) else {
                    throw NSError(
                        domain: "CustomIconStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode source image"]
                    )
                }

                guard let normalizedPNG = Self.encodeNormalizedDisplayP3PNG(from: cg, maxDimension: 1024) else {
                    throw NSError(
                        domain: "CustomIconStore",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize normalized PNG"]
                    )
                }

                // Compute deterministic content hash for file naming
                let hash = SHA256.hash(data: normalizedPNG).compactMap { String(format: "%02x", $0) }.joined()
                let targetFileName = "\(hash).png"

                // Write to staging directory first
                let stagingDir = imagesDir.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                let stagedURL = stagingDir.appendingPathComponent("stage_\(UUID().uuidString).png")
                try normalizedPNG.write(to: stagedURL, options: .atomic)

                // Decode staged image for immediate preview/prewarm
                guard let stagedSource = CGImageSourceCreateWithURL(stagedURL as CFURL, nil),
                      let stagedCG = CGImageSourceCreateImageAtIndex(stagedSource, 0, nil) else {
                    throw NSError(
                        domain: "CustomIconStore",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to reload staged image"]
                    )
                }
                let stagedNSImage = NSImage(cgImage: stagedCG, size: NSSize(width: stagedCG.width, height: stagedCG.height))

                let result = CustomIconStagingResult(
                    stagedFileURL: stagedURL,
                    targetFileName: targetFileName,
                    image: stagedNSImage,
                    cgImage: stagedCG,
                    targetKey: targetKey
                )
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Commit & Reversion (Phase 2 of Staging)

    @discardableResult
    func commitCustomIcon(
        staged: CustomIconStagingResult,
        for app: AppInfo
    ) -> Bool {
        let imagesDir = CustomIconManifestStore.imagesDirectoryURL(domain: domain)
        let destinationURL = imagesDir.appendingPathComponent(staged.targetFileName)

        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: staged.stagedFileURL, to: destinationURL)
        } catch {
            return false
        }

        lock.lock()
        manifest.icons[staged.targetKey] = CustomIconRecord(
            fileName: staged.targetFileName,
            updatedAt: Date().timeIntervalSince1970
        )
        let newRev = (revisions[staged.targetKey] ?? 0) &+ 1
        revisions[staged.targetKey] = newRev
        let nsKey = staged.targetKey as NSString
        imageCache.setObject(staged.image, forKey: nsKey)
        cgImageCache.setObject(staged.cgImage, forKey: nsKey)
        let currentManifest = manifest
        lock.unlock()

        CustomIconManifestStore.saveManifest(currentManifest, domain: domain)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .qlaunchpadCustomIconsChanged,
                object: nil,
                userInfo: ["appID": app.id, "bundleIdentifier": app.bundleIdentifier, "key": staged.targetKey]
            )
        }
        cleanupOrphanedFilesAsync()
        return true
    }

    @discardableResult
    func resetCustomIcon(for app: AppInfo) -> Bool {
        lock.lock()
        guard let key = CustomIconManifestStore.resolveMatchedKey(
            appID: app.id,
            bundleIdentifier: app.bundleIdentifier,
            in: manifest
        ) else {
            lock.unlock()
            return false
        }
        manifest.icons.removeValue(forKey: key)
        let newRev = (revisions[key] ?? 0) &+ 1
        revisions[key] = newRev
        let nsKey = key as NSString
        imageCache.removeObject(forKey: nsKey)
        cgImageCache.removeObject(forKey: nsKey)
        let currentManifest = manifest
        lock.unlock()

        CustomIconManifestStore.saveManifest(currentManifest, domain: domain)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .qlaunchpadCustomIconsChanged,
                object: nil,
                userInfo: ["appID": app.id, "bundleIdentifier": app.bundleIdentifier, "key": key]
            )
        }
        cleanupOrphanedFilesAsync()
        return true
    }

    @discardableResult
    func resetAllCustomIcons() -> Bool {
        lock.lock()
        guard !manifest.icons.isEmpty else {
            lock.unlock()
            return false
        }
        let allKeys = Array(manifest.icons.keys)
        manifest.icons.removeAll()
        for k in allKeys {
            revisions[k] = (revisions[k] ?? 0) &+ 1
            let nsKey = k as NSString
            imageCache.removeObject(forKey: nsKey)
            cgImageCache.removeObject(forKey: nsKey)
        }
        let currentManifest = manifest
        lock.unlock()

        CustomIconManifestStore.saveManifest(currentManifest, domain: domain)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .qlaunchpadCustomIconsChanged,
                object: nil,
                userInfo: nil
            )
        }
        cleanupOrphanedFilesAsync()
        return true
    }

    // MARK: - Image Processing & Normalization

    private static func extractBestCGImage(from image: NSImage) -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let tiffData = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Normalizes any input image to Display P3 with non-premultiplied PNG alpha (W3C PNG compliant).
    private static func encodeNormalizedDisplayP3PNG(from cgImage: CGImage, maxDimension: CGFloat) -> Data? {
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        guard origW > 0, origH > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(origW, origH))
        let targetW = max(1, Int((origW * scale).rounded()))
        let targetH = max(1, Int((origH * scale).rounded()))

        let bytesPerRow = targetW * 4
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: displayP3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let premultipliedImage = ctx.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, premultipliedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private func cleanupOrphanedFilesAsync() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let imagesDir = CustomIconManifestStore.imagesDirectoryURL(domain: self.domain)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) else { return }

            self.lock.lock()
            let referencedFiles = Set(self.manifest.icons.values.map(\.fileName))
            self.lock.unlock()

            for file in files {
                guard file.hasSuffix(".png"), !referencedFiles.contains(file) else { continue }
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
            }
        }
    }
}
