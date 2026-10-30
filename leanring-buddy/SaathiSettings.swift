//
//  SaathiSettings.swift
//  leanring-buddy
//
//  User-facing settings that persist across launches: the trust dial
//  and the narration language.
//

import Combine
import Foundation

/// How much control the user hands over for a task.
enum TrustLevel: String, CaseIterable, Identifiable {
    /// Point at the next step and explain it. The user does everything.
    case showMe
    /// Guide step by step and wait for the user's click before moving on.
    case walkMeThrough
    /// Do the task, narrating each step. Pauses before anything irreversible.
    case justDoIt

    var id: String { rawValue }

    /// The dial offers two choices: guide me, or do it for me. Show me is
    /// kept only so older saved settings still load (it maps to Walk me).
    static var allCases: [TrustLevel] { [.walkMeThrough, .justDoIt] }

    var displayName: String {
        switch self {
        case .showMe: return "Show me"
        case .walkMeThrough: return "Walk me"
        case .justDoIt: return "Do it"
        }
    }

    var longDescription: String {
        switch self {
        case .showMe: return "Points at the next step. You do everything."
        case .walkMeThrough: return "Guides you step by step. You click, it follows."
        case .justDoIt: return "Does the whole task for you. Pauses before pay, submit or send."
        }
    }
}

enum NarrationLanguage: String, CaseIterable, Identifiable {
    case english
    case hindi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .hindi: return "हिंदी"
        }
    }

    /// BCP-47 code for the macOS speech voice.
    var speechVoiceLanguageCode: String {
        switch self {
        case .english: return "en-IN"
        case .hindi: return "hi-IN"
        }
    }

    /// Appended to every prompt whose output is spoken or shown as a caption.
    var promptInstruction: String {
        switch self {
        case .english:
            return "Write all narration in simple, friendly English."
        case .hindi:
            return "Write all narration in simple, conversational Hindi using Devanagari script (Hinglish words for technical terms like 'login' or 'button' are fine). Keep JSON keys and element IDs in English."
        }
    }
}

@MainActor
final class SaathiSettings: ObservableObject {
    static let shared = SaathiSettings()

    @Published var trustLevel: TrustLevel {
        didSet { UserDefaults.standard.set(trustLevel.rawValue, forKey: "saathi.trustLevel") }
    }

    @Published var narrationLanguage: NarrationLanguage {
        didSet { UserDefaults.standard.set(narrationLanguage.rawValue, forKey: "saathi.narrationLanguage") }
    }

    /// Dims the rest of the screen around the target.
    @Published var isSpotlightEnabled: Bool {
        didSet { UserDefaults.standard.set(isSpotlightEnabled, forKey: "saathi.isSpotlightEnabled") }
    }

    private init() {
        let storedTrustLevel = UserDefaults.standard.string(forKey: "saathi.trustLevel").flatMap(TrustLevel.init(rawValue:))
        // Show me was folded into Walk me.
        self.trustLevel = (storedTrustLevel == .showMe ? .walkMeThrough : storedTrustLevel) ?? .walkMeThrough

        let storedLanguage = UserDefaults.standard.string(forKey: "saathi.narrationLanguage").flatMap(NarrationLanguage.init(rawValue:))
        self.narrationLanguage = storedLanguage ?? .english

        if UserDefaults.standard.object(forKey: "saathi.isSpotlightEnabled") == nil {
            self.isSpotlightEnabled = true
        } else {
            self.isSpotlightEnabled = UserDefaults.standard.bool(forKey: "saathi.isSpotlightEnabled")
        }
    }
}
