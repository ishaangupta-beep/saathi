//
//  AccessibilityTreeReader.swift
//  leanring-buddy
//
//  Reads the frontmost app's Accessibility tree: the real buttons, links
//  and fields macOS already knows about, with their labels and exact
//  frames. This is Saathi's primary way of finding targets — far more
//  reliable than guessing pixel coordinates from a screenshot. Also
//  performs actions (press, click, type, scroll, keys) for "Do it" mode.
//

import AppKit
import ApplicationServices

/// One interactive element on screen, numbered so the model can refer to it by ID.
struct AccessibleScreenElement: Identifiable {
    let id: Int
    let role: String
    let label: String
    let currentValue: String?
    /// Global frame in Accessibility/CoreGraphics coordinates (top-left origin of the main display).
    let frameInTopLeftCoordinates: CGRect
    let isSecureTextField: Bool
    let isEnabled: Bool
    let underlyingElement: AXUIElement
    /// The element that currently has keyboard focus (e.g. the field just typed into).
    var isFocused: Bool = false
    /// An option inside an open list, menu, dropdown or calendar — usually
    /// the autocomplete suggestion or date that has to be picked next.
    var isPopupOption: Bool = false
    /// Sits inside a web pop-up, dialog or banner (cookie notices, sign-up
    /// prompts, modals) that may be covering the rest of the page.
    var isInsideOverlay: Bool = false

    var isTextInput: Bool {
        AccessibilityTreeReader.textInputRoles.contains(role)
    }

    /// Global frame in AppKit coordinates (bottom-left origin), used by the overlay.
    var frameInAppKitCoordinates: CGRect {
        AccessibilityTreeReader.convertBetweenTopLeftAndAppKit(frameInTopLeftCoordinates)
    }

    /// Short human description, e.g. `button "Login"`.
    var promptDescription: String {
        let readableRole = role.replacingOccurrences(of: "AX", with: "").lowercased()
        var description = "[\(id)] \(readableRole) \"\(label)\""
        if let currentValue, !currentValue.isEmpty, !isSecureTextField {
            description += " value=\"\(currentValue.prefix(60))\""
        }
        if isSecureTextField {
            description += " (password field)"
        }
        if !isEnabled {
            description += " (disabled)"
        }
        if isFocused {
            description += " (focused)"
        }
        if isPopupOption {
            description += " (option in open list)"
        }
        if isInsideOverlay {
            description += " (in pop-up)"
        }
        let centerX = Int(frameInTopLeftCoordinates.midX)
        let centerY = Int(frameInTopLeftCoordinates.midY)
        description += " at (\(centerX),\(centerY))"
        return description
    }
}

/// Everything Saathi knows about the screen for one agent step.
struct AccessibilitySnapshot {
    let applicationName: String
    let windowTitle: String
    let webPageURL: URL?
    let elements: [AccessibleScreenElement]

    func element(withID elementID: Int) -> AccessibleScreenElement? {
        elements.first { $0.id == elementID }
    }

    /// The element list as plain text for the planner prompt.
    var promptText: String {
        if elements.isEmpty {
            return "(no accessible elements found)"
        }
        return elements.map(\.promptDescription).joined(separator: "\n")
    }
}

@MainActor
enum AccessibilityTreeReader {

    static let textInputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField"
    ]

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSecureTextField", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXSlider", "AXDisclosureTriangle", "AXTab", "AXSearchField",
        "AXIncrementor", "AXSwitch", "AXToggle"
    ]

    private static let maximumNodesToVisit = 3500
    private static let maximumTreeDepth = 45
    private static let maximumElementsToReturn = 220
    private static let maximumPopupOptionsToReturn = 60

    // MARK: - Reading

    /// Reads the frontmost app (ignoring Saathi itself).
    static func readFrontmostApplication() -> AccessibilitySnapshot {
        guard AXIsProcessTrusted(),
              let frontmostApplication = frontmostNonSaathiApplication() else {
            return AccessibilitySnapshot(applicationName: "Unknown", windowTitle: "", webPageURL: nil, elements: [])
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.6)

        // Chromium and Electron apps only build their web Accessibility tree
        // when an assistive app asks for it.
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue as CFTypeRef)

        let focusedWindowElement = copyElementAttribute(applicationElement, "AXFocusedWindow")
            ?? copyElementArrayAttribute(applicationElement, "AXWindows")?.first
        let windowTitle = focusedWindowElement.flatMap { stringAttribute($0, "AXTitle") } ?? ""

        var collectedElements: [AccessibleScreenElement] = []
        var collectedPopupOptions: [AccessibleScreenElement] = []
        var webPageURL: URL?

        if let focusedWindowElement {
            collectElements(
                startingAt: focusedWindowElement,
                collectedElements: &collectedElements,
                collectedPopupOptions: &collectedPopupOptions,
                webPageURL: &webPageURL
            )
        }

        // The menu bar is outside the window; include its top-level items so
        // "open the File menu" style tasks work.
        if let menuBarElement = copyElementAttribute(applicationElement, "AXMenuBar"),
           let menuBarItems = copyElementArrayAttribute(menuBarElement, "AXChildren") {
            for menuBarItem in menuBarItems.prefix(12) {
                appendIfUseful(menuBarItem, role: "AXMenuBarItem", collectedElements: &collectedElements)
            }
        }

        // Open-list options (autocomplete suggestions, dropdown items, calendar
        // days) go first: right after typing they're almost always the next step.
        let focusedElement = copyElementAttribute(applicationElement, "AXFocusedUIElement")
        let orderedElements = collectedPopupOptions + collectedElements
        let numberedElements = orderedElements.enumerated().map { elementIndex, element -> AccessibleScreenElement in
            var renumberedElement = AccessibleScreenElement(
                id: elementIndex + 1,
                role: element.role,
                label: element.label,
                currentValue: element.currentValue,
                frameInTopLeftCoordinates: element.frameInTopLeftCoordinates,
                isSecureTextField: element.isSecureTextField,
                isEnabled: element.isEnabled,
                underlyingElement: element.underlyingElement
            )
            renumberedElement.isPopupOption = element.isPopupOption
            renumberedElement.isInsideOverlay = element.isInsideOverlay
            if let focusedElement, CFEqual(focusedElement, element.underlyingElement) {
                renumberedElement.isFocused = true
            }
            return renumberedElement
        }

        return AccessibilitySnapshot(
            applicationName: frontmostApplication.localizedName ?? "Unknown app",
            windowTitle: windowTitle,
            webPageURL: webPageURL,
            elements: numberedElements
        )
    }

    /// The last app the user was in before Saathi itself came to the front
    /// (for example when the receipts window is open). Kept up to date by
    /// `startTrackingExternalApplicationActivations()`.
    private(set) static var lastActiveExternalApplication: NSRunningApplication?
    private static var applicationActivationObserver: NSObjectProtocol?

    static func startTrackingExternalApplicationActivations() {
        guard applicationActivationObserver == nil else { return }
        lastActiveExternalApplication = frontmostNonSaathiApplication()
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { activationNotification in
            let activatedApplication = activationNotification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let activatedApplication,
                   activatedApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    lastActiveExternalApplication = activatedApplication
                }
            }
        }
    }

    static func frontmostNonSaathiApplication() -> NSRunningApplication? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ownProcessIdentifier {
            return frontmostApplication
        }
        if let lastActiveExternalApplication, !lastActiveExternalApplication.isTerminated {
            return lastActiveExternalApplication
        }
        return nil
    }

    /// Browsers Saathi knows how to drive, in order of preference when more
    /// than one is running and none is in front.
    private static let knownBrowserBundleIdentifiers: [String] = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox",
        "com.google.Chrome.canary", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
    ]

    /// Opens a website in the browser the user is actually using.
    ///  • A browser is in front: load the URL in the current tab (⌘L, paste,
    ///    Return), so no extra tabs or windows pile up.
    ///  • Another app is in front but a browser is running: open it there.
    ///  • No browser running: fall back to the system default browser.
    /// (Plain NSWorkspace.open always used the default browser, which pulled
    /// up Safari even when the user was working in Chrome.)
    static func openURLInUsersBrowser(_ url: URL) async {
        if let frontApplication = frontmostNonSaathiApplication(),
           let frontBundleIdentifier = frontApplication.bundleIdentifier,
           knownBrowserBundleIdentifiers.contains(frontBundleIdentifier) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != frontApplication.processIdentifier {
                frontApplication.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            pressKeyCombination(keyCode: 37, withCommand: true) // ⌘L: focus the address bar
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await typeText(url.absoluteString)
            if Task.isCancelled { return }
            pressNamedKey("return")
            print("🌐 Opened \(url.host ?? url.absoluteString) in the current \(frontApplication.localizedName ?? "browser") tab")
            return
        }

        let runningBrowser = knownBrowserBundleIdentifiers.lazy.compactMap { browserBundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleIdentifier).first
        }.first
        if let runningBrowser, let browserApplicationURL = runningBrowser.bundleURL {
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browserApplicationURL, configuration: openConfiguration, completionHandler: nil)
            print("🌐 Opened \(url.host ?? url.absoluteString) in \(runningBrowser.localizedName ?? "the running browser")")
            return
        }

        NSWorkspace.shared.open(url)
        print("🌐 Opened \(url.host ?? url.absoluteString) in the default browser")
    }

    /// Brings the user's app back to the front before Saathi acts on it.
    static func activateTargetApplicationIfNeeded() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let targetApplication = frontmostNonSaathiApplication() else {
            return
        }
        targetApplication.activate()
    }

    /// Roles that hold a list of choices: autocomplete suggestion lists,
    /// dropdown menus, and calendar grids (which show up as tables).
    private static let listContainerRoles: Set<String> = [
        "AXList", "AXMenu", "AXTable", "AXOutline", "AXComboBox", "AXBrowser"
    ]

    /// Inside a list container, these are the individual choices.
    private static let listOptionRoles: Set<String> = [
        "AXStaticText", "AXGroup", "AXRow", "AXCell", "AXImage", "AXMenuItem", "AXButton", "AXLink"
    ]

    private static func collectElements(
        startingAt rootElement: AXUIElement,
        collectedElements: inout [AccessibleScreenElement],
        collectedPopupOptions: inout [AccessibleScreenElement],
        webPageURL: inout URL?
    ) {
        // Breadth-first so the most prominent controls are found before deep content.
        // Each entry remembers whether it sits inside a list container, so
        // suggestion rows (often plain text with no button role) are still found.
        // It also remembers whether the node is on a web page and inside a
        // pop-up/dialog there, so overlays can be recognised and closed.
        var elementsToVisit: [(element: AXUIElement, depth: Int, isInsideListContainer: Bool, isInsideWebArea: Bool, isInsideOverlay: Bool)] = [(rootElement, 0, false, false, false)]
        var visitedNodeCount = 0
        var nextIndexToVisit = 0

        while nextIndexToVisit < elementsToVisit.count {
            let (currentElement, currentDepth, isInsideListContainer, isInsideWebArea, isInsideOverlay) = elementsToVisit[nextIndexToVisit]
            nextIndexToVisit += 1
            visitedNodeCount += 1
            if visitedNodeCount > maximumNodesToVisit || collectedElements.count >= maximumElementsToReturn {
                break
            }

            // Role, subrole and children in one round trip to the app
            // (cheaper than asking for them one by one).
            let (role, subrole, prefetchedChildElements) = roleSubroleAndChildren(of: currentElement)
            let isWebArea = role == "AXWebArea"
            // Web dialogs (role="dialog"/"alertdialog", modals, cookie banners
            // built as dialogs). Native app windows are left alone.
            let isOverlayContainer = isInsideWebArea && (Self.overlaySubroles.contains(subrole) || role == "AXSheet")

            if role == "AXWebArea" && webPageURL == nil {
                webPageURL = urlAttribute(currentElement, "AXURL")
            }

            // A choice inside an open list: collect it as one option and don't
            // descend further (its children are just the same text again).
            if isInsideListContainer && listOptionRoles.contains(role) && collectedPopupOptions.count < maximumPopupOptionsToReturn {
                let optionCountBefore = collectedPopupOptions.count
                appendIfUseful(currentElement, role: role, collectedElements: &collectedPopupOptions)
                if collectedPopupOptions.count > optionCountBefore {
                    collectedPopupOptions[collectedPopupOptions.count - 1].isPopupOption = true
                    collectedPopupOptions[collectedPopupOptions.count - 1].isInsideOverlay = isInsideOverlay
                    continue
                }
            }

            if interactiveRoles.contains(role) || isClickableGroup(currentElement, role: role) {
                let elementCountBefore = collectedElements.count
                appendIfUseful(currentElement, role: role, collectedElements: &collectedElements)
                if collectedElements.count > elementCountBefore {
                    collectedElements[collectedElements.count - 1].isInsideOverlay = isInsideOverlay
                }
            }

            guard currentDepth < maximumTreeDepth,
                  let childElements = prefetchedChildElements else {
                continue
            }
            let childrenAreInsideListContainer = isInsideListContainer || listContainerRoles.contains(role)
            let childrenAreInsideWebArea = isInsideWebArea || isWebArea
            let childrenAreInsideOverlay = isInsideOverlay || isOverlayContainer
            for childElement in childElements {
                elementsToVisit.append((childElement, currentDepth + 1, childrenAreInsideListContainer, childrenAreInsideWebArea, childrenAreInsideOverlay))
            }
        }
    }

    /// Subroles Chrome and Safari give web dialogs and modals.
    private static let overlaySubroles: Set<String> = [
        "AXApplicationDialog", "AXApplicationAlertDialog", "AXDialog", "AXSystemDialog", "AXFloatingWindow"
    ]

    /// Reads AXRole, AXSubrole and AXChildren in a single Accessibility call.
    private static func roleSubroleAndChildren(of element: AXUIElement) -> (role: String, subrole: String, children: [AXUIElement]?) {
        let attributeNames = ["AXRole", "AXSubrole", "AXChildren"] as CFArray
        var attributeValues: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &attributeValues) == .success,
           let valueList = attributeValues as? [AnyObject], valueList.count == 3 {
            // Missing attributes come back as error values, which these casts skip.
            return (valueList[0] as? String ?? "", valueList[1] as? String ?? "", valueList[2] as? [AXUIElement])
        }
        return (
            stringAttribute(element, "AXRole") ?? "",
            stringAttribute(element, "AXSubrole") ?? "",
            copyElementArrayAttribute(element, "AXChildren")
        )
    }

    /// Some web "buttons" are divs with a press action and no button role.
    private static func isClickableGroup(_ element: AXUIElement, role: String) -> Bool {
        guard role == "AXGroup" || role == "AXImage" || role == "AXRow" || role == "AXCell" else { return false }
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let actionNameList = actionNames as? [String] else {
            return false
        }
        return actionNameList.contains("AXPress") && !(bestLabel(for: element)?.isEmpty ?? true)
    }

    private static func appendIfUseful(
        _ element: AXUIElement,
        role: String,
        collectedElements: inout [AccessibleScreenElement]
    ) {
        guard let elementFrame = frameAttribute(element),
              elementFrame.width >= 3, elementFrame.height >= 3,
              isOnAnyScreen(elementFrame) else {
            return
        }

        let subrole = stringAttribute(element, "AXSubrole") ?? ""
        let isSecureTextField = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let effectiveRole = subrole == "AXSearchField" ? "AXSearchField" : role
        let label = bestLabel(for: element) ?? ""

        // Unlabeled buttons are nearly useless to the planner; text fields are
        // kept anyway because their position alone is often enough.
        if label.isEmpty && !textInputRoles.contains(effectiveRole) && !isSecureTextField {
            return
        }

        let currentValue: String? = isSecureTextField ? nil : stringAttribute(element, "AXValue")
        let isEnabled = boolAttribute(element, "AXEnabled") ?? true

        collectedElements.append(AccessibleScreenElement(
            id: collectedElements.count + 1,
            role: isSecureTextField ? "AXSecureTextField" : effectiveRole,
            label: String(label.prefix(80)),
            currentValue: currentValue,
            frameInTopLeftCoordinates: elementFrame,
            isSecureTextField: isSecureTextField,
            isEnabled: isEnabled,
            underlyingElement: element
        ))
    }

    private static func bestLabel(for element: AXUIElement) -> String? {
        let candidateAttributeNames = ["AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp"]
        for attributeName in candidateAttributeNames {
            if let value = stringAttribute(element, attributeName)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let titleElement = copyElementAttribute(element, "AXTitleUIElement"),
           let titleText = stringAttribute(titleElement, "AXValue")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !titleText.isEmpty {
            return titleText
        }
        // Links and web buttons usually carry their text in a child static text.
        if let childText = firstDescendantText(of: element, remainingDepth: 3), !childText.isEmpty {
            return childText
        }
        let role = stringAttribute(element, "AXRole") ?? ""
        if role == "AXStaticText" || role == "AXButton" {
            return stringAttribute(element, "AXValue")?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func firstDescendantText(of element: AXUIElement, remainingDepth: Int) -> String? {
        guard remainingDepth > 0,
              let childElements = copyElementArrayAttribute(element, "AXChildren") else {
            return nil
        }
        for childElement in childElements.prefix(6) {
            if stringAttribute(childElement, "AXRole") == "AXStaticText",
               let text = stringAttribute(childElement, "AXValue")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if let nestedText = firstDescendantText(of: childElement, remainingDepth: remainingDepth - 1) {
                return nestedText
            }
        }
        return nil
    }

    // MARK: - Finding elements again (skills, answers)

    /// Finds the element whose label best matches `targetLabel` (case-insensitive),
    /// preferring the same role. Used to replay saved skills and to snap the
    /// ring onto an element the vision model named.
    static func findBestMatchingElement(
        label targetLabel: String,
        role targetRole: String?,
        in snapshot: AccessibilitySnapshot
    ) -> AccessibleScreenElement? {
        let normalizedTargetLabel = normalizeForMatching(targetLabel)
        guard !normalizedTargetLabel.isEmpty else { return nil }

        var bestElement: AccessibleScreenElement?
        var bestScore = 0
        for element in snapshot.elements {
            let normalizedElementLabel = normalizeForMatching(element.label)
            guard !normalizedElementLabel.isEmpty else { continue }

            var score = 0
            if normalizedElementLabel == normalizedTargetLabel {
                score = 100
            } else if normalizedElementLabel.contains(normalizedTargetLabel) || normalizedTargetLabel.contains(normalizedElementLabel) {
                score = 60
            } else {
                let targetWords = Set(normalizedTargetLabel.split(separator: " "))
                let elementWords = Set(normalizedElementLabel.split(separator: " "))
                let sharedWordCount = targetWords.intersection(elementWords).count
                if sharedWordCount > 0 {
                    score = 20 + sharedWordCount * 10
                }
            }
            if let targetRole, element.role == targetRole {
                score += 15
            }
            if score > bestScore {
                bestScore = score
                bestElement = element
            }
        }
        return bestScore >= 40 ? bestElement : nil
    }

    private static func normalizeForMatching(_ text: String) -> String {
        let lowercasedText = text.lowercased()
        let allowedCharacters = lowercasedText.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(allowedCharacters)
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: - Actions

    /// Presses an element: the Accessibility press action first (works even if
    /// the element is partly covered), falling back to a real mouse click.
    static func press(_ element: AccessibleScreenElement) {
        let pressResult = AXUIElementPerformAction(element.underlyingElement, "AXPress" as CFString)
        if pressResult != .success {
            clickAtTopLeftPoint(CGPoint(x: element.frameInTopLeftCoordinates.midX, y: element.frameInTopLeftCoordinates.midY))
        }
    }

    /// Focuses a text input by clicking it, then types `text` with real key events
    /// so web pages see normal input events.
    static func focusAndType(_ text: String, into element: AccessibleScreenElement) async {
        // Focus the field: Accessibility focus first, then a real click
        // (web pages only treat a field as active after a click).
        if Task.isCancelled { return }
        AXUIElementSetAttributeValue(element.underlyingElement, "AXFocused" as CFString, kCFBooleanTrue)
        clickAtTopLeftPoint(CGPoint(x: element.frameInTopLeftCoordinates.midX, y: element.frameInTopLeftCoordinates.midY))
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Esc during typing: stop before touching the field's text.
        if Task.isCancelled { return }

        // Select any existing text so the new text replaces it.
        pressKeyCombination(keyCode: 0, withCommand: true) // ⌘A
        try? await Task.sleep(nanoseconds: 100_000_000)
        if Task.isCancelled { return }

        await typeText(text)
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        // Verify the text landed. If it didn't, set the field's value directly
        // through Accessibility as a last resort.
        let fieldValueAfterTyping = stringAttribute(element.underlyingElement, "AXValue") ?? ""
        if !fieldValueAfterTyping.contains(text) {
            print("⌨️ Paste didn't land in \"\(element.label)\" (value: \"\(fieldValueAfterTyping.prefix(40))\"), setting it directly")
            AXUIElementSetAttributeValue(element.underlyingElement, "AXValue" as CFString, text as CFString)
        }
    }

    static func clickAtTopLeftPoint(_ point: CGPoint) {
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    /// Types text by pasting it: the text goes on the clipboard, ⌘V is pressed,
    /// then the user's clipboard is put back. Paste works in every app,
    /// including browsers that ignore synthetic key events, and handles Hindi.
    static func typeText(_ text: String) async {
        let generalPasteboard = NSPasteboard.general

        // Save whatever the user had copied so we can restore it afterwards.
        let savedPasteboardItems: [NSPasteboardItem] = (generalPasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for pasteboardType in originalItem.types {
                if let itemData = originalItem.data(forType: pasteboardType) {
                    copiedItem.setData(itemData, forType: pasteboardType)
                }
            }
            return copiedItem
        }

        generalPasteboard.clearContents()
        generalPasteboard.setString(text, forType: .string)
        try? await Task.sleep(nanoseconds: 60_000_000)

        // If Esc was pressed, skip the paste but still put the user's clipboard back.
        if !Task.isCancelled {
            pressKeyCombination(keyCode: 9, withCommand: true) // ⌘V
            // Give the app time to read the clipboard before restoring it.
            // This wait ignores Esc on purpose: Task.sleep returns at once when
            // cancelled, and restoring too early would paste the old clipboard.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { continuation.resume() }
            }
        }

        generalPasteboard.clearContents()
        if !savedPasteboardItems.isEmpty {
            generalPasteboard.writeObjects(savedPasteboardItems)
        }
    }

    /// Presses a named key: return, tab, escape, delete, space, up, down, left, right, pagedown, pageup.
    static func pressNamedKey(_ keyName: String) {
        let keyCodeByName: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "pagedown": 121, "pageup": 116, "home": 115, "end": 119
        ]
        guard let keyCode = keyCodeByName[keyName.lowercased().replacingOccurrences(of: " ", with: "")] else {
            print("⚠️ Unknown key name: \(keyName)")
            return
        }
        pressKeyCombination(keyCode: keyCode, withCommand: false)
    }

    /// Written into every key event Saathi posts, so its own Esc presses
    /// are never mistaken for the user pressing Esc to stop.
    nonisolated static let saathiSyntheticEventMarker: Int64 = 0x5A4154

    private static func pressKeyCombination(keyCode: CGKeyCode, withCommand: Bool) {
        let hardwareEventSource = CGEventSource(stateID: .hidSystemState)
        guard let keyDownEvent = CGEvent(keyboardEventSource: hardwareEventSource, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: hardwareEventSource, virtualKey: keyCode, keyDown: false) else {
            return
        }
        // Always set the flags explicitly, so modifier keys the user happens
        // to be holding (like Control+Option from push-to-talk) don't leak in.
        let modifierFlags: CGEventFlags = withCommand ? .maskCommand : []
        keyDownEvent.flags = modifierFlags
        keyUpEvent.flags = modifierFlags
        // Tag Saathi's own key presses so the Esc kill switch ignores them.
        keyDownEvent.setIntegerValueField(.eventSourceUserData, value: saathiSyntheticEventMarker)
        keyUpEvent.setIntegerValueField(.eventSourceUserData, value: saathiSyntheticEventMarker)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }

    /// Scrolls the content under the mouse. Positive amount scrolls down.
    static func scroll(downByLines lineCount: Int32) {
        // A scroll goes to whatever is under the pointer, so first put the
        // pointer in the middle of the user's window (the page itself, not a
        // sidebar, another window or Saathi's own panels).
        if let windowCenterPoint = frontmostWindowCenterInTopLeftCoordinates() {
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: windowCenterPoint, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)
        }
        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -lineCount,
            wheel2: 0,
            wheel3: 0
        )
        scrollEvent?.post(tap: .cghidEventTap)
    }

    /// Center of the user's frontmost window, nudged a little below the middle
    /// so it lands on page content rather than a browser toolbar.
    private static func frontmostWindowCenterInTopLeftCoordinates() -> CGPoint? {
        guard let targetApplication = frontmostNonSaathiApplication() else { return nil }
        let applicationElement = AXUIElementCreateApplication(targetApplication.processIdentifier)
        guard let windowElement = copyElementAttribute(applicationElement, "AXFocusedWindow")
                ?? copyElementArrayAttribute(applicationElement, "AXWindows")?.first,
              let windowFrame = frameAttribute(windowElement),
              windowFrame.width > 50, windowFrame.height > 50 else {
            return nil
        }
        return CGPoint(x: windowFrame.midX, y: windowFrame.minY + windowFrame.height * 0.55)
    }

    // MARK: - Coordinates

    /// Accessibility uses a top-left origin on the main display; AppKit uses
    /// bottom-left. The conversion is the same in both directions.
    static func convertBetweenTopLeftAndAppKit(_ rect: CGRect) -> CGRect {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.origin.x,
            y: mainDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func convertAppKitPointToTopLeft(_ point: CGPoint) -> CGPoint {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    private static func isOnAnyScreen(_ frameInTopLeftCoordinates: CGRect) -> Bool {
        let frameInAppKitCoordinates = convertBetweenTopLeftAndAppKit(frameInTopLeftCoordinates)
        return NSScreen.screens.contains { $0.frame.intersects(frameInAppKitCoordinates) }
    }

    // MARK: - Attribute helpers

    private static func copyAttributeValue(_ element: AXUIElement, _ attributeName: String) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue)
        return result == .success ? attributeValue : nil
    }

    static func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String? {
        copyAttributeValue(element, attributeName) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attributeName: String) -> Bool? {
        copyAttributeValue(element, attributeName) as? Bool
    }

    private static func urlAttribute(_ element: AXUIElement, _ attributeName: String) -> URL? {
        let attributeValue = copyAttributeValue(element, attributeName)
        if let url = attributeValue as? URL {
            return url
        }
        if let urlString = attributeValue as? String {
            return URL(string: urlString)
        }
        return nil
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attributeName: String) -> AXUIElement? {
        guard let attributeValue = copyAttributeValue(element, attributeName),
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    private static func copyElementArrayAttribute(_ element: AXUIElement, _ attributeName: String) -> [AXUIElement]? {
        copyAttributeValue(element, attributeName) as? [AXUIElement]
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttributeValue(element, "AXPosition"),
              let sizeValue = copyAttributeValue(element, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
