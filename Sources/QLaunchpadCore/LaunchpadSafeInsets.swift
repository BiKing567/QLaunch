import CoreGraphics
import Foundation

/// Safe-area insets describing screen margins occupied by system chrome such as
/// the macOS Dock (bottom, left, or right) and the Menu Bar (top).
public struct LaunchpadSafeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(
        top: CGFloat = 0,
        left: CGFloat = 0,
        bottom: CGFloat = 0,
        right: CGFloat = 0
    ) {
        self.top = max(0, top)
        self.left = max(0, left)
        self.bottom = max(0, bottom)
        self.right = max(0, right)
    }

    public static let zero = LaunchpadSafeInsets()

    public var isZero: Bool {
        top == 0 && left == 0 && bottom == 0 && right == 0
    }
}
