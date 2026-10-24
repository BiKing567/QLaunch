import AppKit
import QLaunchpadCore
import QuartzCore

/// Transition state passed from Metal frame ticks to synchronize the native folder title view.
struct FolderTitleTransitionState: Equatable, Sendable {
    var folderID: String
    var folderName: String
    var center: CGPoint
    var scale: CGFloat
    var alpha: CGFloat
    var targetRect: CGRect
    var isFullyOpen: Bool
}

/// Custom text field cell providing exact optical baseline alignment to match
/// TextAtlas's 14pt label scaled by 1.57 (offset difference: 0.39pt).
private final class FolderTitleTextFieldCell: NSTextFieldCell {
    private static let baselineYOffset: CGFloat = 0.39

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var newRect = super.drawingRect(forBounds: rect)
        let font = self.font ?? NSFont.systemFont(ofSize: 22, weight: .medium)
        let textHeight = font.ascender - font.descender
        let y = rect.origin.y + (rect.height - textHeight) * 0.5 + Self.baselineYOffset
        newRect.origin.y = y
        newRect.size.height = textHeight
        return newRect
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        return drawingRect(forBounds: rect)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// Native AppKit folder title view that smoothly transitions into the folder card header,
/// crossfading with the icon texture title in mid-flight (40%~60% progress) and maintaining
/// the exact same motion trajectory, scale, and text baseline without post-transition jumps.
@MainActor
final class FolderTitleView: NSView, NSTextFieldDelegate {
    private let titleBox = FlippedContainerView()
    private let focusBackgroundView = NSView()
    private let textField = NSTextField()
    private weak var store: AppStore?

    private(set) var currentFolderID: String?
    private var isFullyOpen = false
    private var isEditing = false

    override var isFlipped: Bool { true }

    init(store: AppStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        titleBox.wantsLayer = true
        titleBox.layer?.masksToBounds = false
        titleBox.isHidden = true
        addSubview(titleBox)

        focusBackgroundView.wantsLayer = true
        focusBackgroundView.layer?.cornerRadius = 10
        focusBackgroundView.layer?.cornerCurve = .continuous
        focusBackgroundView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        focusBackgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        focusBackgroundView.layer?.borderWidth = 0.5
        focusBackgroundView.isHidden = true
        titleBox.addSubview(focusBackgroundView)

        let cell = FolderTitleTextFieldCell(textCell: "")
        cell.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        cell.textColor = NSColor.white.withAlphaComponent(0.94)
        cell.alignment = .center
        cell.isBordered = false
        cell.drawsBackground = false
        cell.lineBreakMode = .byTruncatingMiddle
        cell.placeholderString = L10n.tr("launchpad.folder")

        textField.cell = cell
        textField.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        textField.textColor = NSColor.white.withAlphaComponent(0.94)
        textField.alignment = .center
        textField.isBordered = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.focusRingType = .none
        textField.delegate = self
        titleBox.addSubview(textField)

        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isFullyOpen, !isHidden, !titleBox.isHidden, titleBox.alphaValue > 0.05 else { return nil }
        let local = titleBox.convert(point, from: superview)
        if titleBox.bounds.contains(local) {
            return textField
        }
        return nil
    }

    private func centeredTransform(for transform: CATransform3D, in bounds: CGRect) -> CATransform3D {
        guard bounds.width > 0, bounds.height > 0 else { return transform }
        let midX = bounds.midX
        let midY = bounds.midY
        let toOrigin = CATransform3DMakeTranslation(-midX, -midY, 0)
        let fromOrigin = CATransform3DMakeTranslation(midX, midY, 0)
        return CATransform3DConcat(CATransform3DConcat(toOrigin, transform), fromOrigin)
    }

    func update(state: FolderTitleTransitionState?) {
        guard let state else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if isEditing {
                commitDraftName()
            }
            isHidden = true
            titleBox.isHidden = true
            titleBox.alphaValue = 0
            currentFolderID = nil
            isFullyOpen = false
            textField.isEditable = false
            textField.isSelectable = false
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let targetW = state.targetRect.width
        let targetH = state.targetRect.height
        titleBox.frame = CGRect(
            x: state.center.x - targetW * 0.5,
            y: state.center.y - targetH * 0.5,
            width: targetW,
            height: targetH
        )
        focusBackgroundView.frame = titleBox.bounds.insetBy(dx: 4, dy: 2)
        textField.frame = titleBox.bounds

        let scale = state.scale
        let scaleTransform = CATransform3DMakeScale(scale, scale, 1.0)
        titleBox.layer?.sublayerTransform = centeredTransform(for: scaleTransform, in: titleBox.bounds)
        titleBox.alphaValue = state.alpha

        if currentFolderID != state.folderID {
            currentFolderID = state.folderID
            if !isEditing {
                textField.stringValue = state.folderName
            }
        } else if !isEditing && textField.stringValue != state.folderName {
            textField.stringValue = state.folderName
        }

        if isFullyOpen != state.isFullyOpen {
            isFullyOpen = state.isFullyOpen
            textField.isEditable = state.isFullyOpen
            textField.isSelectable = state.isFullyOpen
            if !state.isFullyOpen && isEditing {
                commitDraftName()
            }
        }

        let isVisible = state.alpha > 0.005
        titleBox.isHidden = !isVisible
        isHidden = !isVisible
        CATransaction.commit()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        focusBackgroundView.isHidden = false
        if let textView = textField.currentEditor() as? NSTextView {
            textView.insertionPointColor = .white
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitDraftName()
        isEditing = false
        focusBackgroundView.isHidden = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitDraftName()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let folderID = currentFolderID, let folder = store?.folder(withID: folderID) {
                textField.stringValue = folder.name
            }
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func commitDraftName() {
        guard let folderID = currentFolderID else { return }
        let newName = textField.stringValue
        store?.renameFolder(folderID, to: newName)
        if let current = store?.folder(withID: folderID)?.name {
            textField.stringValue = current
        }
        isEditing = false
        focusBackgroundView.isHidden = true
    }
}
