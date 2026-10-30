//
//  AgentCoordinator.swift
//  leanring-buddy
//
//  Saathi's task agent. One request ("download my Aadhaar") runs as:
//
//    1. Saved skill?  → replay it, re-finding each target on the current screen
//    2. Otherwise     → research the official steps (Tavily), then a live loop:
//         observe (Accessibility tree + privacy-shielded screenshot)
//         plan    (Nemotron Super on the element list; Omni on the screenshot
//                  when the tree is empty, e.g. canvas apps)
//         present (marigold ring + caption + voice)
//         act (pausing for anything private or irreversible)
//    3. After a successful live run → offer to save it as a skill
//
//  Safety rules enforced in code, not only in the prompt:
//    • a hard pause before anything that looks irreversible (pay, submit, send…)
//    • never types passwords, OTPs, PINs, card or ID numbers — "Your turn" instead
//    • Esc stops everything instantly
//    • "Just do it" is capped at 15 steps, then hands control back in Walk mode
//

import AppKit
import Combine
import Foundation

// MARK: - Plan types

struct PlannedAgentStep {
    enum Action: String {
        case click
        case type
        case pressKey = "press_key"
        case scroll
        case openURL = "open_url"
        case wait
        case userInputNeeded = "user_input_needed"
        case done
        case cannotContinue = "cannot_continue"
    }

    var action: Action
    var elementID: Int?
    /// Only in vision mode: a point in the screenshot's pixel space.
    var screenshotPoint: CGPoint?
    var text: String?
    var keyName: String?
    var urlString: String?
    var narration: String
    var targetDescription: String
    var isIrreversible: Bool
    var needsVision: Bool
    var modelRoleUsed: NemotronModelRole?
    /// On a search box: type, then press Return in the same step
    /// (saves a whole planning round trip).
    var submitsAfterTyping: Bool = false
    /// Closing a cookie banner or pop-up. Never treated as irreversible and
    /// never saved into a skill (the banner may not be there next time).
    var isOverlayDismissal: Bool = false
}

/// What actually happened in a step: feeds the planner's history and skill saving.
struct CompletedAgentStep {
    let action: PlannedAgentStep.Action
    let targetRole: String?
    let targetLabel: String?
    let targetDescription: String
    let typedText: String?
    let keyName: String?
    let urlString: String?
    let narration: String
    let isIrreversible: Bool
    let wasDoneByUser: Bool
    /// Filled in on the next look: false means Saathi acted but nothing on
    /// screen changed, so the step probably didn't work.
    var screenChangedAfterStep: Bool? = nil
    var targetWasInsideOverlay: Bool = false
    var isOverlayDismissal: Bool = false
}

private struct ScreenObservation {
    let accessibilitySnapshot: AccessibilitySnapshot
    let cursorScreenCapture: CompanionScreenCapture?
    let redactedScreenshotJPEGData: Data?
}

private enum UserStepResponse {
    case continued
    case confirmed
    case declined
    case stopped
}

// MARK: - Coordinator

@MainActor
final class AgentCoordinator: ObservableObject {
    static let shared = AgentCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var statusText: String = "Ready"
    @Published var askBoxText: String = ""

    let overlayController = AgentOverlayController()
    /// The notch pill. Display only: it mirrors what the agent is doing and
    /// hosts the Next / Stop / Confirm buttons. It adds no waits or model calls.
    private var island: DynamicIslandController { DynamicIslandController.shared }
    /// Set by a type step that picked an autocomplete suggestion (the field's
    /// value afterwards), nil otherwise. Read right after the step runs.
    private var lastPickedSuggestionValue: String?

    private var currentRunTask: Task<Void, Never>?
    private var pendingUserResponseContinuation: CheckedContinuation<UserStepResponse, Never>?
    private var transientCaptionClearTask: Task<Void, Never>?

    private var escapeKeyGlobalMonitor: Any?
    private var escapeKeyLocalMonitor: Any?

    private let maximumAutonomousSteps = 15
    private let maximumTotalSteps = 30

    private init() {}

    // MARK: Lifecycle

    func start() {
        installEventMonitors()
        DynamicIslandController.shared.start()
        AccessibilityTreeReader.startTrackingExternalApplicationActivations()
        Task {
            await NemotronClient.shared.resolveModelsIfNeeded()
        }
    }

    private func installEventMonitors() {
        guard escapeKeyGlobalMonitor == nil else { return }

        // Esc stops a running task from anywhere. (Global monitors need the
        // Accessibility permission Saathi already asks for.)
        escapeKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            let isUserPressedEscape = AgentCoordinator.isEscapePressedByUser(keyEvent)
            MainActor.assumeIsolated {
                if isUserPressedEscape {
                    self?.stopEverything()
                }
            }
        }
        escapeKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            if AgentCoordinator.isEscapePressedByUser(keyEvent) {
                MainActor.assumeIsolated {
                    self?.stopEverything()
                }
            }
            return keyEvent
        }
    }

    // MARK: Entry points

    /// Voice requests: tasks go to the agent; questions go to `questionFallback`
    /// (Clicky's original explain-what's-on-screen flow).
    func handleSpokenRequest(_ transcript: String, questionFallback: @escaping () -> Void) {
        Task {
            if await classifyAsTask(transcript) {
                runTask(transcript)
            } else {
                questionFallback()
            }
        }
    }

    /// Typed requests from the Ask box always run as tasks.
    func submitAskBox() {
        let trimmedRequest = askBoxText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else { return }
        askBoxText = ""
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        runTask(trimmedRequest)
    }

    func runTask(_ taskDescription: String) {
        stopCurrentRun(reason: nil)
        let trustLevel = SaathiSettings.shared.trustLevel
        currentRunTask = Task {
            await self.executeRun(taskDescription: taskDescription, trustLevel: trustLevel)
        }
    }

    /// Esc is only a stop signal when the user pressed it. Saathi tags the
    /// key events it posts itself (e.g. pressing Escape to close a page popup),
    /// so the agent never stops its own run.
    nonisolated static func isEscapePressedByUser(_ keyEvent: NSEvent) -> Bool {
        guard keyEvent.keyCode == 53 else { return false }
        let eventSourceUserData = keyEvent.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        return eventSourceUserData != AccessibilityTreeReader.saathiSyntheticEventMarker
    }

    /// Set by CompanionManager: stops the voice Q&A side (pending answer,
    /// speech, dictation, pointing). Returns true if anything was active.
    var stopVoiceAnswerHandler: (() -> Bool)?

    /// Esc: one kill switch for everything Saathi is doing — the agent run,
    /// any pending Next/Confirm wait, narration, a voice answer being fetched
    /// or spoken, dictation, the ring and the island.
    func stopEverything() {
        let wasAgentActive = isRunning || currentRunTask != nil
        let wasVoiceAnswerActive = stopVoiceAnswerHandler?() ?? false
        let wasSpeaking = SystemSpeechTTSClient.shared.isPlaying

        if wasAgentActive {
            stopCurrentRun(reason: "Stopped. You're in control.")
            return
        }

        SystemSpeechTTSClient.shared.stopPlayback()
        resolvePendingUserResponse(.stopped)
        overlayController.overlayState.isDrivingIndicatorVisible = false

        if wasVoiceAnswerActive || wasSpeaking {
            print("⏹️ Esc: stopped voice answer")
            overlayController.clear()
            island.showMessage("Stopped")
        }
    }

    func stopCurrentRun(reason: String?) {
        guard isRunning || currentRunTask != nil else { return }
        if isRunning {
            ActionReceiptStore.shared.finishReceipt(finalOutcome: "Stopped by you")
        }
        currentRunTask?.cancel()
        currentRunTask = nil
        resolvePendingUserResponse(.stopped)
        SystemSpeechTTSClient.shared.stopPlayback()
        overlayController.overlayState.isDrivingIndicatorVisible = false
        isRunning = false
        statusText = "Stopped"
        if let reason {
            showStatusCaption(reason)
        } else {
            overlayController.clear()
            island.returnToIdle()
        }
    }

    /// Shows a caption by the mouse for a few seconds (errors, short notes).
    func showStatusCaption(_ captionText: String) {
        overlayController.present(mode: .hidden, targetFrameInAppKitCoordinates: nil, captionText: captionText, stepLabelText: nil)
        scheduleOverlayClear(afterSeconds: 6)
        island.showMessage(captionText)
    }

    /// Used by the question/answer flow: the ring wraps the element the answer
    /// refers to, snapping to its real outline when the Accessibility tree has it.
    func pointAtLocationForAnswer(globalAppKitLocation: CGPoint, elementLabel: String?, captionText: String) {
        guard !isRunning else { return }
        let snapshot = AccessibilityTreeReader.readFrontmostApplication()
        let pointInTopLeftCoordinates = AccessibilityTreeReader.convertAppKitPointToTopLeft(globalAppKitLocation)

        var targetFrame = CGRect(x: globalAppKitLocation.x - 22, y: globalAppKitLocation.y - 22, width: 44, height: 44)
        if let containingElement = smallestElement(containing: pointInTopLeftCoordinates, in: snapshot) {
            targetFrame = containingElement.frameInAppKitCoordinates
        } else if let elementLabel,
                  let labelMatchedElement = AccessibilityTreeReader.findBestMatchingElement(label: elementLabel, role: nil, in: snapshot),
                  hypot(labelMatchedElement.frameInAppKitCoordinates.midX - globalAppKitLocation.x,
                        labelMatchedElement.frameInAppKitCoordinates.midY - globalAppKitLocation.y) < 200 {
            targetFrame = labelMatchedElement.frameInAppKitCoordinates
        }

        let shortCaption = captionText.count > 160 ? String(captionText.prefix(157)) + "…" : captionText
        overlayController.present(mode: .pointing, targetFrameInAppKitCoordinates: targetFrame, captionText: shortCaption, stepLabelText: nil)
        scheduleOverlayClear(afterSeconds: 8)
    }

    private func scheduleOverlayClear(afterSeconds delayInSeconds: Double) {
        transientCaptionClearTask?.cancel()
        transientCaptionClearTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delayInSeconds * 1_000_000_000))
            guard !Task.isCancelled, !self.isRunning else { return }
            self.overlayController.clear()
        }
    }

    // MARK: Intent routing

    private func classifyAsTask(_ transcript: String) async -> Bool {
        let lowercasedTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Obvious imperatives skip the model call entirely.
        let taskOpeningWords = ["open ", "book ", "download ", "fill ", "go to ", "search ", "find ", "renew ", "apply ",
                                "pay ", "send ", "click ", "sign in", "log in", "login ", "check my ", "help me ",
                                "take me", "navigate", "start ", "create ", "upload ", "register ", "file my"]
        if taskOpeningWords.contains(where: { lowercasedTranscript.hasPrefix($0) }) {
            return true
        }

        let classificationPrompt = """
        A user spoke to a screen assistant that can either (A) perform or guide a multi-step action on their computer, or (B) answer a question about what's on screen or explain something.

        User said: "\(transcript)"

        If they want something done or want to be guided through doing it (for example "how do I download my aadhaar", "book a train to jaipur"), reply TASK. If they want information or an explanation (for example "what does this error mean", "what is this button for"), reply QUESTION. Reply with one word.
        """
        do {
            let responseText = try await NemotronClient.shared.complete(
                role: .fast,
                messages: [NemotronChatMessage(role: .user, text: classificationPrompt)],
                purpose: "Route request: task or question",
                maxTokens: SaathiConfiguration.fastCallMaxTokens,
                temperature: 0
            )
            return responseText.uppercased().contains("TASK")
        } catch {
            print("⚠️ Intent routing failed, treating as a question: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: The run

    private func executeRun(taskDescription: String, trustLevel: TrustLevel) async {
        isRunning = true
        statusText = "Working"
        let runStartDate = Date()
        print("▶️ TASK [\(trustLevel.displayName)]: \(taskDescription)")
        defer {
            print(String(format: "⏹ RUN ENDED after %.1fs", Date().timeIntervalSince(runStartDate)))
        }
        transientCaptionClearTask?.cancel()
        ActionReceiptStore.shared.beginReceipt(taskDescription: taskDescription, trustLevel: trustLevel)
        overlayController.present(mode: .thinking, targetFrameInAppKitCoordinates: nil, captionText: "On it: \(taskDescription)", stepLabelText: nil)
        island.showThinking("On it: \(taskDescription)")

        guard NemotronClient.shared.isConfigured else {
            finishRun(outcome: "Add PROVIDER_API_KEY to the .env file first.", succeeded: false)
            return
        }

        // 1. A saved skill for this kind of task?
        statusText = "Checking saved skills"
        let matchedSkill = await SkillStore.shared.findMatchingSkill(for: taskDescription)
        guard !Task.isCancelled else { return }

        // 2. Otherwise research the official steps first.
        var research: TavilyResearchResult?
        if let matchedSkill {
            ActionReceiptStore.shared.markUsedSkill(named: matchedSkill.name)
            let skillAnnouncement = "I know this one. Using your saved skill: \(matchedSkill.name)."
            overlayController.present(mode: .thinking, targetFrameInAppKitCoordinates: nil, captionText: skillAnnouncement, stepLabelText: nil)
            SystemSpeechTTSClient.shared.speak(skillAnnouncement)
        } else if TavilyClient.shared.isConfigured {
            statusText = "Looking up official steps"
            overlayController.present(mode: .thinking, targetFrameInAppKitCoordinates: nil, captionText: "Looking up the official steps…", stepLabelText: nil)
            research = await TavilyClient.shared.researchOfficialSteps(for: taskDescription)
            guard !Task.isCancelled else { return }
        }

        var completedSteps: [CompletedAgentStep] = []
        var autonomousActionCount = 0
        var nextSkillStepIndex = 0
        var hasCheckedOfficialDomain = false
        var signatureBeforeLastAction: String?
        var attemptedOverlayDismissalKeys: Set<String> = []
        var runSucceeded = false
        var finalMessage = "Stopped."

        stepLoop: for stepNumber in 1...maximumTotalSteps {
            if Task.isCancelled { return }

            // Saathi hands control back after a fixed number of actions, so a
            // run can never go on indefinitely.
            if autonomousActionCount >= maximumAutonomousSteps {
                finalMessage = "This is taking a while, so I'll stop here and hand control back to you."
                break stepLoop
            }

            statusText = "Step \(stepNumber): looking"

            let observation = await observeScreen()
            if Task.isCancelled { return }

            // Did Saathi's last action change anything? Free to check (no model
            // call), and it tells the planner when a click silently failed.
            if let signatureBeforeLastAction, let lastIndex = completedSteps.indices.last, !completedSteps[lastIndex].wasDoneByUser {
                completedSteps[lastIndex].screenChangedAfterStep = Self.screenSignature(of: observation.accessibilitySnapshot) != signatureBeforeLastAction
                print("   ↳ screen changed: \(completedSteps[lastIndex].screenChangedAfterStep == true ? "yes" : "NO")")
            }
            signatureBeforeLastAction = nil

            // Lookalike-site check, once per run.
            if !hasCheckedOfficialDomain, observation.accessibilitySnapshot.webPageURL != nil {
                hasCheckedOfficialDomain = true
                if let expectedOfficialDomain = TavilyClient.officialDomainMismatchWarning(
                    currentPageURL: observation.accessibilitySnapshot.webPageURL,
                    research: research
                ) {
                    let warningMessage = "Careful: this site doesn't match the official one I found, \(expectedOfficialDomain)."
                    SystemSpeechTTSClient.shared.speak(warningMessage)
                    overlayController.present(mode: .awaitingConfirmation, targetFrameInAppKitCoordinates: nil, captionText: warningMessage, stepLabelText: nil)
                    let warningResponse = await waitForUserResponse(
                        promptText: "This may not be the official site.",
                        buttons: [("Continue anyway", .secondary, .confirmed), ("Stop", .destructive, .declined)]
                    )
                    if warningResponse != .confirmed {
                        finalMessage = "Stopped on a site that didn't look official."
                        break stepLoop
                    }
                }
            }

            // Plan: saved skill step first, the model otherwise.
            statusText = "Step \(stepNumber): thinking"
            island.showThinking("Step \(stepNumber) · working out what's next")
            // Cookie banners and blocking pop-ups are cleared first, without a
            // model call, so later clicks don't land on the overlay.
            var plannedStep: PlannedAgentStep? = Self.overlayDismissalStep(
                for: observation.accessibilitySnapshot,
                completedSteps: completedSteps,
                attemptedKeys: &attemptedOverlayDismissalKeys
            )
            var skillHintText: String?
            if plannedStep == nil, let matchedSkill, nextSkillStepIndex < matchedSkill.steps.count {
                let savedStep = matchedSkill.steps[nextSkillStepIndex]
                plannedStep = await planFromSavedSkillStep(savedStep, taskDescription: taskDescription, observation: observation)
                if plannedStep == nil {
                    skillHintText = "The user's saved skill says the next step is: \(savedStep.narration) (target: \(savedStep.targetDescription))."
                }
                nextSkillStepIndex += 1
            }
            if plannedStep == nil {
                do {
                    plannedStep = try await planNextStep(
                        taskDescription: taskDescription,
                        observation: observation,
                        completedSteps: completedSteps,
                        research: research,
                        skillHintText: skillHintText
                    )
                } catch {
                    if Task.isCancelled { return }
                    finalMessage = error.localizedDescription
                    break stepLoop
                }
            }
            if Task.isCancelled { return }
            guard var currentStep = plannedStep else { break stepLoop }
            Self.logStepTrace(stepNumber: stepNumber, step: currentStep, snapshot: observation.accessibilitySnapshot, usedSavedSkill: skillHintText == nil && matchedSkill != nil && currentStep.modelRoleUsed != .reasoning && currentStep.modelRoleUsed != .vision)

            if currentStep.action == .done {
                runSucceeded = true
                finalMessage = currentStep.narration.isEmpty ? "All done." : currentStep.narration
                break stepLoop
            }
            if currentStep.action == .cannotContinue {
                finalMessage = currentStep.narration.isEmpty ? "I couldn't continue from here." : currentStep.narration
                break stepLoop
            }

            // Resolve the target on screen.
            let targetElement = currentStep.elementID.flatMap { observation.accessibilitySnapshot.element(withID: $0) }
            let targetFrame = targetFrameInAppKitCoordinates(for: currentStep, targetElement: targetElement, observation: observation)

            // Safety classification (enforced here regardless of what the model said).
            let targetLabelText = [targetElement?.label, currentStep.targetDescription].compactMap { $0 }.joined(separator: " ")
            let needsUserInput = currentStep.action == .userInputNeeded
                || (targetElement?.isSecureTextField ?? false)
                || (currentStep.action == .type && Self.looksLikeSecretField(targetLabelText))
                || (currentStep.action == .type && (currentStep.text ?? "").contains("{"))
            let isIrreversible = !currentStep.isOverlayDismissal
                && (currentStep.isIrreversible || (currentStep.action == .click && Self.looksIrreversible(targetLabelText)))
            currentStep.isIrreversible = isIrreversible

            let stepLabelText: String
            if let matchedSkill, stepNumber <= matchedSkill.steps.count {
                stepLabelText = "Step \(stepNumber) of \(matchedSkill.steps.count)"
            } else {
                stepLabelText = "Step \(stepNumber)"
            }

            var stepOutcome = "done"
            var stepWasDoneByUser = true

            switch trustLevel {
            case .justDoIt:
                if needsUserInput {
                    present(step: currentStep, ringMode: .yourTurn, targetFrame: targetFrame, stepLabelText: stepLabelText)
                    overlayController.overlayState.isDrivingIndicatorVisible = false
                    let yourTurnResponse = await waitForUserResponse(
                        promptText: "Your turn: type it yourself, then tap Continue.",
                        buttons: [("Continue", .primary, .continued), ("Stop", .secondary, .stopped)]
                    )
                    if yourTurnResponse == .stopped || Task.isCancelled {
                        finalMessage = "Stopped. You're in control."
                        break stepLoop
                    }
                    stepOutcome = "paused for you"
                    break
                }

                if isIrreversible {
                    present(step: currentStep, ringMode: .awaitingConfirmation, targetFrame: targetFrame, stepLabelText: stepLabelText)
                    overlayController.overlayState.isDrivingIndicatorVisible = false
                    let confirmationResponse = await waitForUserResponse(
                        promptText: "This can't be undone. Go ahead?",
                        buttons: [("Yes, go ahead", .primary, .confirmed), ("Stop", .destructive, .declined)]
                    )
                    if confirmationResponse != .confirmed || Task.isCancelled {
                        finalMessage = "Okay, I stopped before that step."
                        break stepLoop
                    }
                    stepOutcome = "you confirmed"
                }

                overlayController.overlayState.isDrivingIndicatorVisible = true
                present(step: currentStep, ringMode: .justDoIt, targetFrame: targetFrame, stepLabelText: stepLabelText)
                statusText = "Step \(stepNumber): doing it"
                // Let the ring arrive before acting, so the user can follow along.
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                if Task.isCancelled { return }

                AccessibilityTreeReader.activateTargetApplicationIfNeeded()
                let signatureBeforeAction = Self.screenSignature(of: observation.accessibilitySnapshot)
                lastPickedSuggestionValue = nil
                let willPressEnterAfterTyping = currentStep.action == .type
                    && currentStep.submitsAfterTyping
                    && (targetElement.map(Self.looksLikeSearchField) ?? false)
                signatureBeforeLastAction = signatureBeforeAction
                await perform(step: currentStep, targetElement: targetElement, observation: observation)
                overlayController.playPressAnimation()
                autonomousActionCount += 1
                stepWasDoneByUser = false
                if stepOutcome == "done" { stepOutcome = "done by \(SaathiConfiguration.productName)" }
                // Let the page update before looking again.
                // Pages need longer after navigation, and suggestion lists take a
                // moment to appear after typing.
                // Never waits longer than before; moves on early once the
                // screen has changed and stopped changing.
                switch currentStep.action {
                case .type where !willPressEnterAfterTyping && lastPickedSuggestionValue == nil:
                    // Suggestion lists appear late, so typing keeps a fixed wait.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                case .openURL, .type:
                    await waitForScreenToSettle(changedFrom: signatureBeforeAction, minimumSeconds: 1.0, maximumSeconds: 3.0)
                default:
                    await waitForScreenToSettle(changedFrom: signatureBeforeAction, minimumSeconds: 0.5, maximumSeconds: 1.5)
                }
            }

            if Task.isCancelled { return }

            ActionReceiptStore.shared.appendStep(
                summary: currentStep.narration,
                modelRoleUsed: currentStep.modelRoleUsed,
                screenshotJPEGData: observation.redactedScreenshotJPEGData,
                outcome: stepOutcome
            )
            completedSteps.append(CompletedAgentStep(
                action: needsUserInput && currentStep.action == .type ? .userInputNeeded : currentStep.action,
                targetRole: targetElement?.role,
                targetLabel: targetElement?.label,
                targetDescription: currentStep.targetDescription,
                typedText: needsUserInput ? nil : currentStep.text,
                keyName: (currentStep.action == .type && lastPickedSuggestionValue != nil && !stepWasDoneByUser) ? "suggestion" : (currentStep.action == .type && currentStep.submitsAfterTyping && (targetElement.map(Self.looksLikeSearchField) ?? false) && !stepWasDoneByUser) ? "return" : currentStep.keyName,
                urlString: currentStep.urlString,
                narration: currentStep.narration,
                isIrreversible: currentStep.isIrreversible,
                wasDoneByUser: stepWasDoneByUser,
                targetWasInsideOverlay: targetElement?.isInsideOverlay ?? false,
                isOverlayDismissal: currentStep.isOverlayDismissal
            ))
        }

        if Task.isCancelled { return }
        overlayController.overlayState.isDrivingIndicatorVisible = false

        if runSucceeded {
            if let matchedSkill {
                SkillStore.shared.recordReplay(of: matchedSkill)
            } else if !completedSteps.isEmpty {
                await offerToSaveSkill(taskDescription: taskDescription, completedSteps: completedSteps, observationAppName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
            }
        }

        finishRun(outcome: finalMessage, succeeded: runSucceeded)
    }

    private func finishRun(outcome: String, succeeded: Bool) {
        print("\(succeeded ? "✅ SUCCEEDED" : "❌ DID NOT FINISH"): \(outcome)")
        ActionReceiptStore.shared.finishReceipt(finalOutcome: outcome)
        overlayController.overlayState.isDrivingIndicatorVisible = false
        isRunning = false
        currentRunTask = nil
        statusText = succeeded ? "Done" : "Stopped"
        SystemSpeechTTSClient.shared.speak(outcome)
        showStatusCaption(outcome)
    }

    private func present(step: PlannedAgentStep, ringMode: RingPresentationMode, targetFrame: CGRect?, stepLabelText: String) {
        overlayController.present(
            mode: ringMode,
            targetFrameInAppKitCoordinates: targetFrame,
            captionText: step.narration,
            stepLabelText: stepLabelText
        )
        island.showRunning(stepLabelText: stepLabelText, narration: step.narration)
        SystemSpeechTTSClient.shared.speak(step.narration)
    }

    // MARK: Waiting for the user

    private func waitForUserResponse(
        promptText: String,
        buttons: [(title: String, style: AgentControlButtonDescriptor.Style, response: UserStepResponse)]
    ) async -> UserStepResponse {
        resolvePendingUserResponse(.stopped)

        let buttonDescriptors = buttons.map { buttonSpecification in
            AgentControlButtonDescriptor(title: buttonSpecification.title, style: buttonSpecification.style) { [weak self] in
                self?.resolvePendingUserResponse(buttonSpecification.response)
            }
        }
        let isConfirmation = buttons.contains { $0.style == .destructive }
        island.showWaiting(
            titleText: isConfirmation ? "Confirm" : "Your move",
            detailText: promptText,
            buttons: buttonDescriptors,
            isWarning: isConfirmation
        )

        let userResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UserStepResponse, Never>) in
                self.pendingUserResponseContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                AgentCoordinator.shared.resolvePendingUserResponse(.stopped)
            }
        }

        if userResponse != .stopped {
            island.showThinking("Okay")
        }
        return userResponse
    }

    private func resolvePendingUserResponse(_ userResponse: UserStepResponse) {
        guard let pendingUserResponseContinuation else { return }
        self.pendingUserResponseContinuation = nil
        pendingUserResponseContinuation.resume(returning: userResponse)
    }

    // MARK: Observing the screen

    private func observeScreen() async -> ScreenObservation {
        let accessibilitySnapshot = AccessibilityTreeReader.readFrontmostApplication()

        let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
        guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else {
            return ScreenObservation(accessibilitySnapshot: accessibilitySnapshot, cursorScreenCapture: nil, redactedScreenshotJPEGData: nil)
        }

        // Privacy shield: black out password fields and ID/card numbers before
        // the screenshot is used anywhere.
        let passwordFieldRectsInImagePixels = accessibilitySnapshot.elements
            .filter(\.isSecureTextField)
            .map { secureElement in
                PrivacyShield.convertAppKitRectToImagePixels(
                    secureElement.frameInAppKitCoordinates,
                    displayFrame: cursorScreenCapture.displayFrame,
                    imageWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    imageHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                )
            }
        let originalScreenshotJPEGData = cursorScreenCapture.imageData
        let privacyShieldResult = await Task.detached(priority: .userInitiated) {
            PrivacyShield.redact(
                screenshotJPEGData: originalScreenshotJPEGData,
                additionalRedactionRectsInImagePixels: passwordFieldRectsInImagePixels
            )
        }.value
        if privacyShieldResult.redactedRegionCount > 0 {
            print("🛡️ Privacy shield redacted \(privacyShieldResult.redactedRegionCount) region(s)")
        }

        return ScreenObservation(
            accessibilitySnapshot: accessibilitySnapshot,
            cursorScreenCapture: cursorScreenCapture,
            redactedScreenshotJPEGData: privacyShieldResult.redactedJPEGData
        )
    }

    // MARK: Planning

    private static let plannerSystemPrompt = """
    You are Saathi, a careful assistant that operates a Mac for the user, one step at a time, like a patient friend sitting next to them. Many users are not technical (for example parents using Indian government, banking or travel websites).

    Each turn you get: the user's task, the frontmost app, the page URL, a numbered list of on-screen elements, and the steps already done. Decide the single next step.

    Reply with ONLY one JSON object, no other text:
    {"action": "click|type|press_key|scroll|open_url|wait|user_input_needed|done|cannot_continue",
     "element_id": <number from the list or null>,
     "text": "<text to type, for type>",
     "key": "<return|tab|escape|down|up|pagedown>",
     "url": "<https url, for open_url>",
     "target_description": "<plain description of the target, e.g. 'Login button, top right'>",
     "narration": "<one short friendly sentence telling the user what this step does>",
     "irreversible": <true|false>,
     "needs_vision": <true|false>,
     "submit": <true|false>}

    Rules:
    - One step only. Prefer element_id from the list. Never invent an element_id.
    - If the right website isn't open, use open_url with the official https URL (prefer URLs from the research, never lookalike sites).
    - If the task names a website (YouTube, Gmail, IRCTC, a government portal…), go there directly with open_url using its official https address. Don't search for it in a search engine.
    - Search boxes: set "submit": true on the type step to type and press Enter in one go. Never use submit on autocomplete fields (cities, airports, stations) or forms.
    - Read "Steps already done" carefully. Never redo a finished step, and don't retype a field that already shows the right value.
    - A step marked "(nothing changed on screen)" did not work. Don't repeat it: pick a different element, close what's blocking, scroll, or use another route.
    - Click the most specific element (the link or button itself, not the area around it).
    - The element list only shows what is visible on screen. If what you need isn't there (a Continue or Submit button, the next form field, more results), use scroll with key "down" (or "up") to find it before trying anything else or giving up.
    - The moment the screen shows what the user asked for, use done.
    - Never invent personal details. If a field needs a password, OTP, PIN, CVV, captcha, card number, Aadhaar/PAN/passport number, or any personal value the user did not state in the task, use user_input_needed on that field.
    - Only type values the user actually gave in the task (like a city or a date).
    - irreversible is true for steps that pay, submit, send, confirm, place an order, book, transfer, or delete.
    - Web forms, step by step:
      • Autocomplete fields (cities, airports, stations, addresses): just type the value. Saathi then picks the top suggestion automatically (history says "picked the top suggestion"). Check the field's value: if it shows the right place, move on; if it's wrong or empty, click the field, and click the right option in the list (marked "option in open list", or visible in the screenshot).
      • Before moving to the next field, check the field shows the chosen value (see value="…"). If it doesn't, select the suggestion again.
      • Date fields: click the field to open the calendar, move to the right month if needed, then click the day.
      • Dropdowns (popup buttons): click to open, then click the option.
      • Pop-ups: elements marked (in pop-up) are in a dialog or banner on top of the page. If one that isn't part of the task is open (cookies, newsletter, app download, notifications, sign-in nag), close it first: prefer "Reject all", "Necessary only", "Close", "No thanks" or "×"; if there's no close button, press_key "escape". Never click page elements behind an open pop-up. Don't close a pop-up that IS the task (a form, date picker or window you opened).
      • Fill fields top to bottom, then press the search or continue button.
    - Use done when the task is finished or the page shows the result; the narration then says what was achieved.
    - Use cannot_continue if blocked (for example the site is down); the narration explains why.
    - If the element list is empty or clearly missing what you need (canvas apps, images), set needs_vision true and action wait.
    """

    private func planNextStep(
        taskDescription: String,
        observation: ScreenObservation,
        completedSteps: [CompletedAgentStep],
        research: TavilyResearchResult?,
        skillHintText: String?
    ) async throws -> PlannedAgentStep {
        let languageInstruction = SaathiSettings.shared.narrationLanguage.promptInstruction
        let historyText = completedSteps.isEmpty
            ? "(none yet)"
            : completedSteps.enumerated().map { stepIndex, completedStep in
                let pressedEnterNote: String
                if completedStep.action == .type && completedStep.keyName == "return" {
                    pressedEnterNote = " then pressed Enter"
                } else if completedStep.action == .type && completedStep.keyName == "suggestion" {
                    pressedEnterNote = " then picked the top suggestion (check the field's value)"
                } else {
                    pressedEnterNote = ""
                }
                let typedValueNote = (completedStep.typedText.map { " typed \"\($0)\"" } ?? "") + pressedEnterNote
                let noChangeNote = completedStep.screenChangedAfterStep == false ? " (nothing changed on screen)" : ""
                return "\(stepIndex + 1). \(completedStep.narration) [\(completedStep.action.rawValue)\(typedValueNote) → \(completedStep.targetDescription)]\(noChangeNote)"
            }.joined(separator: "\n")

        let snapshot = observation.accessibilitySnapshot
        var contextSections = [
            "Task: \(taskDescription)",
            "Frontmost app: \(snapshot.applicationName). Window: \(snapshot.windowTitle)",
            "Page URL: \(snapshot.webPageURL?.absoluteString ?? "n/a")",
            "Steps already done:\n\(historyText)"
        ]
        if let research {
            contextSections.append(research.promptText)
        }
        if let skillHintText {
            contextSections.append(skillHintText)
        }

        // When to look at the screen instead of only reading the element list:
        //  • right after typing — autocomplete dropdowns and pickers pop up,
        //    and seeing them is far more reliable than reading their markup
        //  • when stuck — the last two steps did the same thing to the same target
        //  • when the app exposes too few elements (canvas apps, images)
        let hasUsableAccessibilityTree = snapshot.elements.count >= 3
        let lastCompletedStep = completedSteps.last
        // A picked suggestion doesn't need a look at the screen: the field's
        // value in the element list shows whether the right one was chosen.
        let justTyped = lastCompletedStep?.action == .type && lastCompletedStep?.keyName != "suggestion"
        let isRepeatingItself: Bool = {
            guard completedSteps.count >= 2 else { return false }
            let previousStep = completedSteps[completedSteps.count - 2]
            return previousStep.action == lastCompletedStep?.action
                && previousStep.targetDescription == lastCompletedStep?.targetDescription
        }()
        let shouldLookAtScreen = !hasUsableAccessibilityTree || justTyped || isRepeatingItself
        let canLookAtScreen = observation.redactedScreenshotJPEGData != nil && observation.cursorScreenCapture != nil

        if snapshot.elements.contains(where: \.isInsideOverlay) {
            contextSections.append("A pop-up is open on top of the page (elements marked \"(in pop-up)\").")
        }
        if isRepeatingItself {
            contextSections.append("Warning: the last two steps did the same thing, so it probably didn't work. Look carefully at the screen and try a different approach.")
        }

        // Text planning on the element list (Nemotron Super).
        if hasUsableAccessibilityTree && !(shouldLookAtScreen && canLookAtScreen) {
            let textPlannerUserMessage = (contextSections + ["On-screen elements:\n\(snapshot.promptText)", languageInstruction]).joined(separator: "\n\n")
            let responseText = try await NemotronClient.shared.complete(
                role: .reasoning,
                messages: [
                    NemotronChatMessage(role: .system, text: Self.plannerSystemPrompt),
                    NemotronChatMessage(role: .user, text: textPlannerUserMessage)
                ],
                purpose: "Plan next step from element list",
                maxTokens: 1600,
                temperature: 0.1
            )
            if var parsedStep = Self.parsePlannedStep(from: responseText) {
                parsedStep.modelRoleUsed = .reasoning
                if !parsedStep.needsVision {
                    return parsedStep
                }
            }
        }

        // Vision planning (Nemotron Omni): the screenshot plus the element list,
        // so it can see the dropdown and still target real elements by ID.
        guard let screenshotJPEGData = observation.redactedScreenshotJPEGData,
              let cursorScreenCapture = observation.cursorScreenCapture else {
            throw NemotronClientError(message: "I couldn't see the screen. Check the Screen Recording permission.")
        }

        let elementListSection = hasUsableAccessibilityTree
            ? "On-screen elements (prefer these IDs when the target is listed):\n\(snapshot.promptText)"
            : "No element list is available for this app."
        let visionInstructions = """
        You can also see a screenshot of the screen. It is \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels (origin top-left). Black boxes are redacted private data.
        Use the same JSON. Give element_id when the target is in the element list; otherwise give "x" and "y": the integer pixel coordinates of the target's center in the screenshot. Set needs_vision false.
        """
        let visionPlannerUserMessage = (contextSections + [elementListSection, visionInstructions, languageInstruction]).joined(separator: "\n\n")
        let visionResponseText = try await NemotronClient.shared.complete(
            role: .vision,
            messages: [
                NemotronChatMessage(role: .system, text: Self.plannerSystemPrompt),
                NemotronChatMessage(role: .user, text: visionPlannerUserMessage, imageJPEGDataList: [screenshotJPEGData])
            ],
            purpose: justTyped ? "Plan next step after typing (looking for suggestions)" : "Plan next step from screenshot",
            maxTokens: 1600,
            temperature: 0.1
        )
        guard var visionStep = Self.parsePlannedStep(from: visionResponseText) else {
            throw NemotronClientError(message: "The model's reply didn't make sense, so I stopped to be safe.")
        }
        visionStep.modelRoleUsed = .vision
        // Keep an element ID only if it really exists; otherwise fall back to x/y.
        if let plannedElementID = visionStep.elementID, snapshot.element(withID: plannedElementID) == nil {
            visionStep.elementID = nil
        }
        return visionStep
    }

    private static func parsePlannedStep(from responseText: String) -> PlannedAgentStep? {
        guard let stepJSON = NemotronClient.extractFirstJSONObject(from: responseText),
              let actionName = stepJSON["action"] as? String,
              let action = PlannedAgentStep.Action(rawValue: actionName.lowercased()) else {
            print("⚠️ Planner reply not parsable: \(responseText.prefix(300))")
            return nil
        }

        func integerValue(_ key: String) -> Int? {
            if let intValue = stepJSON[key] as? Int { return intValue }
            if let doubleValue = stepJSON[key] as? Double { return Int(doubleValue) }
            if let stringValue = stepJSON[key] as? String { return Int(stringValue) }
            return nil
        }
        func nonEmptyString(_ key: String) -> String? {
            guard let stringValue = stepJSON[key] as? String else { return nil }
            let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }

        var screenshotPoint: CGPoint?
        if let xCoordinate = integerValue("x"), let yCoordinate = integerValue("y") {
            screenshotPoint = CGPoint(x: xCoordinate, y: yCoordinate)
        }

        return PlannedAgentStep(
            action: action,
            elementID: integerValue("element_id"),
            screenshotPoint: screenshotPoint,
            text: stepJSON["text"] as? String,
            keyName: nonEmptyString("key"),
            urlString: nonEmptyString("url"),
            narration: nonEmptyString("narration") ?? "",
            targetDescription: nonEmptyString("target_description") ?? "",
            isIrreversible: stepJSON["irreversible"] as? Bool ?? false,
            needsVision: stepJSON["needs_vision"] as? Bool ?? false,
            modelRoleUsed: nil,
            submitsAfterTyping: stepJSON["submit"] as? Bool ?? false
        )
    }

    // MARK: Skill replay

    /// Turns a saved skill step into a plan without a big-model call when the
    /// target can be found by its label. Returns nil when it can't be found,
    /// so the planner takes over with the skill step as a hint (self-healing).
    private func planFromSavedSkillStep(
        _ savedStep: SavedSkillStep,
        taskDescription: String,
        observation: ScreenObservation
    ) async -> PlannedAgentStep? {
        guard let action = PlannedAgentStep.Action(rawValue: savedStep.action) else { return nil }
        let snapshot = observation.accessibilitySnapshot

        var replayedStep = PlannedAgentStep(
            action: action,
            elementID: nil,
            screenshotPoint: nil,
            text: nil,
            keyName: savedStep.keyName,
            urlString: savedStep.urlString,
            narration: savedStep.narration,
            targetDescription: savedStep.targetDescription,
            isIrreversible: savedStep.isIrreversible,
            needsVision: false,
            modelRoleUsed: nil,
            // A saved "type then Enter" search step replays the same way.
            submitsAfterTyping: action == .type && savedStep.keyName == "return"
        )

        switch action {
        case .openURL, .pressKey, .scroll, .wait:
            return replayedStep
        case .done, .cannotContinue:
            return nil
        case .click, .type, .userInputNeeded:
            guard let savedTargetLabel = savedStep.targetLabel,
                  let matchedElement = AccessibilityTreeReader.findBestMatchingElement(label: savedTargetLabel, role: savedStep.targetRole, in: snapshot) else {
                return nil
            }
            replayedStep.elementID = matchedElement.id

            if action == .type {
                if let textTemplate = savedStep.textTemplate, textTemplate.contains("{") {
                    // Placeholder: fill it from the new request if the user said it,
                    // otherwise it becomes the user's turn.
                    if let filledValue = await fillPlaceholderFromRequest(fieldDescription: savedStep.targetDescription, taskDescription: taskDescription, isSensitiveField: Self.looksLikeSecretField(savedTargetLabel)) {
                        replayedStep.text = filledValue
                        replayedStep.modelRoleUsed = .fast
                    } else {
                        replayedStep.action = .userInputNeeded
                    }
                } else {
                    replayedStep.text = savedStep.textTemplate
                }
            }
            return replayedStep
        }
    }

    private func fillPlaceholderFromRequest(fieldDescription: String, taskDescription: String, isSensitiveField: Bool) async -> String? {
        guard !isSensitiveField else { return nil }
        let fillPrompt = """
        Request: "\(taskDescription)"
        Form field: "\(fieldDescription)"
        If the request clearly states the value for this field, reply with only that value. Otherwise reply NONE.
        """
        guard let responseText = try? await NemotronClient.shared.complete(
            role: .fast,
            messages: [NemotronChatMessage(role: .user, text: fillPrompt)],
            purpose: "Fill skill field from request",
            maxTokens: SaathiConfiguration.fastCallMaxTokens,
            temperature: 0
        ) else {
            return nil
        }
        let filledValue = responseText.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if filledValue.isEmpty || filledValue.uppercased() == "NONE" || filledValue.count > 80 {
            return nil
        }
        return filledValue
    }

    // MARK: Saving a skill

    private func offerToSaveSkill(taskDescription: String, completedSteps: [CompletedAgentStep], observationAppName: String) async {
        let promptText = "Save this as a skill? Next time it'll be instant."
        overlayController.present(mode: .hidden, targetFrameInAppKitCoordinates: nil, captionText: promptText, stepLabelText: nil)
        let saveResponse = await waitForUserResponse(
            promptText: promptText,
            buttons: [("Save skill", .primary, .confirmed), ("No thanks", .secondary, .declined)]
        )
        guard saveResponse == .confirmed else { return }

        var skillName = String(taskDescription.prefix(48))
        var skillTriggerDescription = taskDescription
        let namingPrompt = """
        A user asked a screen assistant: "\(taskDescription)". Name this as a reusable skill.
        Reply with ONLY JSON: {"name": "<3-6 word general name, no personal details>", "trigger": "<one line: what kind of request this skill handles>"}
        """
        if let namingResponse = try? await NemotronClient.shared.complete(
            role: .fast,
            messages: [NemotronChatMessage(role: .user, text: namingPrompt)],
            purpose: "Name the new skill",
            maxTokens: SaathiConfiguration.fastCallMaxTokens,
            temperature: 0.2
        ), let namingJSON = NemotronClient.extractFirstJSONObject(from: namingResponse) {
            if let generatedName = namingJSON["name"] as? String, !generatedName.isEmpty { skillName = generatedName }
            if let generatedTrigger = namingJSON["trigger"] as? String, !generatedTrigger.isEmpty { skillTriggerDescription = generatedTrigger }
        }

        let savedSteps = completedSteps.filter { !$0.isOverlayDismissal }.map { completedStep -> SavedSkillStep in
            // Typed values are stored only as a placeholder named after the field,
            // so personal data never lands in a skill file.
            let textTemplate: String? = completedStep.action == .type || completedStep.action == .userInputNeeded
                ? "{\(Self.placeholderName(for: completedStep.targetLabel ?? completedStep.targetDescription))}"
                : nil
            return SavedSkillStep(
                action: completedStep.action == .userInputNeeded ? PlannedAgentStep.Action.type.rawValue : completedStep.action.rawValue,
                targetRole: completedStep.targetRole,
                targetLabel: completedStep.targetLabel,
                targetDescription: completedStep.targetDescription,
                textTemplate: textTemplate,
                keyName: completedStep.keyName,
                // Keep only the site and page, not the query: a URL like
                // youtube.com/results?search_query=lofi would replay the old search.
                urlString: completedStep.urlString.map(Self.urlWithoutQuery),
                narration: completedStep.narration,
                isIrreversible: completedStep.isIrreversible
            )
        }

        let firstOpenedURLString = completedSteps.first(where: { $0.action == .openURL })?.urlString
        SkillStore.shared.save(SavedSkill(
            id: UUID(),
            name: skillName,
            triggerDescription: skillTriggerDescription,
            applicationName: observationAppName,
            startURLString: firstOpenedURLString,
            steps: savedSteps,
            createdDate: Date(),
            timesReplayed: 0
        ))
        SystemSpeechTTSClient.shared.speak("Saved. Next time I'll know this one.")
    }

    private static func urlWithoutQuery(_ urlString: String) -> String {
        guard var urlComponents = URLComponents(string: urlString) else { return urlString }
        // Only the site itself: paths like /channel/<id> or /results are
        // specific to the request the skill was saved from.
        urlComponents.query = nil
        urlComponents.fragment = nil
        urlComponents.path = "/"
        return urlComponents.string ?? urlString
    }

    private static func placeholderName(for fieldLabel: String) -> String {
        let lowercasedWords = fieldLabel.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        return lowercasedWords.isEmpty ? "value" : lowercasedWords.joined(separator: "_")
    }

    // MARK: Acting

    private func perform(step: PlannedAgentStep, targetElement: AccessibleScreenElement?, observation: ScreenObservation) async {
        switch step.action {
        case .click:
            if let targetElement {
                AccessibilityTreeReader.press(targetElement)
            } else if let clickPoint = topLeftPointForVisionStep(step, observation: observation) {
                AccessibilityTreeReader.clickAtTopLeftPoint(clickPoint)
            }
        case .type:
            let textToType = step.text ?? ""
            guard !textToType.isEmpty else { return }
            if let targetElement {
                await AccessibilityTreeReader.focusAndType(textToType, into: targetElement)
                if step.submitsAfterTyping && Self.looksLikeSearchField(targetElement) && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if !Task.isCancelled { AccessibilityTreeReader.pressNamedKey("return") }
                } else if !Task.isCancelled {
                    // Autocomplete field: pick the top suggestion now, so the
                    // value is really selected (typing alone doesn't select it).
                    lastPickedSuggestionValue = await AccessibilityTreeReader.pickTopSuggestionIfAutocompleteOpened(afterTyping: textToType, into: targetElement)
                }
            } else if let clickPoint = topLeftPointForVisionStep(step, observation: observation) {
                AccessibilityTreeReader.clickAtTopLeftPoint(clickPoint)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await AccessibilityTreeReader.typeText(textToType)
            } else {
                await AccessibilityTreeReader.typeText(textToType)
            }
        case .pressKey:
            AccessibilityTreeReader.pressNamedKey(step.keyName ?? "return")
        case .scroll:
            let scrollsUp = (step.keyName ?? step.text ?? "").lowercased().contains("up")
            AccessibilityTreeReader.scroll(downByLines: scrollsUp ? -8 : 8)
        case .openURL:
            if let urlString = step.urlString, let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" {
                await AccessibilityTreeReader.openURLInUsersBrowser(url)
            }
        case .wait, .userInputNeeded, .done, .cannotContinue:
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: Geometry

    private func targetFrameInAppKitCoordinates(
        for step: PlannedAgentStep,
        targetElement: AccessibleScreenElement?,
        observation: ScreenObservation
    ) -> CGRect? {
        if let targetElement {
            return targetElement.frameInAppKitCoordinates
        }
        guard let topLeftPoint = topLeftPointForVisionStep(step, observation: observation) else {
            return nil
        }
        // Snap a vision-model point to the real element under it when possible.
        if let containingElement = smallestElement(containing: topLeftPoint, in: observation.accessibilitySnapshot) {
            return containingElement.frameInAppKitCoordinates
        }
        let pointRectInTopLeftCoordinates = CGRect(x: topLeftPoint.x - 22, y: topLeftPoint.y - 22, width: 44, height: 44)
        return AccessibilityTreeReader.convertBetweenTopLeftAndAppKit(pointRectInTopLeftCoordinates)
    }

    /// Converts a vision step's screenshot-pixel point to global top-left coordinates.
    private func topLeftPointForVisionStep(_ step: PlannedAgentStep, observation: ScreenObservation) -> CGPoint? {
        guard let screenshotPoint = step.screenshotPoint, let capture = observation.cursorScreenCapture else {
            return nil
        }
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))
        let displayLocalX = clampedX * (capture.displayFrame.width / screenshotWidth)
        let displayLocalY = clampedY * (capture.displayFrame.height / screenshotHeight)
        let appKitPoint = CGPoint(
            x: capture.displayFrame.minX + displayLocalX,
            y: capture.displayFrame.maxY - displayLocalY
        )
        return AccessibilityTreeReader.convertAppKitPointToTopLeft(appKitPoint)
    }

    private func smallestElement(containing pointInTopLeftCoordinates: CGPoint, in snapshot: AccessibilitySnapshot) -> AccessibleScreenElement? {
        snapshot.elements
            .filter { $0.frameInTopLeftCoordinates.insetBy(dx: -4, dy: -4).contains(pointInTopLeftCoordinates) }
            .min { firstElement, secondElement in
                firstElement.frameInTopLeftCoordinates.width * firstElement.frameInTopLeftCoordinates.height
                    < secondElement.frameInTopLeftCoordinates.width * secondElement.frameInTopLeftCoordinates.height
            }
    }

    // MARK: Safety heuristics

    /// Enter is only pressed automatically on a search box, never on a form
    /// field, so "submit" can't send or pay for anything.
    static func looksLikeSearchField(_ element: AccessibleScreenElement) -> Bool {
        let labelText = element.label.lowercased()
        return labelText.contains("search") || labelText.contains("खोज") || element.role == "AXSearchField"
    }

    /// A cheap fingerprint of what's on screen, to tell whether an action changed anything.
    static func screenSignature(of snapshot: AccessibilitySnapshot) -> String {
        let elementSummary = snapshot.elements.prefix(150).map { element in
            "\(element.role)|\(element.label)|\(element.currentValue ?? "")|\(element.isPopupOption)"
        }.joined(separator: ";")
        return "\(snapshot.webPageURL?.absoluteString ?? "")#\(snapshot.windowTitle)#\(snapshot.elements.count)#\(elementSummary)"
    }

    /// Waits until the screen has changed and then held still, capped at the
    /// old fixed wait. Esc cancels it at once.
    private func waitForScreenToSettle(changedFrom signatureBeforeAction: String, minimumSeconds: Double, maximumSeconds: Double) async {
        let startTime = Date()
        try? await Task.sleep(nanoseconds: UInt64(minimumSeconds * 1_000_000_000))
        var previousSignature: String?
        while !Task.isCancelled && Date().timeIntervalSince(startTime) < maximumSeconds {
            let currentSignature = Self.screenSignature(of: AccessibilityTreeReader.readFrontmostApplication())
            if currentSignature != signatureBeforeAction && currentSignature == previousSignature {
                return
            }
            previousSignature = currentSignature
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: Test trace

    /// One line per step in the log, so a failed run can be diagnosed
    /// afterwards. Typed text is logged by length only (it may be personal).
    private static func logStepTrace(stepNumber: Int, step: PlannedAgentStep, snapshot: AccessibilitySnapshot, usedSavedSkill: Bool) {
        let targetElement = step.elementID.flatMap { snapshot.element(withID: $0) }
        let targetText: String
        if let targetElement {
            targetText = "#\(targetElement.id) \(targetElement.role.replacingOccurrences(of: "AX", with: "")) \"\(targetElement.label.prefix(50))\"\(targetElement.isInsideOverlay ? " (in pop-up)" : "")"
        } else if let screenshotPoint = step.screenshotPoint {
            targetText = "vision point (\(Int(screenshotPoint.x)),\(Int(screenshotPoint.y)))"
        } else {
            targetText = step.targetDescription.isEmpty ? "-" : step.targetDescription
        }
        var detailText = ""
        if let typedText = step.text, step.action == .type { detailText += " typed \(typedText.count) chars\(step.submitsAfterTyping ? " + Enter" : "")" }
        if let keyName = step.keyName, step.action != .type { detailText += " key=\(keyName)" }
        if let urlString = step.urlString { detailText += " url=\(urlString)" }
        let sourceText: String
        if step.isOverlayDismissal { sourceText = "overlay rule" }
        else if usedSavedSkill { sourceText = "saved skill" }
        else { sourceText = step.modelRoleUsed?.rawValue ?? "rule" }
        print("🧭 STEP \(stepNumber) [\(sourceText)] \(step.action.rawValue) → \(targetText)\(detailText)\(step.isIrreversible ? " ⚠️irreversible" : "") | page: \(snapshot.webPageURL?.host ?? snapshot.applicationName), \(snapshot.elements.count) elements | \"\(step.narration.prefix(90))\"")
    }

    // MARK: Pop-ups and cookie banners

    private static let strongCookieRejectLabels: Set<String> = [
        "reject all", "reject all cookies", "reject optional cookies", "reject non-essential cookies",
        "reject additional cookies", "decline all", "decline optional cookies", "deny all", "refuse all",
        "only necessary", "necessary only", "only necessary cookies", "necessary cookies only",
        "use necessary cookies only", "allow necessary cookies only", "accept necessary cookies only",
        "accept only necessary", "accept only necessary cookies", "accept only essential cookies",
        "essential cookies only", "only essential cookies", "continue without accepting"
    ]
    private static let strongCookieAcceptLabels: Set<String> = [
        "accept all", "accept all cookies", "accept cookies", "allow all", "allow all cookies", "allow cookies",
        "accept & close", "accept and close", "agree and close", "agree & close", "accept and continue",
        "i accept cookies", "accept all & close", "accept all and close"
    ]
    /// Too generic on their own; only used when the page clearly has a cookie notice.
    private static let weakCookieRejectLabels: Set<String> = ["reject", "decline", "deny"]
    private static let weakCookieAcceptLabels: Set<String> = ["accept", "i accept", "agree", "i agree", "ok", "okay", "got it", "allow"]
    /// Close buttons on generic pop-ups (newsletters, app banners, sign-in nags).
    private static let overlayCloseLabels: Set<String> = [
        "close", "×", "✕", "✖", "x", "dismiss", "no thanks", "no, thanks", "not now", "maybe later", "later",
        "skip", "close dialog", "close modal", "close popup", "close pop-up", "close banner", "close this dialog",
        "close window", "बंद करें"
    ]

    private static func normalizedButtonLabel(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
    }

    /// Picks a step that clears what's covering the page, with no model call:
    ///  1. a cookie notice: decline optional cookies if possible, else accept;
    ///  2. a pop-up that just blocked a click (Saathi clicked behind it and
    ///     nothing changed): its close button, or Escape.
    /// Each button is tried once, so this can never loop.
    private static func overlayDismissalStep(
        for snapshot: AccessibilitySnapshot,
        completedSteps: [CompletedAgentStep],
        attemptedKeys: inout Set<String>
    ) -> PlannedAgentStep? {
        guard snapshot.webPageURL != nil else { return nil }
        let pageHost = snapshot.webPageURL?.host ?? ""
        let candidateElements = snapshot.elements.filter { $0.isEnabled && !$0.isTextInput }

        let pageHasCookieNotice = snapshot.elements.contains { element in
            let labelText = element.label.lowercased()
            return labelText.contains("cookie") || labelText.contains("consent")
                || labelText.contains("manage preferences") || labelText.contains("manage options")
                || labelText.contains("privacy settings")
        }

        func firstUntried(_ isMatch: (AccessibleScreenElement, String) -> Bool) -> AccessibleScreenElement? {
            candidateElements.first { element in
                let normalizedLabel = normalizedButtonLabel(element.label)
                return isMatch(element, normalizedLabel) && !attemptedKeys.contains("\(pageHost)|\(normalizedLabel)")
            }
        }

        // Bare labels like "Accept all" also appear in other places (e.g. a
        // document editor), so they count only next to a cookie notice or
        // inside a pop-up. Labels that say "cookie" or "necessary" always count.
        func isCookieBannerButton(_ element: AccessibleScreenElement, _ normalizedLabel: String, in labelSet: Set<String>) -> Bool {
            guard labelSet.contains(normalizedLabel) else { return false }
            let isSelfDescribing = normalizedLabel.contains("cookie") || normalizedLabel.contains("necessary")
                || normalizedLabel.contains("essential") || normalizedLabel.contains("without accepting")
            return isSelfDescribing || pageHasCookieNotice || element.isInsideOverlay
        }

        func dismissalStep(clicking element: AccessibleScreenElement, narration: String, targetDescription: String) -> PlannedAgentStep {
            attemptedKeys.insert("\(pageHost)|\(normalizedButtonLabel(element.label))")
            print("🍪 Clearing overlay: \"\(element.label)\"")
            return PlannedAgentStep(
                action: .click, elementID: element.id, screenshotPoint: nil, text: nil, keyName: nil, urlString: nil,
                narration: narration, targetDescription: targetDescription,
                isIrreversible: false, needsVision: false, modelRoleUsed: nil, isOverlayDismissal: true
            )
        }

        // 1. Cookie notices — declining optional cookies is preferred (privacy first).
        let cookieRejectButton = firstUntried { element, normalizedLabel in
            isCookieBannerButton(element, normalizedLabel, in: strongCookieRejectLabels)
                || (normalizedLabel.contains("cookie") && (normalizedLabel.contains("reject") || normalizedLabel.contains("decline") || normalizedLabel.contains("necessary") || normalizedLabel.contains("essential")))
                || (pageHasCookieNotice && weakCookieRejectLabels.contains(normalizedLabel))
        }
        if let cookieRejectButton {
            return dismissalStep(clicking: cookieRejectButton, narration: "First, closing the cookie banner and declining optional cookies.", targetDescription: "\"\(cookieRejectButton.label)\" on the cookie banner")
        }
        let cookieAcceptButton = firstUntried { element, normalizedLabel in
            isCookieBannerButton(element, normalizedLabel, in: strongCookieAcceptLabels)
                || (normalizedLabel.contains("cookie") && (normalizedLabel.contains("accept") || normalizedLabel.contains("allow") || normalizedLabel.contains("agree")))
                || (pageHasCookieNotice && element.isInsideOverlay && weakCookieAcceptLabels.contains(normalizedLabel))
        }
        if let cookieAcceptButton {
            return dismissalStep(clicking: cookieAcceptButton, narration: "First, closing the cookie banner.", targetDescription: "\"\(cookieAcceptButton.label)\" on the cookie banner")
        }

        // 2. A pop-up blocked the last click: Saathi clicked something behind
        //    it and nothing changed. (A pop-up Saathi was working inside, like
        //    a compose window, is never closed this way.)
        guard let lastStep = completedSteps.last,
              !lastStep.wasDoneByUser,
              lastStep.action == .click || lastStep.action == .type,
              lastStep.screenChangedAfterStep == false,
              !lastStep.targetWasInsideOverlay,
              !lastStep.isOverlayDismissal,
              snapshot.elements.contains(where: \.isInsideOverlay) else {
            return nil
        }
        if let closeButton = firstUntried({ element, normalizedLabel in
            element.isInsideOverlay && overlayCloseLabels.contains(normalizedLabel)
        }) {
            return dismissalStep(clicking: closeButton, narration: "A pop-up is in the way. Closing it first.", targetDescription: "\"\(closeButton.label)\" on the pop-up")
        }
        guard !attemptedKeys.contains("\(pageHost)|escape") else { return nil }
        attemptedKeys.insert("\(pageHost)|escape")
        print("🍪 Clearing overlay with Escape")
        return PlannedAgentStep(
            action: .pressKey, elementID: nil, screenshotPoint: nil, text: nil, keyName: "escape", urlString: nil,
            narration: "A pop-up is in the way. Closing it first.", targetDescription: "the pop-up",
            isIrreversible: false, needsVision: false, modelRoleUsed: nil, isOverlayDismissal: true
        )
    }

    static func looksIrreversible(_ labelText: String) -> Bool {
        let lowercasedLabel = labelText.lowercased()
        let irreversibleKeywords = [
            "pay", "payment", "submit", "send", "confirm", "place order", "purchase", "buy now", "book now",
            "book ticket", "checkout", "check out", "delete", "remove account", "transfer", "proceed to pay",
            "make payment", "final submit", "sign document", "भुगतान", "जमा करें", "पुष्टि"
        ]
        return irreversibleKeywords.contains { lowercasedLabel.contains($0) }
    }

    static func looksLikeSecretField(_ labelText: String) -> Bool {
        let lowercasedLabel = labelText.lowercased()
        let secretKeywords = [
            "password", "passcode", "otp", "one time", "one-time", "pin", "cvv", "cvc", "captcha",
            "card number", "aadhaar", "aadhar", "pan number", "pan card", "passport number", "security code", "mpin"
        ]
        return secretKeywords.contains { lowercasedLabel.contains($0) }
    }
}
