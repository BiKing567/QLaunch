import AppKit
import Combine
import QLaunchpadCore
import SwiftUI

extension Notification.Name {
    static let qlaunchpadStoreChanged = Notification.Name("QLaunchpadStoreChanged")
    static let qlaunchpadLayoutDidChange = Notification.Name("com.qzrzz.qlaunchpad.layoutDidChange")
    static let qlaunchpadDismiss = Notification.Name("QLaunchpadDismiss")
    static let qlaunchpadPresentationChanged = Notification.Name("QLaunchpadPresentationChanged")
    static let qlaunchpadFocusSearch = Notification.Name("QLaunchpadFocusSearch")
    static let qlaunchpadGridLayoutChanged = Notification.Name("QLaunchpadGridLayoutChanged")
    static let qlaunchpadCacheClearRequested = Notification.Name("QLaunchpadCacheClearRequested")
    static let qlaunchpadRenderQualityChanged = Notification.Name("QLaunchpadRenderQualityChanged")
    static let qlaunchpadBackgroundChanged = Notification.Name("QLaunchpadBackgroundChanged")
    /// Posted when a background icon bake finishes (may batch multiple).
    static let qlaunchpadIconTexturesUpdated = Notification.Name("QLaunchpadIconTexturesUpdated")
    static let qlaunchpadShowSystemDockChanged = Notification.Name("QLaunchpadShowSystemDockChanged")
}

private final class PassthroughFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Overlay hosting view that only intercepts hits in the search / chrome regions.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var pageCount = 0
    var currentPage = 0
    var isSearching = false
    var safeInsets: LaunchpadSafeInsets = .zero
    var folderCardMetrics: FolderCardMetrics?
    var onSelectPageAt: ((NSPoint) -> Void)?
    private var isScrubbingPages = false

    private var pageIndicatorEnabled: Bool {
        LaunchpadPageIndicatorHitArea.isEnabled(pageCount: pageCount, isSearching: isSearching)
    }

    private var isFolderOpen: Bool {
        folderCardMetrics != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isFolderOpen {
            if searchPadRect.contains(local) {
                return super.hitTest(point) ?? self
            }
        }
        if pageIndicatorEnabled, pageIndicatorRect.contains(local) {
            return self
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isFolderOpen {
            if searchPadRect.contains(point) {
                isScrubbingPages = false
                super.mouseDown(with: event)
                return
            }
        }
        if pageIndicatorEnabled, pageIndicatorRect.contains(point) {
            isScrubbingPages = true
            onSelectPageAt?(point)
            return
        }
        isScrubbingPages = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbingPages else {
            super.mouseDragged(with: event)
            return
        }
        onSelectPageAt?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbingPages else {
            super.mouseUp(with: event)
            return
        }
        onSelectPageAt?(convert(event.locationInWindow, from: nil))
        isScrubbingPages = false
    }

    private var searchPadRect: NSRect {
        LaunchpadFieldHitArea.rect(in: bounds, safeInsets: safeInsets, flipped: isFlipped)
    }

    private var pageIndicatorRect: NSRect {
        LaunchpadPageIndicatorHitArea.rect(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: safeInsets,
            cardMetrics: folderCardMetrics,
            flipped: isFlipped
        )
    }
}

/// Hit pad around the 320×38 glass field. Clicks here must not dismiss.
enum LaunchpadFieldHitArea {
    static let fieldSize = NSSize(width: 320, height: 38)
    static let topInset: CGFloat = 36
    static let horizontalSlop: CGFloat = 48
    static let verticalSlop: CGFloat = 32

    static var padSize: NSSize {
        NSSize(
            width: fieldSize.width + horizontalSlop * 2,
            height: fieldSize.height + verticalSlop * 2
        )
    }

    static func rect(
        in bounds: NSRect,
        safeInsets: LaunchpadSafeInsets = .zero,
        flipped: Bool = false
    ) -> NSRect {
        let pad = padSize
        let usableWidth = max(bounds.width - safeInsets.left - safeInsets.right, 1)
        let x = safeInsets.left + (usableWidth - pad.width) / 2
        let fromTop = topInset + safeInsets.top + fieldSize.height / 2 - pad.height / 2
        let y = flipped ? fromTop : bounds.height - fromTop - pad.height
        return NSRect(
            x: x,
            y: y,
            width: pad.width,
            height: pad.height
        )
    }

    static func rect(
        in bounds: NSRect,
        safeTopInset: CGFloat,
        flipped: Bool = false
    ) -> NSRect {
        rect(in: bounds, safeInsets: LaunchpadSafeInsets(top: safeTopInset), flipped: flipped)
    }
}

/// Hit testing for the page capsule. Layout numbers match `PageIndicator`.
enum LaunchpadPageIndicatorHitArea {
    static let dotWidth: CGFloat = 5
    static let activeDotWidth: CGFloat = 15
    static let dotHeight: CGFloat = 5
    static let spacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 11
    static let verticalPadding: CGFloat = 7
    static let bottomInset: CGFloat = 36
    static let hitSlopX: CGFloat = 28
    static let hitSlopY: CGFloat = 24

    static func isEnabled(pageCount: Int, isSearching: Bool) -> Bool {
        pageCount > 1 && !isSearching
    }

    static func visualSize(pageCount: Int, currentPage: Int) -> NSSize {
        guard pageCount > 0 else { return .zero }
        var content: CGFloat = 0
        for index in 0..<pageCount {
            content += index == currentPage ? activeDotWidth : dotWidth
            if index + 1 < pageCount { content += spacing }
        }
        return NSSize(
            width: content + horizontalPadding * 2,
            height: dotHeight + verticalPadding * 2
        )
    }

    static func visualRect(
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeInsets: LaunchpadSafeInsets = .zero,
        cardMetrics: FolderCardMetrics? = nil,
        flipped: Bool = false
    ) -> NSRect {
        if let cardMetrics {
            return cardMetrics.pageIndicatorVisualRect(pageCount: pageCount, currentPage: currentPage, flipped: flipped)
        }
        let size = visualSize(pageCount: pageCount, currentPage: currentPage)
        let usableWidth = max(bounds.width - safeInsets.left - safeInsets.right, 1)
        let x = safeInsets.left + (usableWidth - size.width) / 2
        let totalBottomInset = bottomInset + safeInsets.bottom
        let y = flipped
            ? bounds.height - totalBottomInset - size.height
            : totalBottomInset
        return NSRect(
            x: x,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    static func visualRect(
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeBottomInset: CGFloat,
        flipped: Bool = false
    ) -> NSRect {
        visualRect(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: LaunchpadSafeInsets(bottom: safeBottomInset),
            cardMetrics: nil,
            flipped: flipped
        )
    }

    static func rect(
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeInsets: LaunchpadSafeInsets = .zero,
        cardMetrics: FolderCardMetrics? = nil,
        flipped: Bool = false
    ) -> NSRect {
        if let cardMetrics {
            return cardMetrics.pageIndicatorHitRect(pageCount: pageCount, currentPage: currentPage, flipped: flipped)
        }
        return visualRect(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: safeInsets,
            cardMetrics: nil,
            flipped: flipped
        ).insetBy(dx: -hitSlopX, dy: -hitSlopY)
    }

    static func rect(
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeBottomInset: CGFloat,
        flipped: Bool = false
    ) -> NSRect {
        rect(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: LaunchpadSafeInsets(bottom: safeBottomInset),
            cardMetrics: nil,
            flipped: flipped
        )
    }

    static func pageIndex(
        at point: NSPoint,
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeInsets: LaunchpadSafeInsets = .zero,
        cardMetrics: FolderCardMetrics? = nil,
        requireHitPad: Bool = true,
        flipped: Bool = false
    ) -> Int? {
        if let cardMetrics {
            return cardMetrics.pageIndicatorPageIndex(
                at: point,
                pageCount: pageCount,
                currentPage: currentPage,
                requireHitPad: requireHitPad,
                flipped: flipped
            )
        }
        guard pageCount > 1 else { return nil }
        if requireHitPad {
            let pad = rect(
                in: bounds,
                pageCount: pageCount,
                currentPage: currentPage,
                safeInsets: safeInsets,
                cardMetrics: nil,
                flipped: flipped
            )
            guard pad.contains(point) else { return nil }
        }
        let centers = dotCenters(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: safeInsets,
            flipped: flipped
        )
        guard !centers.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - point.x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    static func pageIndex(
        at point: NSPoint,
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeBottomInset: CGFloat,
        requireHitPad: Bool = true,
        flipped: Bool = false
    ) -> Int? {
        pageIndex(
            at: point,
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: LaunchpadSafeInsets(bottom: safeBottomInset),
            requireHitPad: requireHitPad,
            flipped: flipped
        )
    }

    private static func dotCenters(
        in bounds: NSRect,
        pageCount: Int,
        currentPage: Int,
        safeInsets: LaunchpadSafeInsets = .zero,
        flipped: Bool = false
    ) -> [CGFloat] {
        let visual = visualRect(
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            safeInsets: safeInsets,
            flipped: flipped
        )
        var x = visual.minX + horizontalPadding
        var centers: [CGFloat] = []
        centers.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            let width = index == currentPage ? activeDotWidth : dotWidth
            centers.append(x + width / 2)
            x += width + spacing
        }
        return centers
    }
}

@MainActor
final class LaunchpadContainerView: NSView {
    private let store: AppStore
    private let backgroundView: DesktopBackgroundView
    private let backdropView: FolderDepthBackdropView
    private let fullScreenDimView = PassthroughFlippedView()
    private let backgroundFolderHostView: FolderGlassHostView
    private let foregroundFolderHostView: FolderGlassHostView
    private let metalView: LaunchpadMetalView
    private let overlayView: PassthroughHostingView<LaunchpadOverlayView>
    private let folderTitleView: FolderTitleView
    private var activeTransitionFolderID: String?
    private var cancellables = Set<AnyCancellable>()

    var metal: LaunchpadMetalView { metalView }
    var background: DesktopBackgroundView { backgroundView }
    var onInteractiveDismissProgress: ((CGFloat) -> Void)?
    var onInteractiveDismissEnd: ((Bool) -> Void)?

    init(store: AppStore) {
        self.store = store
        backgroundView = DesktopBackgroundView(screen: NSScreen.main)
        backdropView = FolderDepthBackdropView()
        fullScreenDimView.wantsLayer = true
        fullScreenDimView.layer?.backgroundColor = NSColor.black.cgColor
        fullScreenDimView.alphaValue = 0.0
        fullScreenDimView.isHidden = true
        backgroundFolderHostView = FolderGlassHostView()
        foregroundFolderHostView = FolderGlassHostView()
        metalView = LaunchpadMetalView(store: store)
        overlayView = PassthroughHostingView(rootView: LaunchpadOverlayView(store: store))
        folderTitleView = FolderTitleView(store: store)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(backgroundView)
        addSubview(backdropView)
        addSubview(backgroundFolderHostView)
        addSubview(fullScreenDimView)
        addSubview(foregroundFolderHostView)
        addSubview(metalView)
        addSubview(overlayView)
        addSubview(folderTitleView)
        metalView.onUpdateFolderPlates = { [weak self] plates, backdropAlpha in
            guard let self else { return }
            let fgPlates = plates.filter { $0.id.hasPrefix("opened-folder-") }
            let bgPlates = plates.filter { !$0.id.hasPrefix("opened-folder-") }
            let shouldRemoveUnused = (self.store.openedFolderID == nil) && !self.metalView.isFolderTransitionActive
            if !bgPlates.isEmpty || shouldRemoveUnused {
                self.backgroundFolderHostView.update(plates: bgPlates, removeUnused: shouldRemoveUnused)
            }
            self.foregroundFolderHostView.update(plates: fgPlates)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if backdropAlpha > 0.005 {
                self.fullScreenDimView.frame = self.bounds
                self.fullScreenDimView.alphaValue = CGFloat(backdropAlpha)
                self.fullScreenDimView.isHidden = false
            } else {
                self.fullScreenDimView.alphaValue = 0
                self.fullScreenDimView.isHidden = true
            }
            CATransaction.commit()
        }
        metalView.onUpdateFolderTitleTransition = { [weak self] state in
            self?.folderTitleView.update(state: state)
        }
        metalView.onFolderTransitionBakeBackdrop = { [weak self] folderID, generation, rootItems, pageOffset, canvasScale, canvasPan, canvasAdaptive in
            guard let self else { return }
            self.activeTransitionFolderID = folderID
            self.backgroundFolderHostView.setPlateHidden(true, for: folderID)
            guard let device = self.metalView.device else { return }
            let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            self.backdropView.bake(
                device: device,
                commandQueue: self.metalView.commandQueue,
                boundsSize: self.bounds.size,
                scale: scale
            ) { commandBuffer, targetTexture in
                self.metalView.renderBackdropRootGrid(
                    to: targetTexture,
                    commandBuffer: commandBuffer,
                    excluding: folderID,
                    items: rootItems,
                    pageOffset: pageOffset,
                    canvasScale: canvasScale,
                    canvasPan: canvasPan,
                    canvasAdaptive: canvasAdaptive
                )
            }
        }
        metalView.onFolderTransitionProgress = { [weak self] progress in
            guard let self else { return }
            self.backdropView.updateProgress(progress)
            let sink = FolderDepthBackdropView.sinkTransform(progress: progress)
            self.backgroundFolderHostView.applySinkTransform(sink.transform, progress: progress)
        }
        metalView.isDepthBackdropActive = { [weak self] in
            guard let self else { return false }
            return self.backdropView.isReady && !self.backdropView.isHidden
        }
        metalView.onFolderTransitionEnd = { [weak self] generation in
            guard let self else { return }
            guard generation == self.metalView.folderTransitionGeneration else { return }
            guard !self.metalView.isFolderTransitionActive else { return }
            if self.store.openedFolderID == nil {
                self.backdropView.dismiss()
                self.backgroundFolderHostView.resetSinkTransform()
                self.backgroundFolderHostView.setAllPlatesHidden(false)
                self.foregroundFolderHostView.removeAllPlates()
                self.activeTransitionFolderID = nil
            }
        }
        metalView.onInteractiveDismissProgress = { [weak self] progress in
            self?.onInteractiveDismissProgress?(progress)
        }
        metalView.onInteractiveDismissEnd = { [weak self] completed in
            self?.onInteractiveDismissEnd?(completed)
        }
        overlayView.onSelectPageAt = { [weak self] point in
            guard let self else { return }
            _ = self.store.selectPage(
                at: point,
                in: self.overlayView.bounds,
                scrubbing: true,
                flipped: self.overlayView.isFlipped
            )
        }
        syncPageIndicatorHitState()

        // Overlay chrome fades with presentation progress.
        overlayView.alphaValue = 0

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.metalView.needsDisplay = true
                NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: self)
                self.syncOverlayAlpha()
                self.syncPageIndicatorHitState()
            }
            .store(in: &cancellables)

        // Resign any field editor so SwiftUI can fade search ↔ folder title.
        // Remounting the hosting view would cancel that transition.
        store.$openedFolderID
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.window?.makeFirstResponder(self)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentationNote(_:)),
            name: .qlaunchpadPresentationChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cacheClearRequested),
            name: .qlaunchpadCacheClearRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gridLayoutChangedNote),
            name: .qlaunchpadGridLayoutChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func presentationNote(_ note: Notification) {
        guard let showing = note.userInfo?["showing"] as? Bool else { return }
        let style = (note.userInfo?["animationStyle"] as? String)
            .flatMap(LaunchpadAnimationStyle.init(rawValue:))
            ?? LaunchpadAnimationStyle.current
        setPresentationScale(1)
        guard style != .none else {
            overlayView.alphaValue = showing ? 1 : 0
            if !showing {
                backgroundView.alphaValue = 0
                backgroundFolderHostView.removeAllPlates()
                foregroundFolderHostView.removeAllPlates()
                backgroundFolderHostView.resetSinkTransform()
                activeTransitionFolderID = nil
                backdropView.dismiss()
                fullScreenDimView.alphaValue = 0
                fullScreenDimView.isHidden = true
            }
            return
        }
        // Fade dismissal is performed on the containing NSPanel. Keeping these
        // child layers unchanged avoids multiplying two opacity animations.
        if !showing, style == .fade { return }
        let transitionDuration = (note.userInfo?["effectiveDuration"] as? CFTimeInterval)
            ?? (showing ? style.duration : style.dismissalDuration)
        let overlayDuration = min(transitionDuration, 0.32)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = overlayDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            overlayView.animator().alphaValue = showing ? 1 : 0
        }
        if !showing {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = transitionDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                backgroundView.animator().alphaValue = 0
            }
            backgroundFolderHostView.removeAllPlates()
            foregroundFolderHostView.removeAllPlates()
            backgroundFolderHostView.resetSinkTransform()
            activeTransitionFolderID = nil
            backdropView.dismiss()
            fullScreenDimView.alphaValue = 0
            fullScreenDimView.isHidden = true
        }
    }

    @objc private func cacheClearRequested() {
        backgroundView.clearCacheAndReload()
        backgroundFolderHostView.removeAllPlates()
        backgroundFolderHostView.clearCache()
        foregroundFolderHostView.removeAllPlates()
        foregroundFolderHostView.clearCache()
        backgroundFolderHostView.resetSinkTransform()
        activeTransitionFolderID = nil
        backdropView.purgeTextures()
        backdropView.dismiss()
    }

    @objc private func gridLayoutChangedNote() {
        backgroundFolderHostView.removeAllPlates()
        backgroundFolderHostView.clearCache()
        foregroundFolderHostView.removeAllPlates()
        foregroundFolderHostView.clearCache()
        backgroundFolderHostView.resetSinkTransform()
        activeTransitionFolderID = nil
        backdropView.purgeTextures()
        backdropView.dismiss()
        metalView.needsDisplay = true
        syncPageIndicatorHitState()
    }

    private func syncOverlayAlpha() {
        // Keep overlay in sync if presentationProgress is driven from Metal.
        if store.presentation == .visible {
            overlayView.alphaValue = 1
            backgroundView.alphaValue = 1
        }
    }

    private func syncPageIndicatorHitState() {
        overlayView.pageCount = store.pageCount
        overlayView.currentPage = store.currentPage
        overlayView.isSearching = store.isSearching
        overlayView.safeInsets = store.safeInsets
        if let folderID = store.openedFolderID, let folder = store.folder(withID: folderID) {
            overlayView.folderCardMetrics = FolderCardMetrics(
                boundsSize: bounds.size,
                safeInsets: store.safeInsets,
                itemCount: folder.appIDs.count
            )
        } else {
            overlayView.folderCardMetrics = nil
        }
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        backdropView.frame = bounds
        backgroundFolderHostView.frame = bounds
        fullScreenDimView.frame = bounds
        foregroundFolderHostView.frame = bounds
        metalView.frame = bounds
        overlayView.frame = bounds
        folderTitleView.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc
        if event.keyCode == 53 {
            if store.openedFolderID != nil {
                store.exitFolder()
                return
            }
            NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
            return
        }
        // Fallback keyboard navigation when the search field is not first responder.
        if event.keyCode == 123 {
            store.moveKeyboardFocus(.left)
            return
        }
        if event.keyCode == 124 {
            store.moveKeyboardFocus(.right)
            return
        }
        if event.keyCode == 125 {
            store.moveKeyboardFocus(.down)
            return
        }
        if event.keyCode == 126 {
            store.moveKeyboardFocus(.up)
            return
        }
        super.keyDown(with: event)
    }

    func prepareForShow(
        on screen: NSScreen,
        animationStyle _: LaunchpadAnimationStyle
    ) {
        setPresentationScale(1)
        metalView.alphaValue = 0
        overlayView.alphaValue = 0
        backgroundView.prepare(for: screen)
        backgroundView.prepareForPresentation()
        window?.makeFirstResponder(self)
    }

    func prepareForInteractiveShow(on screen: NSScreen, style: LaunchpadAnimationStyle = LaunchpadAnimationStyle.current, initialProgress: CGFloat = 0.0) {
        setPresentationScale(1)
        metalView.alphaValue = 1
        let overlayAlpha = max(0, min(1, (initialProgress - 0.35) / 0.65))
        overlayView.alphaValue = overlayAlpha
        backgroundView.prepare(for: screen)
        backgroundView.prepareForPresentation()
        metalView.prepareForInteractivePresentation(style: style, initialProgress: initialProgress)
        window?.makeFirstResponder(self)
    }

    func prepareForInteractiveDismiss(style: LaunchpadAnimationStyle = LaunchpadAnimationStyle.current) {
        metalView.prepareForInteractiveDismiss(style: style)
    }

    func setInteractivePresentationProgress(_ progress: CGFloat) {
        let p = min(1, max(0, progress))
        metalView.applyInteractivePresentationProgress(p)
        backgroundView.alphaValue = p
        let overlayAlpha = max(0, min(1, (p - 0.35) / 0.65))
        overlayView.alphaValue = overlayAlpha
    }

    func animateInteractivePresentation(
        from start: CGFloat,
        to target: CGFloat,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        metalView.animateInteractivePresentation(
            from: start,
            to: target,
            duration: duration,
            onUpdate: { [weak self] phase in
                self?.backgroundView.alphaValue = phase
                let overlayAlpha = max(0, min(1, (phase - 0.35) / 0.65))
                self?.overlayView.alphaValue = overlayAlpha
            },
            completion: completion
        )
    }

    func cancelInteractiveFinishing() {
        metalView.cancelInteractiveFinishing()
    }

    func revealPrimedMetalContent() {
        metalView.alphaValue = 1
    }

    func hideImmediately() {
        metalView.resetInteractivePresentationState()
        metalView.clearDrawableIfAvailable()
        [backgroundView, metalView, overlayView].forEach { view in
            view.layer?.removeAllAnimations()
            view.alphaValue = 0
        }
        backgroundFolderHostView.removeAllPlates()
        foregroundFolderHostView.removeAllPlates()
        backgroundFolderHostView.resetSinkTransform()
        activeTransitionFolderID = nil
        setPresentationScale(1)
    }

    private func setPresentationScale(_ scale: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    func animateWallpaperIn(duration: CFTimeInterval = 0.64) {
        backgroundView.animateWallpaperIn(duration: duration)
    }

    func showWallpaperImmediately() {
        backgroundView.showWallpaperImmediately()
    }
}

// MARK: - SwiftUI overlay

struct LaunchpadOverlayView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var language = LocalizationManager.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Top Search Bar & bottom PageIndicator for root grid
                VStack(spacing: 0) {
                    if store.openedFolderID == nil {
                        SearchField(store: store)
                            .transition(.opacity)
                            .background {
                                Color.clear
                                    .frame(
                                        width: LaunchpadFieldHitArea.padSize.width,
                                        height: LaunchpadFieldHitArea.padSize.height
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        NotificationCenter.default.post(
                                            name: .qlaunchpadFocusSearch,
                                            object: nil
                                        )
                                    }
                                    .accessibilityHidden(true)
                            }
                            .padding(.top, LaunchpadFieldHitArea.topInset + store.safeInsets.top)
                    }
                    Spacer(minLength: 0)
                    if store.openedFolderID == nil {
                        PageIndicator(store: store)
                            .padding(.bottom, LaunchpadPageIndicatorHitArea.bottomInset + store.safeInsets.bottom)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.30), value: store.openedFolderID)

                if let folderID = store.openedFolderID,
                   !store.isFolderTransitionActive,
                   let folder = store.folder(withID: folderID),
                   store.pageCount > 1 {
                    let metrics = FolderCardMetrics(
                        boundsSize: geo.size,
                        safeInsets: store.safeInsets,
                        itemCount: folder.appIDs.count
                    )
                    PageIndicator(store: store)
                        .position(x: metrics.cardRect.midX, y: metrics.cardRect.maxY - 14)
                        .transition(.opacity)
                }

                if store.isDraggingFolderApp {
                    FolderRemovalDropZone(isTargeted: store.isFolderRemovalTargeted)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 76 + store.safeInsets.bottom)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, store.safeInsets.left)
            .padding(.trailing, store.safeInsets.right)
            .animation(.easeOut(duration: 0.18), value: store.isDraggingFolderApp)
            .animation(.easeOut(duration: 0.14), value: store.isFolderRemovalTargeted)
        }
        .ignoresSafeArea()
        .environment(\.locale, language.locale)
    }
}

private struct FolderRemovalDropZone: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 16, weight: .semibold))
            Text(L10n.tr("launchpad.removeFromFolder"))
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.82))
        .frame(width: 240, height: 54)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isTargeted ? 0.20 : 0.09))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isTargeted ? 0.62 : 0.22), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .scaleEffect(isTargeted ? 1.06 : 1)
    }
}

// MARK: - Liquid glass search field


private struct SearchField: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFocused = false
    /// Bumped to request first-responder; survives overlay reuse across presentations.
    @State private var focusRequestID = 0

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDark ? Color.white.opacity(0.72) : Color.black.opacity(0.65))
                .symbolRenderingMode(.hierarchical)

            // AppKit field: custom placeholder color + native IME marked-text handling.
            // SwiftUI `prompt` color is unreliable; overlay placeholders cover preedit.
            AppKitSearchTextField(
                text: Binding(
                    get: { store.searchText },
                    set: { store.updateSearch($0) }
                ),
                isFocused: $isFocused,
                focusRequestID: focusRequestID,
                placeholder: L10n.tr("launchpad.search"),
                isDark: isDark
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .qlaunchpadFocusSearch)) { _ in
                // Focus only when user explicitly clicks search or types
                focusRequestID &+= 1
            }

            Button {
                if !store.searchText.isEmpty {
                    store.updateSearch("")
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isDark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .opacity(store.searchText.isEmpty ? 0 : 1)
            .allowsHitTesting(!store.searchText.isEmpty)
            .accessibilityHidden(store.searchText.isEmpty)
            .help(L10n.tr("launchpad.clearSearch"))

            Button {
                NotificationCenter.default.post(name: .qlaunchpadOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isDark ? Color.white.opacity(0.68) : Color.black.opacity(0.65))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .padding(14)
            .contentShape(Rectangle())
            .padding(-14)
            .help(L10n.tr("launchpad.openSettings"))
            .accessibilityLabel(L10n.tr("launchpad.openSettings"))
        }
        .launchpadGlassField(isEmphasized: !store.searchText.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("launchpad.searchApps"))
    }
}

private extension View {
    func launchpadGlassField(isEmphasized: Bool) -> some View {
        modifier(LaunchpadGlassFieldChrome(isEmphasized: isEmphasized))
    }
}

/// Clear liquid glass chip. Rim brightens when typing, not merely because
/// the field holds first-responder (search is auto-focused on open).
private struct LaunchpadGlassFieldChrome: ViewModifier {
    var isEmphasized: Bool
    @Environment(\.colorScheme) private var colorScheme
    private let width: CGFloat = 320
    private let height: CGFloat = 38
    private let cornerRadius: CGFloat = 19

    private var isDark: Bool {
        colorScheme == .dark
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(width: width, height: height)
            .background { glassBackground }
            .overlay { glassStroke }
            .shadow(
                color: Color.black.opacity(isEmphasized ? (isDark ? 0.20 : 0.12) : (isDark ? 0.12 : 0.08)),
                radius: isEmphasized ? 18 : 14,
                y: 6
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.16), value: isEmphasized)
    }

    @ViewBuilder
    private var glassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.clear.interactive(true), in: shape)
        } else if #available(macOS 15.0, *) {
            ZStack {
                shape.fill(.ultraThinMaterial).opacity(isDark ? 0.55 : 0.65)
                shape.fill(
                    LinearGradient(
                        colors: isDark ? [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.02)
                        ] : [
                            Color.white.opacity(0.50),
                            Color.white.opacity(0.25),
                            Color.white.opacity(0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.stroke(
                    LinearGradient(
                        colors: isDark ? [
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.06),
                            Color.clear
                        ] : [
                            Color.black.opacity(0.12),
                            Color.black.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial).opacity(isDark ? 0.5 : 0.6)
                shape.fill(isDark ? Color.white.opacity(0.05) : Color.white.opacity(0.3))
            }
        }
    }

    private var glassStroke: some View {
        let baseColor = isDark ? Color.white : Color.black
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        baseColor.opacity(isEmphasized ? (isDark ? 0.46 : 0.32) : (isDark ? 0.22 : 0.14)),
                        baseColor.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isEmphasized ? 1 : 0.8
            )
    }
}

// MARK: - AppKit search field (placeholder color + IME)

/// Native single-line `NSTextView` so the IME field editor can report marked text
/// directly. `NSTextField`'s shared field editor only reliably reports committed
/// text, which is too late for responsive pinyin search.
private struct AppKitSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: Int
    var placeholder: String
    var isDark: Bool

    private static let textFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 16, weight: .medium)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: 16) ?? base
        }
        return base
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> IMESearchTextView {
        let view = IMESearchTextView(frame: .zero)
        view.explicitIsDark = isDark
        view.setSearchText(text)
        view.placeholder = placeholder
        view.delegate = context.coordinator
        view.onTextChange = { [weak coordinator = context.coordinator] value in
            coordinator?.updateSearchText(value)
        }
        return view
    }

    func updateNSView(_ field: IMESearchTextView, context: Context) {
        context.coordinator.parent = self
        field.explicitIsDark = isDark

        // Never replace the text while IME marked text is active.
        if !field.hasMarkedText(), field.string != text {
            field.setSearchText(text)
        }
        field.placeholder = placeholder
        field.needsDisplay = true

        if focusRequestID != context.coordinator.lastFocusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard field.superview != nil, let window = field.window else { return }
                if window.firstResponder !== field {
                    window.makeFirstResponder(field)
                }
                field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
                context.coordinator.parent.isFocused = true
            }
        }
    }

    static func dismantleNSView(_ view: IMESearchTextView, coordinator: Coordinator) {
        if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
        view.removeFromSuperview()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitSearchTextField
        var lastFocusRequestID = -1

        init(_ parent: AppKitSearchTextField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            updateSearchText(editor.string)
        }

        fileprivate func updateSearchText(_ value: String) {
            if parent.text != value {
                parent.text = value
            }
        }
    }
}

private final class IMESearchTextView: NSTextView {
    var placeholder = "Search"
    var onTextChange: ((String) -> Void)?
    var explicitIsDark: Bool? {
        didSet {
            if oldValue != explicitIsDark {
                updateColors()
            }
        }
    }

    private var isDarkMode: Bool {
        if let explicit = explicitIsDark {
            return explicit
        }
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var currentTextColor: NSColor {
        isDarkMode
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.88)
    }

    private var currentPlaceholderColor: NSColor {
        isDarkMode
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.48)
    }

    private var currentInsertionPointColor: NSColor {
        isDarkMode ? .white : .black
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureAppearance()
    }

    override init(frame frameRect: NSRect) {
        // Let AppKit create and connect the text storage, layout manager, and
        // container. A hand-built TextKit 1 stack can leave a lazy attribute
        // run in an invalid state on newer AppKit versions.
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureAppearance() {
        isRichText = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        minSize = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainerInset = .zero
        font = NSFont.systemFont(ofSize: 16, weight: .medium)
        backgroundColor = .clear
        allowsUndo = true
        updateColors()
    }

    func updateColors() {
        textColor = currentTextColor
        insertionPointColor = currentInsertionPointColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: currentTextColor as Any
        ]
        typingAttributes = attributes
        if let textStorage, textStorage.length > 0 {
            textStorage.addAttribute(
                .foregroundColor,
                value: currentTextColor,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    func setSearchText(_ value: String) {
        guard !hasMarkedText() else { return }
        guard string != value else { return }

        // Replace the whole value with one fully attributed string. This keeps
        // externally synchronized values valid before AppKit lays them out,
        // without changing the storage during a draw pass.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: currentTextColor as Any
        ]
        textStorage?.setAttributedString(
            NSAttributedString(string: value, attributes: attributes)
        )
        typingAttributes = attributes
    }

    override func layout() {
        super.layout()
        // NSTextView defaults to a top-aligned text container. Center the
        // single-line editor in the glass search field so the glyphs and
        // insertion caret align with the surrounding toolbar buttons.
        let lineHeight = max(font?.boundingRectForFont.height ?? 19, 1)
        textContainerInset = NSSize(
            width: 0,
            height: max(0, (bounds.height - lineHeight) * 0.5)
        )
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onTextChange?(string)
        needsDisplay = true
    }

    override func setMarkedText(
        _ markedText: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            markedText,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        // NSTextView may not send textDidChange while composition is active.
        // Report the value only after AppKit has finished mutating its storage.
        onTextChange?(string)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep single-line container width in sync with the view.
        if let textContainer, textContainer.containerSize.width != newSize.width {
            textContainer.containerSize = NSSize(
                width: max(newSize.width, 1),
                height: textContainer.containerSize.height
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: currentPlaceholderColor
        ]
        let size = placeholder.size(withAttributes: attributes)
        let y = max(0, (bounds.height - size.height) / 2)
        placeholder.draw(at: NSPoint(x: 0, y: y), withAttributes: attributes)
    }
}

// MARK: - Page indicator

private struct PageIndicator: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let pageCount = store.pageCount
        let currentPage = store.currentPage
        // Hide when searching or single page.
        if pageCount > 1 && !store.isSearching {
            HStack(spacing: LaunchpadPageIndicatorHitArea.spacing) {
                ForEach(0..<pageCount, id: \.self) { page in
                    Capsule(style: .continuous)
                        .fill(page == currentPage ? Color.white : Color.white.opacity(0.32))
                        .frame(
                            width: page == currentPage
                                ? LaunchpadPageIndicatorHitArea.activeDotWidth
                                : LaunchpadPageIndicatorHitArea.dotWidth,
                            height: LaunchpadPageIndicatorHitArea.dotHeight
                        )
                        .accessibilityLabel(L10n.tr("launchpad.page", page + 1))
                        .accessibilityAddTraits(page == currentPage ? .isSelected : [])
                        .accessibilityAction {
                            store.goToPage(page)
                        }
                }
            }
            .allowsHitTesting(false)
            .padding(.horizontal, LaunchpadPageIndicatorHitArea.horizontalPadding)
            .padding(.vertical, LaunchpadPageIndicatorHitArea.verticalPadding)
            .background {
                if #available(macOS 26.0, *) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(.clear, in: Capsule(style: .continuous))
                        .opacity(0.58)
                } else {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.3)
                        .overlay(Capsule(style: .continuous).fill(Color.white.opacity(0.02)))
                }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .contentShape(Capsule(style: .continuous))
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: currentPage)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }
}
