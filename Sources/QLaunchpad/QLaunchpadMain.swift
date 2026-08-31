import AppKit
import Darwin

@main
enum QLaunchpadMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if LaunchpadCLI.isInvocation(args) {
            Darwin.exit(LaunchpadCLI.run(args))
        }

        let application = NSApplication.shared
        // Packaged .app: never assign applicationIconImage. Dock must render
        // CFBundleIconName from Assets.car (correct pixel size + Liquid Glass).
        // NSWorkspace.icon(forFile:) is a 32pt lazy snapshot; writing it here
        // is why the Dock tile occasionally looks low-resolution.
        // Bare `swift run` has no asset catalog, so it still needs the PNG.
        if Bundle.main.bundleURL.pathExtension != "app",
           let image = QLaunchpadAppIcon.image {
            application.applicationIconImage = image
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
