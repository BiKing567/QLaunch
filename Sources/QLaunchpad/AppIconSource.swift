import AppKit
import CoreGraphics
import QLaunchpadCore

final class AppIconSource: @unchecked Sendable {
    static let shared = AppIconSource()

    private init() {}

    func image(for app: AppInfo, size: CGFloat = 512, appearance: NSAppearance? = nil) -> NSImage {
        if let custom = CustomIconStore.shared.image(for: app) {
            return custom
        }
        let source = NSWorkspace.shared.icon(forFile: app.url.path)
        return (source.copy() as? NSImage) ?? source
    }

    func cgImage(
        for app: AppInfo,
        appearance: NSAppearance? = nil,
        allowFallback: Bool = true
    ) -> CGImage? {
        if let custom = CustomIconStore.shared.cgImage(for: app) {
            return custom
        }
        return AppIconImageProvider.shared.cgImage(for: app, allowCreate: allowFallback)
    }

    func hasCustomIcon(for app: AppInfo) -> Bool {
        CustomIconStore.shared.hasCustomIcon(for: app)
    }

    func iconRevision(for app: AppInfo) -> UInt64 {
        CustomIconStore.shared.iconRevision(for: app)
    }
}
