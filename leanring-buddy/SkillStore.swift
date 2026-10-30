//
//  SkillStore.swift
//  leanring-buddy
//
//  A skill is a task Saathi has done successfully once, saved as a small
//  JSON file of steps described in words ("button 'Login'"), never pixel
//  positions and never personal values. Next time the same kind of task
//  comes up, the steps are replayed by finding each target again on the
//  current screen, so the skill survives layout changes.
//

import Combine
import Foundation

struct SavedSkillStep: Codable {
    /// click, type, press_key, scroll, open_url, user_input_needed
    let action: String
    let targetRole: String?
    let targetLabel: String?
    /// Plain-language description of the target, e.g. "Login button, top right".
    let targetDescription: String
    /// For type steps: a placeholder like {aadhaar_number} or a safe literal
    /// like a search query. Personal values are never stored.
    let textTemplate: String?
    let keyName: String?
    let urlString: String?
    let narration: String
    let isIrreversible: Bool
}

struct SavedSkill: Codable, Identifiable {
    let id: UUID
    var name: String
    /// What kind of request this skill answers, used for matching.
    var triggerDescription: String
    var applicationName: String
    var startURLString: String?
    var steps: [SavedSkillStep]
    let createdDate: Date
    var timesReplayed: Int
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [SavedSkill] = []

    private let skillsFolderURL: URL

    private init() {
        skillsFolderURL = SaathiConfiguration.applicationSupportFolderURL.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsFolderURL, withIntermediateDirectories: true)
        reloadFromDisk()
    }

    var skillsFolderPath: String {
        skillsFolderURL.path
    }

    func reloadFromDisk() {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        let skillFileURLs = (try? FileManager.default.contentsOfDirectory(at: skillsFolderURL, includingPropertiesForKeys: nil)) ?? []
        skills = skillFileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { skillFileURL in
                guard let skillData = try? Data(contentsOf: skillFileURL) else { return nil }
                return try? jsonDecoder.decode(SavedSkill.self, from: skillData)
            }
            .sorted { $0.createdDate > $1.createdDate }
    }

    func save(_ skill: SavedSkill) {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        do {
            let skillData = try jsonEncoder.encode(skill)
            try skillData.write(to: fileURL(for: skill.id), options: .atomic)
            reloadFromDisk()
            print("💾 Saved skill \"\(skill.name)\" with \(skill.steps.count) steps")
        } catch {
            print("⚠️ Could not save skill: \(error)")
        }
    }

    func delete(_ skill: SavedSkill) {
        try? FileManager.default.removeItem(at: fileURL(for: skill.id))
        reloadFromDisk()
    }

    func recordReplay(of skill: SavedSkill) {
        var updatedSkill = skill
        updatedSkill.timesReplayed += 1
        save(updatedSkill)
    }

    private func fileURL(for skillID: UUID) -> URL {
        skillsFolderURL.appendingPathComponent("\(skillID.uuidString).json")
    }

    // MARK: - Matching

    /// Asks Nemotron Nano which saved skill (if any) fits the request.
    func findMatchingSkill(for taskDescription: String) async -> SavedSkill? {
        guard !skills.isEmpty else { return nil }

        let numberedSkillList = skills.enumerated()
            .map { skillIndex, skill in "\(skillIndex + 1). \(skill.name) — \(skill.triggerDescription) (app: \(skill.applicationName))" }
            .joined(separator: "\n")

        let matchingPrompt = """
        A user asked: "\(taskDescription)"

        Saved skills:
        \(numberedSkillList)

        Reply with ONLY the number of the saved skill that does the same kind of task (values like names or dates may differ), or 0 if none fits.
        """

        do {
            let responseText = try await NemotronClient.shared.complete(
                role: .fast,
                messages: [NemotronChatMessage(role: .user, text: matchingPrompt)],
                purpose: "Match request to a saved skill",
                maxTokens: 1000,
                temperature: 0
            )
            let digitsOnly = responseText.filter(\.isNumber)
            guard let chosenNumber = Int(digitsOnly.prefix(3)), chosenNumber >= 1, chosenNumber <= skills.count else {
                return nil
            }
            return skills[chosenNumber - 1]
        } catch {
            print("⚠️ Skill matching failed: \(error.localizedDescription)")
            return nil
        }
    }
}
