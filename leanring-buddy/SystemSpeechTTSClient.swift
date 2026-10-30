//
//  SystemSpeechTTSClient.swift
//  leanring-buddy
//
//  Replaces Clicky's ElevenLabs client with macOS's built-in voices
//  (free, offline, includes Hindi). Same method shape as the old client
//  so CompanionManager's pipeline is unchanged.
//

import AVFoundation
import Foundation

@MainActor
final class SystemSpeechTTSClient {
    static let shared = SystemSpeechTTSClient()

    private let speechSynthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Starts speaking `text` in the current narration language and returns
    /// immediately (playback continues in the background).
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        speak(text)
    }

    /// Non-async convenience for the agent's narration.
    func speak(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmedText)
        let languageCode = SaathiSettings.shared.narrationLanguage.speechVoiceLanguageCode
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        speechSynthesizer.speak(utterance)
    }

    /// Whether speech is currently playing.
    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
}
