//
//  AgentRingOverlay.swift
//  leanring-buddy
//
//  Saathi's visual identity: a marigold ring that travels across the
//  screen as a small circle, leaving a fading trail, then morphs into the
//  exact outline of its target. Its look encodes what is happening:
//
//    Pointing         dashed outline hugging the target (answering a question)
//    Doing it         filled tint; presses the target with a squeeze + ripple
//    Your turn        parked beside a field with a lock badge (OTP/password)
//    Confirm          red outline: about to do something irreversible
//
//  Supporting pieces: spotlight dimming around the target, a caption chip
//  with the narration and step counter, and a "driving" edge glow with an
//  Esc hint whenever Saathi is controlling the computer.
//

import AppKit
import Combine
import SwiftUI

enum RingPresentationMode: Equatable {
    case hidden
    case thinking
    case pointing
    case justDoIt
    case yourTurn
    case awaitingConfirmation
}

enum SaathiColors {
    static let marigold = Color(red: 0.961, green: 0.647, blue: 0.141)
    static let marigoldDeep = Color(red: 0.878, green: 0.565, blue: 0.102)
    static let confirmationRed = Color(red: 0.898, green: 0.282, blue: 0.302)
    static let captionBackground = Color(red: 0.09, green: 0.08, blue: 0.07)
}

@MainActor
final class AgentOverlayState: ObservableObject {
    @Published var mode: RingPresentationMode = .hidden
    /// Target outline in global AppKit coordinates (bottom-left origin).
    @Published var targetFrameInAppKitCoordinates: CGRect?
    @Published var captionText: String = ""
    @Published var stepLabelText: String?
    @Published var isDrivingIndicatorVisible: Bool = false
    /// Incremented to play the press animation (squeeze + ripple).
    @Published var pressAnimationCounter: Int = 0
}

// MARK: - Window management

@MainActor
final class AgentOverlayController {
    let overlayState = AgentOverlayState()
    private var overlayWindows: [NSWindow] = []
    private var screenConfigurationObserver: NSObjectProtocol?

    init() {
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildWindowsIfVisible()
            }
        }
    }

    private func ensureWindowsExist() {
        guard overlayWindows.isEmpty else { return }
        for screen in NSScreen.screens {
            // Reuses Clicky's transparent, click-through, all-Spaces window,
            // one level above the cursor buddy so the ring draws on top.
            let overlayWindow = OverlayWindow(screen: screen)
            overlayWindow.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            let ringOverlayView = AgentRingOverlayView(
                screenFrame: screen.frame,
                overlayState: overlayState,
                settings: SaathiSettings.shared
            )
            let hostingView = NSHostingView(rootView: ringOverlayView)
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            overlayWindow.contentView = hostingView
            overlayWindows.append(overlayWindow)
        }
    }

    private func rebuildWindowsIfVisible() {
        let wereVisible = overlayWindows.contains { $0.isVisible }
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        if wereVisible {
            showWindows()
        }
    }

    func showWindows() {
        ensureWindowsExist()
        overlayWindows.forEach { $0.orderFrontRegardless() }
    }

    /// Clears everything; the windows stay alive (cheap) but draw nothing.
    func clear() {
        overlayState.mode = .hidden
        overlayState.targetFrameInAppKitCoordinates = nil
        overlayState.captionText = ""
        overlayState.stepLabelText = nil
        overlayState.isDrivingIndicatorVisible = false
    }

    func present(
        mode: RingPresentationMode,
        targetFrameInAppKitCoordinates: CGRect?,
        captionText: String,
        stepLabelText: String?
    ) {
        showWindows()
        overlayState.mode = mode
        overlayState.targetFrameInAppKitCoordinates = targetFrameInAppKitCoordinates
        overlayState.captionText = captionText
        overlayState.stepLabelText = stepLabelText
    }

    func playPressAnimation() {
        overlayState.pressAnimationCounter += 1
    }
}

// MARK: - Ring view (one per screen)

private struct CaptionChipSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct AgentRingOverlayView: View {
    let screenFrame: CGRect
    @ObservedObject var overlayState: AgentOverlayState
    @ObservedObject var settings: SaathiSettings

    /// The ring's current rectangle in this screen's local SwiftUI coordinates.
    @State private var ringFrameInLocalCoordinates: CGRect = .zero
    @State private var ringCornerRadius: CGFloat = 13
    @State private var isRingOnThisScreen: Bool = false
    /// Increments for every new target so a stale morph step is skipped.
    @State private var morphGeneration: Int = 0

    @State private var trailStartPoint: CGPoint = .zero
    @State private var trailEndPoint: CGPoint = .zero
    @State private var trailOpacity: Double = 0

    @State private var pressScale: CGFloat = 1.0
    @State private var rippleProgress: CGFloat = 1.0

    @State private var captionChipSize: CGSize = .zero

    private let travellingCircleDiameter: CGFloat = 26
    private let targetPadding: CGFloat = 6

    var body: some View {
        ZStack {
            Color.clear

            spotlightLayer
            trailLayer
            ringLayer
            thinkingIndicatorLayer
            captionChipLayer
            drivingIndicatorLayer
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: overlayState.targetFrameInAppKitCoordinates) { _, newTargetFrame in
            handleTargetChange(newTargetFrame)
        }
        .onChange(of: overlayState.mode) { _, newMode in
            if newMode == .hidden || newMode == .thinking {
                if overlayState.targetFrameInAppKitCoordinates == nil {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isRingOnThisScreen = false
                    }
                }
            }
        }
        .onChange(of: overlayState.pressAnimationCounter) { _, _ in
            playPressAnimation()
        }
        .onAppear {
            handleTargetChange(overlayState.targetFrameInAppKitCoordinates)
        }
    }

    // MARK: Layers

    private var isTargetPresentationMode: Bool {
        switch overlayState.mode {
        case .pointing, .justDoIt, .yourTurn, .awaitingConfirmation:
            return true
        case .hidden, .thinking:
            return false
        }
    }

    private var ringColor: Color {
        overlayState.mode == .awaitingConfirmation ? SaathiColors.confirmationRed : SaathiColors.marigold
    }

    @ViewBuilder
    private var spotlightLayer: some View {
        if settings.isSpotlightEnabled && isRingOnThisScreen && isTargetPresentationMode {
            let screenRect = CGRect(origin: .zero, size: screenFrame.size)
            let spotlightHole = ringFrameInLocalCoordinates.insetBy(dx: -4, dy: -4)
            Path { spotlightPath in
                spotlightPath.addRect(screenRect)
                spotlightPath.addRoundedRect(in: spotlightHole, cornerSize: CGSize(width: ringCornerRadius + 4, height: ringCornerRadius + 4))
            }
            .fill(Color.black.opacity(0.24), style: FillStyle(eoFill: true))
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var trailLayer: some View {
        if isRingOnThisScreen && trailOpacity > 0.01 {
            Path { trailPath in
                trailPath.move(to: trailStartPoint)
                trailPath.addLine(to: trailEndPoint)
            }
            .stroke(
                LinearGradient(
                    colors: [SaathiColors.marigold.opacity(0), SaathiColors.marigold.opacity(0.85)],
                    startPoint: UnitPoint(x: 0, y: 0),
                    endPoint: UnitPoint(x: 1, y: 1)
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7])
            )
            .opacity(trailOpacity)
        }
    }

    @ViewBuilder
    private var ringLayer: some View {
        if isRingOnThisScreen && isTargetPresentationMode {
            ZStack {
                // Fill tint for "Just do it" and confirmation
                if overlayState.mode == .justDoIt || overlayState.mode == .awaitingConfirmation {
                    RoundedRectangle(cornerRadius: ringCornerRadius, style: .continuous)
                        .fill(ringColor.opacity(0.20))
                }

                // The ring itself
                RoundedRectangle(cornerRadius: ringCornerRadius, style: .continuous)
                    .stroke(ringColor, style: ringStrokeStyle)
                    .shadow(color: ringColor.opacity(0.55), radius: 6)

                // Slow outward pulse: "are you sure?" before an irreversible step
                if overlayState.mode == .awaitingConfirmation {
                    TimelineView(.animation) { timelineContext in
                        let pulsePhase = CGFloat(timelineContext.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.5) / 1.5)
                        RoundedRectangle(cornerRadius: ringCornerRadius + 6 * pulsePhase, style: .continuous)
                            .stroke(ringColor.opacity(0.65 * Double(1 - pulsePhase)), lineWidth: 2)
                            .padding(-10 * pulsePhase)
                    }
                }

                // Press ripple
                if rippleProgress < 1 {
                    RoundedRectangle(cornerRadius: ringCornerRadius + 10 * rippleProgress, style: .continuous)
                        .stroke(ringColor.opacity(Double(1 - rippleProgress)), lineWidth: 3)
                        .padding(-22 * rippleProgress)
                }
            }
            .frame(width: ringFrameInLocalCoordinates.width, height: ringFrameInLocalCoordinates.height)
            .overlay(alignment: .topTrailing) {
                if overlayState.mode == .yourTurn {
                    lockBadge
                        .offset(x: 11, y: -11)
                }
            }
            .scaleEffect(pressScale)
            .position(x: ringFrameInLocalCoordinates.midX, y: ringFrameInLocalCoordinates.midY)
            .transition(.opacity)
        }
    }

    private var ringStrokeStyle: StrokeStyle {
        switch overlayState.mode {
        case .pointing:
            return StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6])
        case .yourTurn:
            return StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5])
        case .justDoIt, .awaitingConfirmation:
            return StrokeStyle(lineWidth: 3.5, lineCap: .round)
        case .hidden, .thinking:
            return StrokeStyle(lineWidth: 3, lineCap: .round)
        }
    }

    private var lockBadge: some View {
        ZStack {
            Circle()
                .fill(SaathiColors.marigold)
                .frame(width: 22, height: 22)
                .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(SaathiColors.captionBackground)
        }
    }

    /// While planning, a small spinning dashed ring sits beside the mouse.
    @ViewBuilder
    private var thinkingIndicatorLayer: some View {
        if overlayState.mode == .thinking && isMouseOnThisScreen {
            TimelineView(.animation) { timelineContext in
                let rotationDegrees = timelineContext.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                let mouseLocalPosition = mouseLocationInLocalCoordinates
                Circle()
                    .stroke(SaathiColors.marigold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(rotationDegrees))
                    .shadow(color: SaathiColors.marigold.opacity(0.6), radius: 5)
                    .position(x: mouseLocalPosition.x + 30, y: mouseLocalPosition.y + 26)
            }
        }
    }

    @ViewBuilder
    private var captionChipLayer: some View {
        if !overlayState.captionText.isEmpty && shouldShowCaptionOnThisScreen {
            captionChip
                .background(
                    GeometryReader { geometryProxy in
                        Color.clear.preference(key: CaptionChipSizePreferenceKey.self, value: geometryProxy.size)
                    }
                )
                .onPreferenceChange(CaptionChipSizePreferenceKey.self) { newSize in
                    captionChipSize = newSize
                }
                .position(captionChipCenter)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: ringFrameInLocalCoordinates)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var captionChip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stepLabelText = overlayState.stepLabelText {
                Text(stepLabelText.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(ringColor)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(ringColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Text(overlayState.captionText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SaathiColors.captionBackground.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ringColor.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
    }

    private var shouldShowCaptionOnThisScreen: Bool {
        if isRingOnThisScreen && isTargetPresentationMode {
            return true
        }
        // With no target on any screen, the caption follows the mouse.
        if overlayState.targetFrameInAppKitCoordinates == nil || !isTargetPresentationMode {
            return isMouseOnThisScreen
        }
        return false
    }

    /// Below the ring when there's room, otherwise above; clamped to the screen.
    private var captionChipCenter: CGPoint {
        let chipWidth = max(captionChipSize.width, 120)
        let chipHeight = max(captionChipSize.height, 36)
        let horizontalMargin: CGFloat = 16

        let anchorRect: CGRect
        if isRingOnThisScreen && isTargetPresentationMode {
            anchorRect = ringFrameInLocalCoordinates
        } else {
            let mouseLocalPosition = mouseLocationInLocalCoordinates
            anchorRect = CGRect(x: mouseLocalPosition.x + 24, y: mouseLocalPosition.y + 20, width: 1, height: 1)
        }

        var centerX = anchorRect.minX + chipWidth / 2
        centerX = min(max(centerX, chipWidth / 2 + horizontalMargin), screenFrame.width - chipWidth / 2 - horizontalMargin)

        let spaceBelowAnchor = screenFrame.height - anchorRect.maxY
        let centerY: CGFloat
        if spaceBelowAnchor > chipHeight + 40 {
            centerY = anchorRect.maxY + 14 + chipHeight / 2
        } else {
            centerY = anchorRect.minY - 14 - chipHeight / 2
        }
        return CGPoint(x: centerX, y: centerY)
    }

    @ViewBuilder
    private var drivingIndicatorLayer: some View {
        if overlayState.isDrivingIndicatorVisible {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SaathiColors.marigold.opacity(0.85), lineWidth: 6)
                    .blur(radius: 8)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SaathiColors.marigold, lineWidth: 2)

                HStack(spacing: 8) {
                    Circle()
                        .fill(SaathiColors.marigold)
                        .frame(width: 7, height: 7)
                    Text("\(SaathiConfiguration.productName) is driving")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Esc to stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SaathiColors.marigold)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(SaathiColors.captionBackground.opacity(0.94)))
                .overlay(Capsule().stroke(SaathiColors.marigold.opacity(0.5), lineWidth: 1))
                .padding(.top, 34)
            }
            .padding(2)
            .transition(.opacity)
        }
    }

    // MARK: Motion

    private func handleTargetChange(_ newTargetFrameInAppKitCoordinates: CGRect?) {
        morphGeneration += 1
        let currentMorphGeneration = morphGeneration

        guard let newTargetFrameInAppKitCoordinates else {
            withAnimation(.easeOut(duration: 0.25)) {
                isRingOnThisScreen = false
            }
            return
        }

        let targetCenter = CGPoint(x: newTargetFrameInAppKitCoordinates.midX, y: newTargetFrameInAppKitCoordinates.midY)
        guard screenFrame.contains(targetCenter) else {
            withAnimation(.easeOut(duration: 0.25)) {
                isRingOnThisScreen = false
            }
            return
        }

        let targetFrameInLocalCoordinates = convertAppKitRectToLocal(newTargetFrameInAppKitCoordinates)
            .insetBy(dx: -targetPadding, dy: -targetPadding)
        let finalCornerRadius = min(12, targetFrameInLocalCoordinates.height / 2)

        // First appearance: start as a small circle at the mouse (or at the target).
        if !isRingOnThisScreen {
            let startPoint = isMouseOnThisScreen
                ? CGPoint(x: mouseLocationInLocalCoordinates.x + 30, y: mouseLocationInLocalCoordinates.y + 26)
                : CGPoint(x: targetFrameInLocalCoordinates.midX, y: targetFrameInLocalCoordinates.midY)
            ringFrameInLocalCoordinates = circleRect(centeredAt: startPoint)
            ringCornerRadius = travellingCircleDiameter / 2
            withAnimation(.easeOut(duration: 0.2)) {
                isRingOnThisScreen = true
            }
        }

        let travelStartPoint = CGPoint(x: ringFrameInLocalCoordinates.midX, y: ringFrameInLocalCoordinates.midY)
        let travelEndPoint = CGPoint(x: targetFrameInLocalCoordinates.midX, y: targetFrameInLocalCoordinates.midY)
        let travelDistance = hypot(travelEndPoint.x - travelStartPoint.x, travelEndPoint.y - travelStartPoint.y)
        let travelDuration = min(0.75, max(0.3, Double(travelDistance) / 1600))

        // Trail from where the ring was to where it's going, fading out.
        trailStartPoint = travelStartPoint
        trailEndPoint = travelEndPoint
        trailOpacity = travelDistance > 40 ? 0.9 : 0
        withAnimation(.easeOut(duration: travelDuration + 0.6)) {
            trailOpacity = 0
        }

        // Phase 1: shrink to a circle and travel.
        withAnimation(.easeInOut(duration: travelDuration)) {
            ringFrameInLocalCoordinates = circleRect(centeredAt: travelEndPoint)
            ringCornerRadius = travellingCircleDiameter / 2
        }

        // Phase 2: morph into the target's outline.
        DispatchQueue.main.asyncAfter(deadline: .now() + travelDuration) {
            guard currentMorphGeneration == morphGeneration else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                ringFrameInLocalCoordinates = targetFrameInLocalCoordinates
                ringCornerRadius = finalCornerRadius
            }
        }
    }

    private func playPressAnimation() {
        withAnimation(.easeIn(duration: 0.09)) {
            pressScale = 0.9
        }
        rippleProgress = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                pressScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.55)) {
                rippleProgress = 1
            }
        }
    }

    // MARK: Coordinates

    private func circleRect(centeredAt centerPoint: CGPoint) -> CGRect {
        CGRect(
            x: centerPoint.x - travellingCircleDiameter / 2,
            y: centerPoint.y - travellingCircleDiameter / 2,
            width: travellingCircleDiameter,
            height: travellingCircleDiameter
        )
    }

    private func convertAppKitRectToLocal(_ appKitRect: CGRect) -> CGRect {
        CGRect(
            x: appKitRect.minX - screenFrame.minX,
            y: screenFrame.maxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    private var isMouseOnThisScreen: Bool {
        screenFrame.contains(NSEvent.mouseLocation)
    }

    private var mouseLocationInLocalCoordinates: CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        return CGPoint(x: mouseLocation.x - screenFrame.minX, y: screenFrame.maxY - mouseLocation.y)
    }
}

// MARK: - Clickable floating controls (Confirm / Stop / Next / Save skill)

/// Borderless panels can't become key by default; this lets buttons respond
/// without activating Saathi or stealing focus from the user's app.
private final class AgentControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct AgentControlButtonDescriptor: Identifiable {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    let id = UUID()
    let title: String
    let style: Style
    let action: () -> Void
}

@MainActor
final class AgentFloatingControlsController {
    private var controlPanel: NSPanel?

    /// Shows a small floating card near the bottom of the screen the target is on.
    func show(
        titleText: String,
        buttons: [AgentControlButtonDescriptor],
        nearAppKitRect anchorRect: CGRect?
    ) {
        hide()

        let controlsView = AgentFloatingControlsView(titleText: titleText, buttons: buttons)
        let hostingView = NSHostingView(rootView: controlsView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = CGRect(origin: .zero, size: fittingSize)

        let panel = AgentControlPanel(
            contentRect: CGRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hostingView

        let anchorPoint = anchorRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(anchorPoint) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let panelOrigin = CGPoint(
                x: visibleFrame.midX - fittingSize.width / 2,
                y: visibleFrame.minY + 36
            )
            panel.setFrameOrigin(panelOrigin)
        }

        panel.orderFrontRegardless()
        controlPanel = panel
    }

    func hide() {
        controlPanel?.orderOut(nil)
        controlPanel = nil
    }
}

private struct AgentFloatingControlsView: View {
    let titleText: String
    let buttons: [AgentControlButtonDescriptor]

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SaathiColors.marigold)
                .frame(width: 8, height: 8)
            Text(titleText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
            ForEach(buttons) { buttonDescriptor in
                Button(action: buttonDescriptor.action) {
                    Text(buttonDescriptor.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(foregroundColor(for: buttonDescriptor.style))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(backgroundColor(for: buttonDescriptor.style))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SaathiColors.captionBackground.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SaathiColors.marigold.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 16, y: 6)
        .padding(16)
    }

    private func backgroundColor(for style: AgentControlButtonDescriptor.Style) -> Color {
        switch style {
        case .primary: return SaathiColors.marigold
        case .secondary: return Color.white.opacity(0.10)
        case .destructive: return SaathiColors.confirmationRed
        }
    }

    private func foregroundColor(for style: AgentControlButtonDescriptor.Style) -> Color {
        switch style {
        case .primary: return SaathiColors.captionBackground
        case .secondary, .destructive: return .white
        }
    }
}
