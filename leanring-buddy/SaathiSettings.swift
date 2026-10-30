//
//  SaathiSettings.swift
//  leanring-buddy
//
//  User-facing settings that persist across launches: the narration
//  language and the spotlight.
//

import Combine
import Foundation

/// Saathi has one mode: it does the task for you, narrating each step, and
/// pauses before anything irreversible or private.
enum TrustLevel: String, CaseIterable, Identifiable {
    case justDoIt

    var id: String { rawValue }

    var displayName: String { "Do it" }

    var longDescription: String { "Does the whole task for you. Pauses before pay, submit or send." }
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

    /// Always Do it (kept as a value so receipts can record the mode).
    let trustLevel: TrustLevel = .justDoIt

    @Published var narrationLanguage: NarrationLanguage {
        didSet { UserDefaults.standard.set(narrationLanguage.rawValue, forKey: "saathi.narrationLanguage") }
    }

    /// Dims the rest of the screen around the target.
    @Published var isSpotlightEnabled: Bool {
        didSet { UserDefaults.standard.set(isSpotlightEnabled, forKey: "saathi.isSpotlightEnabled") }
    }

    private init() {
        let storedLanguage = UserDefaults.standard.string(forKey: "saathi.narrationLanguage").flatMap(NarrationLanguage.init(rawValue:))
        self.narrationLanguage = storedLanguage ?? .english

        if UserDefaults.standard.object(forKey: "saathi.isSpotlightEnabled") == nil {
            self.isSpotlightEnabled = true
        } else {
            self.isSpotlightEnabled = UserDefaults.standard.bool(forKey: "saathi.isSpotlightEnabled")
        }
    }
}
