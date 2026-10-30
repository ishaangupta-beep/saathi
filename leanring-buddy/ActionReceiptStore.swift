//
//  ActionReceiptStore.swift
//  leanring-buddy
//
//  Keeps a receipt of every agent run: one line and one screenshot
//  thumbnail per step, so the user can see exactly what Saathi did and
//  where it paused for them.
//

import Combine
import Foundation

struct ActionReceiptStep: Identifiable {
    let id = UUID()
    let stepNumber: Int
    let timestamp: Date
    let summary: String
    let modelRoleUsed: NemotronModelRole?
    let thumbnailJPEGData: Data?
    /// done, paused for user, confirmed, skipped, failed
    let outcome: String
}

struct ActionReceipt: Identifiable {
    let id = UUID()
    let taskDescription: String
    let trustLevel: TrustLevel
    let startedDate: Date
    var steps: [ActionReceiptStep] = []
    var finalOutcome: String = "Running"
    var usedSavedSkillName: String?
}

@MainActor
final class ActionReceiptStore: ObservableObject {
    static let shared = ActionReceiptStore()

    @Published private(set) var receipts: [ActionReceipt] = []

    private init() {}

    var latestReceipt: ActionReceipt? {
        receipts.first
    }

    func beginReceipt(taskDescription: String, trustLevel: TrustLevel) {
        receipts.insert(ActionReceipt(taskDescription: taskDescription, trustLevel: trustLevel, startedDate: Date()), at: 0)
        if receipts.count > 20 {
            receipts.removeLast(receipts.count - 20)
        }
    }

    func appendStep(
        summary: String,
        modelRoleUsed: NemotronModelRole?,
        screenshotJPEGData: Data?,
        outcome: String
    ) {
        guard !receipts.isEmpty else { return }
        let thumbnailJPEGData = screenshotJPEGData.flatMap { PrivacyShield.makeThumbnailJPEG(from: $0) }
        let receiptStep = ActionReceiptStep(
            stepNumber: receipts[0].steps.count + 1,
            timestamp: Date(),
            summary: summary,
            modelRoleUsed: modelRoleUsed,
            thumbnailJPEGData: thumbnailJPEGData,
            outcome: outcome
        )
        receipts[0].steps.append(receiptStep)
    }

    func markUsedSkill(named skillName: String) {
        guard !receipts.isEmpty else { return }
        receipts[0].usedSavedSkillName = skillName
    }

    func finishReceipt(finalOutcome: String) {
        guard !receipts.isEmpty else { return }
        receipts[0].finalOutcome = finalOutcome
    }
}
