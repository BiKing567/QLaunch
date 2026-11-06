import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    static let qlaunchpadSelfIconChanged = Notification.Name("com.qzrzz.qlaunchpad.selfIconChanged")
}

enum AppIconPreset: String, CaseIterable, Identifiable {
    case `default` = "default"
    case dark = "dark"
    case clearDark = "clearDark"
    case clearLight = "clearLight"
    case glass = "glass"
    case tinted = "tinted"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: L10n.tr("settings.appIcon.default")
        case .dark: L10n.tr("settings.appIcon.dark")
        case .clearDark: L10n.tr("settings.appIcon.clearDark")
        case .clearLight: L10n.tr("settings.appIcon.clearLight")
        case .glass: L10n.tr("settings.appIcon.glass")
        case .tinted: L10n.tr("settings.appIcon.tinted")
        case .custom: L10n.tr("settings.appIcon.custom")
        }
    }

    var resourceName: String? {
        switch self {
        case .default: "QLaunchpadAppIcon"
        case .dark: "AppIcon-Dark"
        case .clearDark: "AppIcon-ClearDark"
        case .clearLight: "AppIcon-ClearLight"
        case .glass: "AppIcon-Glass"
        case .tinted: "AppIcon-Tinted"
        case .custom: nil
        }
    }
}

@MainActor
final class QLaunchpadSelfIconManager: ObservableObject {
    static let shared = QLaunchpadSelfIconManager()

    @Published private(set) var currentPreset: AppIconPreset = .default
    @Published private(set) var hasCustomIcon: Bool = false

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    private var customIconCache: NSImage?
    private var presetImageCache: [AppIconPreset: NSImage] = [:]

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: QLaunchpadPreferences.selfAppIconPresetKey) ?? AppIconPreset.default.rawValue
        self.currentPreset = AppIconPreset(rawValue: savedRaw) ?? .default
        self.hasCustomIcon = FileManager.default.fileExists(atPath: customIconFileURL.path)
    }

    var customIconFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("com.qzrzz.qlaunchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("self_app_icon.png")
    }

    /// The active display icon for QLaunchpad (for About view, Settings, etc.)
    var currentAppIcon: NSImage {
        image(for: currentPreset) ?? defaultAppIcon
    }

    /// The default application icon
    var defaultAppIcon: NSImage {
        if let bundle = QLaunchpadResources.bundle,
           let url = bundle.url(forResource: "QLaunchpadAppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApplication.shared.applicationIconImage
    }

    /// Retrieves the image for a specific preset
    func image(for preset: AppIconPreset) -> NSImage? {
        if let cached = presetImageCache[preset] {
            return cached
        }

        switch preset {
        case .default:
            let img = defaultAppIcon
            presetImageCache[.default] = img
            return img

        case .custom:
            if let customIconCache {
                return customIconCache
            }
            if let img = NSImage(contentsOf: customIconFileURL) {
                customIconCache = img
                return img
            }
            return defaultAppIcon

        case .dark, .clearDark, .clearLight, .glass, .tinted:
            guard let name = preset.resourceName,
                  let bundle = QLaunchpadResources.bundle,
                  let url = bundle.url(forResource: name, withExtension: "png"),
                  let img = NSImage(contentsOf: url) else {
                return defaultAppIcon
            }
            presetImageCache[preset] = img
            return img
        }
    }

    /// Applies the chosen preset to the running process and persistent preferences
    func applyPreset(_ preset: AppIconPreset) {
        currentPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: QLaunchpadPreferences.selfAppIconPresetKey)
        applyToSystem(preset: preset)
        NotificationCenter.default.post(name: .qlaunchpadSelfIconChanged, object: nil)
    }

    /// Sets a user-provided image as the custom icon and applies it
    func setCustomIcon(from image: NSImage) -> Bool {
        guard let normalizedCG = normalizeToSquareCGImage(image) else {
            return false
        }
        let destURL = customIconFileURL
        let tempURL = destURL.deletingLastPathComponent().appendingPathComponent("temp_\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, normalizedCG, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        _ = try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        customIconCache = NSImage(contentsOf: destURL)
        hasCustomIcon = true
        applyPreset(.custom)
        return true
    }

    /// Sets a user-provided image file as the custom icon
    func setCustomIcon(from url: URL) -> Bool {
        guard let img = NSImage(contentsOf: url) else { return false }
        return setCustomIcon(from: img)
    }

    /// Clears the custom icon file and resets to default
    func resetToDefault() {
        try? FileManager.default.removeItem(at: customIconFileURL)
        customIconCache = nil
        hasCustomIcon = false
        applyPreset(.default)
    }

    /// Restores the saved icon on application launch
    func restoreSavedIconOnLaunch() {
        let savedRaw = UserDefaults.standard.string(forKey: QLaunchpadPreferences.selfAppIconPresetKey) ?? AppIconPreset.default.rawValue
        let preset = AppIconPreset(rawValue: savedRaw) ?? .default
        currentPreset = preset
        applyToSystem(preset: preset)
    }

    private func applyToSystem(preset: AppIconPreset) {
        let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app"
        let bundlePath = Bundle.main.bundlePath

        if preset == .default {
            if isPackagedApp {
                // Restore Assets.car CFBundleIconName rendering for Dock
                NSApp.applicationIconImage = nil
            } else {
                NSApp.applicationIconImage = defaultAppIcon
            }
            if isPackagedApp {
                NSWorkspace.shared.setIcon(nil, forFile: bundlePath, options: [])
            }
        } else {
            if let img = image(for: preset) {
                NSApp.applicationIconImage = img
                if isPackagedApp {
                    NSWorkspace.shared.setIcon(img, forFile: bundlePath, options: [])
                }
            }
        }
    }

    private func normalizeToSquareCGImage(_ image: NSImage, targetSize: CGFloat = 1024) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pxW = Int(targetSize)
        let pxH = Int(targetSize)

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: Self.displayP3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high

        let aspect = size.width / size.height
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        if aspect >= 1.0 {
            drawWidth = targetSize
            drawHeight = targetSize / aspect
        } else {
            drawHeight = targetSize
            drawWidth = targetSize * aspect
        }
        let drawX = (targetSize - drawWidth) * 0.5
        let drawY = (targetSize - drawHeight) * 0.5
        let drawRect = CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

        var proposedRect = CGRect(origin: .zero, size: size)
        if let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            ctx.draw(cg, in: drawRect)
            return ctx.makeImage()
        }
        return nil
    }
}
