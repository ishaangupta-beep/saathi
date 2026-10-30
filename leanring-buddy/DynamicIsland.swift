//
//  DynamicIsland.swift
//  leanring-buddy
//
//  Saathi's home on screen: a black pill at the top centre that blends into
//  the MacBook notch (or sits in the menu bar on Macs without one). It is the
//  one place to look and the one place to act:
//
//    idle       — tiny; hover shows "Ask Saathi", click or ⌘⇧Space opens the box
//    asking     — type a request, pick Show / Walk / Do, press Return
//    listening  — while Control+Option is held
//    thinking   — planning, with what it's working on
//    running    — "Step 3" + what it's doing + Stop
//    waiting    — "Your move" / "Confirm" with the buttons for that moment
//    message    — the result or an answer, then it shrinks back
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DynamicIslandState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking
        case listening
        case thinking
        case running
        case waiting
        case message
    }

    @Published var phase: Phase = .idle
    @Published var titleText: String = ""
    @Published var detailText: String = ""
    @Published var buttons: [AgentControlButtonDescriptor] = []
    @Published var isHovering: Bool = false
    @Published var requestText: String = ""
    /// Drawn with the confirmation colour (about to do something irreversible).
    @Published var isWarning: Bool = false
}

/// Borderless panels can't become key by default. The island needs to, so
/// its text field can take typing — without activating Saathi or stealing
/// the user's app from the front.
private final class DynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DynamicIslandController {
    static let shared = DynamicIslandController()

    let state = DynamicIslandState()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<DynamicIslandView>?
    private var stateChangeCancellable: AnyCancellable?
    private var returnToIdleTask: Task<Void, Never>?
    private var hotkeyGlobalMonitor: Any?
    private var hotkeyLocalMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?

    private init() {}

    // MARK: Setup

    func start() {
        guard panel == nil else { return }

        let islandView = DynamicIslandView(
            state: state,
            settings: SaathiSettings.shared,
            notchSize: Self.notchSize(on: Self.islandScreen()),
            hasNotch: (Self.islandScreen()?.safeAreaInsets.top ?? 0) > 0,
            onSubmitRequest: { [weak self] in self?.submitRequest() },
            onBeginAsking: { [weak self] in self?.beginAsking() },
            onCancelAsking: { [weak self] in self?.returnToIdle() },
            onStop: { AgentCoordinator.shared.stopEverything() }
        )
        let newHostingView = NSHostingView(rootView: islandView)
        newHostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let newPanel = DynamicIslandPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        // Above the menu bar and above the ring overlay.
        newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.contentView = newHostingView

        panel = newPanel
        hostingView = newHostingView

        // Resize the panel to the pill whenever its content changes, so the
        // transparent area never blocks clicks on the apps underneath.
        stateChangeCancellable = state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeToFitContent()
                }
            }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizeToFitContent()
            }
        }

        installHotkey()
        resizeToFitContent()
        newPanel.orderFrontRegardless()
    }

    /// ⌘⇧Space opens the ask box from anywhere.
    private func installHotkey() {
        hotkeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            let isAskShortcut = keyEvent.keyCode == 49
                && keyEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
            guard isAskShortcut else { return }
            MainActor.assumeIsolated {
                self?.beginAsking()
            }
        }
        hotkeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            let isAskShortcut = keyEvent.keyCode == 49
                && keyEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
            if isAskShortcut {
                MainActor.assumeIsolated {
                    self?.beginAsking()
                }
                return nil
            }
            return keyEvent
        }
    }

    // MARK: Geometry

    /// The built-in display (it has the notch), otherwise the main display.
    private static func islandScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Size of the camera notch, or a menu-bar-height pill on Macs without one.
    static func notchSize(on screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 180, height: 24) }
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - leftArea.width - rightArea.width
            return CGSize(width: max(notchWidth, 160), height: notchHeight)
        }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGSize(width: 180, height: menuBarHeight)
    }

    private func resizeToFitContent() {
        guard let panel, let hostingView, let screen = Self.islandScreen() else { return }
        let fittingSize = hostingView.fittingSize
        let panelFrame = CGRect(
            x: screen.frame.midX - fittingSize.width / 2,
            y: screen.frame.maxY - fittingSize.height,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(panelFrame, display: true)
    }

    // MARK: Asking

    func beginAsking() {
        returnToIdleTask?.cancel()
        state.phase = .asking
        state.titleText = ""
        state.detailText = ""
        state.isWarning = false
        state.buttons = []
        // Becoming key lets the text field take typing; the user's app stays frontmost.
        panel?.makeKey()
    }

    private func submitRequest() {
        let trimmedRequest = state.requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else {
            returnToIdle()
            return
        }
        state.requestText = ""
        // Hand the keyboard back to the user's app before Saathi starts typing into it.
        panel?.resignKey()
        AccessibilityTreeReader.lastActiveExternalApplication?.activate()
        AgentCoordinator.shared.runTask(trimmedRequest)
    }

    // MARK: Updates from the agent and the voice pipeline

    func showListening() {
        returnToIdleTask?.cancel()
        state.phase = .listening
        state.titleText = "Listening"
        state.detailText = ""
        state.buttons = []
        state.isWarning = false
    }

    func showThinking(_ detailText: String) {
        returnToIdleTask?.cancel()
        state.phase = .thinking
        state.titleText = "Thinking"
        state.detailText = detailText
        state.buttons = []
        state.isWarning = false
    }

    func showRunning(stepLabelText: String, narration: String) {
        returnToIdleTask?.cancel()
        state.phase = .running
        state.titleText = stepLabelText
        state.detailText = narration
        state.buttons = []
        state.isWarning = false
    }

    func showWaiting(titleText: String, detailText: String, buttons: [AgentControlButtonDescriptor], isWarning: Bool) {
        returnToIdleTask?.cancel()
        state.phase = .waiting
        state.titleText = titleText
        state.detailText = detailText
        state.buttons = buttons
        state.isWarning = isWarning
    }

    /// Shows a result or answer, then shrinks back after a few seconds
    /// (longer for longer text so it can be read).
    func showMessage(_ messageText: String) {
        returnToIdleTask?.cancel()
        state.phase = .message
        state.titleText = ""
        state.detailText = messageText
        state.buttons = []
        state.isWarning = false
        let displaySeconds = min(14, max(5, Double(messageText.count) / 14))
        returnToIdleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(displaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.returnToIdle()
        }
    }

    func returnToIdle() {
        returnToIdleTask?.cancel()
        panel?.resignKey()
        state.phase = .idle
        state.titleText = ""
        state.detailText = ""
        state.buttons = []
        state.isWarning = false
    }
}

// MARK: - View

struct DynamicIslandView: View {
    @ObservedObject var state: DynamicIslandState
    @ObservedObject var settings: SaathiSettings
    let notchSize: CGSize
    /// Without a notch the idle pill sits in the menu bar, so it shows a small ring to be findable.
    let hasNotch: Bool
    let onSubmitRequest: () -> Void
    let onBeginAsking: () -> Void
    let onCancelAsking: () -> Void
    let onStop: () -> Void

    @FocusState private var isRequestFieldFocused: Bool

    private let expandedWidth: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            // The top strip sits behind the camera notch; content goes below it.
            ZStack {
                Color.clear
                if !hasNotch && !isExpanded {
                    Circle()
                        .stroke(SaathiColors.marigold, lineWidth: 2)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(height: notchSize.height)

            if state.phase != .idle || state.isHovering {
                expandedContent
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: isExpanded ? expandedWidth : notchSize.width)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: isExpanded ? 22 : 12,
                bottomTrailingRadius: isExpanded ? 22 : 12,
                style: .continuous
            )
            .fill(Color.black)
        )
        .overlay(alignment: .bottom) {
            // A thin marigold line under the pill while Saathi is active.
            if state.phase == .running || state.phase == .thinking || state.phase == .listening {
                Capsule()
                    .fill(state.isWarning ? SaathiColors.confirmationRed : SaathiColors.marigold)
                    .frame(width: 60, height: 3)
                    .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                state.isHovering = isHovering && state.phase == .idle
            }
        }
        .onTapGesture {
            if state.phase == .idle {
                onBeginAsking()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.phase)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.detailText)
        .fixedSize(horizontal: true, vertical: true)
        .onChange(of: state.phase) { _, newPhase in
            if newPhase == .asking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isRequestFieldFocused = true
                }
            }
        }
    }

    private var isExpanded: Bool {
        state.phase != .idle || state.isHovering
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch state.phase {
        case .idle:
            hoverHint
        case .asking:
            askingContent
        case .listening:
            statusRow(icon: AnyView(ListeningBars()), title: "Listening", detail: "Release Control + Option when you're done")
        case .thinking:
            statusRow(icon: AnyView(SpinningRing()), title: state.titleText, detail: state.detailText)
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                statusRow(icon: AnyView(PulsingDot(color: SaathiColors.marigold)), title: state.titleText, detail: state.detailText)
                HStack {
                    Text("Esc to stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    islandButton(title: "Stop", style: .secondary, action: onStop)
                }
            }
        case .waiting:
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: AnyView(PulsingDot(color: state.isWarning ? SaathiColors.confirmationRed : SaathiColors.marigold)),
                    title: state.titleText,
                    detail: state.detailText
                )
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(state.buttons) { buttonDescriptor in
                        islandButton(title: buttonDescriptor.title, style: buttonDescriptor.style, action: buttonDescriptor.action)
                    }
                }
            }
        case .message:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SaathiColors.marigold)
                    .padding(.top, 2)
                Text(state.detailText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var hoverHint: some View {
        HStack(spacing: 8) {
            Circle()
                .stroke(SaathiColors.marigold, lineWidth: 2)
                .frame(width: 12, height: 12)
            Text("Ask \(SaathiConfiguration.productName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text("⌘⇧Space  ·  hold ⌃⌥ to talk")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var askingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .stroke(SaathiColors.marigold, lineWidth: 2)
                    .frame(width: 12, height: 12)
                TextField("", text: $state.requestText, prompt: Text("What should I do?").foregroundColor(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .focused($isRequestFieldFocused)
                    .onSubmit(onSubmitRequest)
                    .onExitCommand(perform: onCancelAsking)
                Button(action: onSubmitRequest) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(SaathiColors.captionBackground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SaathiColors.marigold))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            HStack(spacing: 6) {
                // The mode chips only appear when there's more than one mode.
                if TrustLevel.allCases.count > 1 {
                    ForEach(TrustLevel.allCases) { trustLevel in
                        trustChip(trustLevel)
                    }
                }
                Spacer()
                Text("Return to go · Esc to close")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private func trustChip(_ trustLevel: TrustLevel) -> some View {
        let isSelected = settings.trustLevel == trustLevel
        return Button(action: { settings.trustLevel = trustLevel }) {
            HStack(spacing: 5) {
                TrustLevelRingGlyph(trustLevel: trustLevel, isSelected: isSelected)
                Text(trustLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? SaathiColors.captionBackground : .white.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? SaathiColors.marigold : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func statusRow(icon: AnyView, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(state.isWarning ? SaathiColors.confirmationRed : SaathiColors.marigold)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func islandButton(title: String, style: AgentControlButtonDescriptor.Style, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(style == .primary ? SaathiColors.captionBackground : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        style == .primary ? SaathiColors.marigold
                            : (style == .destructive ? SaathiColors.confirmationRed : Color.white.opacity(0.12))
                    )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Small animated pieces

private struct PulsingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { timelineContext in
            let pulsePhase = CGFloat(timelineContext.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4)
            ZStack {
                Circle()
                    .stroke(color.opacity(Double(1 - pulsePhase)), lineWidth: 1.5)
                    .scaleEffect(0.6 + pulsePhase * 0.8)
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

private struct SpinningRing: View {
    var body: some View {
        TimelineView(.animation) { timelineContext in
            let rotationDegrees = timelineContext.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
            Circle()
                .stroke(SaathiColors.marigold, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                .rotationEffect(.degrees(rotationDegrees))
        }
    }
}

private struct ListeningBars: View {
    var body: some View {
        TimelineView(.animation) { timelineContext in
            let time = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { barIndex in
                    Capsule()
                        .fill(SaathiColors.marigold)
                        .frame(width: 2.5, height: 4 + 10 * abs(sin(time * 5 + Double(barIndex) * 0.9)))
                }
            }
        }
    }
}
