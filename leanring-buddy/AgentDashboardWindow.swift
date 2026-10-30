//
//  AgentDashboardWindow.swift
//  leanring-buddy
//
//  One window with three tabs:
//    • Receipts      — what Saathi did, step by step, with screenshots
//    • Skills        — saved skills, with delete
//    • Model routing — every Nemotron call: which model, latency, tokens, cost
//

import AppKit
import SwiftUI

@MainActor
final class AgentDashboardWindowController {
    static let shared = AgentDashboardWindowController()

    private var dashboardWindow: NSWindow?

    private init() {}

    func showWindow() {
        if dashboardWindow == nil {
            let dashboardView = AgentDashboardView(
                receiptStore: ActionReceiptStore.shared,
                skillStore: SkillStore.shared,
                nemotronClient: NemotronClient.shared
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(SaathiConfiguration.productName) — Receipts & Routing"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: dashboardView)
            window.center()
            dashboardWindow = window
        }
        // Saathi is a menu bar app, so it has to activate itself to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }
}

private enum DashboardTab: String, CaseIterable, Identifiable {
    case receipts = "Receipts"
    case skills = "Skills"
    case modelRouting = "Model routing"

    var id: String { rawValue }
}

struct AgentDashboardView: View {
    @ObservedObject var receiptStore: ActionReceiptStore
    @ObservedObject var skillStore: SkillStore
    @ObservedObject var nemotronClient: NemotronClient

    @State private var selectedTab: DashboardTab = .receipts

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(DashboardTab.allCases) { dashboardTab in
                    Text(dashboardTab.rawValue).tag(dashboardTab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Divider()

            switch selectedTab {
            case .receipts:
                receiptsTab
            case .skills:
                skillsTab
            case .modelRouting:
                modelRoutingTab
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .tint(SaathiColors.marigold)
    }

    // MARK: Receipts

    @ViewBuilder
    private var receiptsTab: some View {
        if let latestReceipt = receiptStore.latestReceipt {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latestReceipt.taskDescription)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 10) {
                            Text("Mode: \(latestReceipt.trustLevel.displayName)")
                            if let usedSavedSkillName = latestReceipt.usedSavedSkillName {
                                Text("Skill: \(usedSavedSkillName)")
                            }
                            Text(latestReceipt.startedDate.formatted(date: .omitted, time: .shortened))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Text(latestReceipt.finalOutcome)
                            .font(.callout)
                            .foregroundColor(SaathiColors.marigoldDeep)
                    }

                    ForEach(latestReceipt.steps) { receiptStep in
                        receiptStepRow(receiptStep)
                    }

                    if receiptStore.receipts.count > 1 {
                        Divider()
                        Text("Earlier runs")
                            .font(.headline)
                        ForEach(receiptStore.receipts.dropFirst()) { earlierReceipt in
                            HStack {
                                Text(earlierReceipt.taskDescription)
                                Spacer()
                                Text("\(earlierReceipt.steps.count) steps · \(earlierReceipt.finalOutcome)")
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            emptyState(title: "No runs yet", message: "Ask \(SaathiConfiguration.productName) to do something and every step will show up here.")
        }
    }

    private func receiptStepRow(_ receiptStep: ActionReceiptStep) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .stroke(SaathiColors.marigold, lineWidth: 2)
                    .frame(width: 26, height: 26)
                Text("\(receiptStep.stepNumber)")
                    .font(.caption.weight(.bold))
            }

            if let thumbnailJPEGData = receiptStep.thumbnailJPEGData, let thumbnailImage = NSImage(data: thumbnailJPEGData) {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(receiptStep.summary)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(receiptStep.outcome)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SaathiColors.marigold.opacity(0.18)))
                    Text(receiptStep.modelRoleUsed?.displayName ?? "Saved skill (no model call)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(receiptStep.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Skills

    @ViewBuilder
    private var skillsTab: some View {
        if skillStore.skills.isEmpty {
            emptyState(title: "No saved skills", message: "After a task works, tap \"Save skill\" and next time it replays instantly.")
        } else {
            List {
                ForEach(skillStore.skills) { savedSkill in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(savedSkill.name)
                                .font(.headline)
                            Text(savedSkill.triggerDescription)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text("\(savedSkill.steps.count) steps · used \(savedSkill.timesReplayed)× · \(savedSkill.applicationName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Delete") {
                            skillStore.delete(savedSkill)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("Skills are plain JSON files in \(skillStore.skillsFolderPath). Personal values are stored only as placeholders like {aadhaar_number}.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(12)
        }
    }

    // MARK: Model routing

    private var modelRoutingTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider").font(.caption).foregroundColor(.secondary)
                    Text(SaathiConfiguration.providerDisplayName).font(.headline)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated spend").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "$%.4f of $%.2f limit", nemotronClient.estimatedTotalSpendInUSD, nemotronClient.spendLimitInUSD))
                        .font(.headline.monospacedDigit())
                }
                Spacer()
                Button("Reset estimate") {
                    nemotronClient.resetEstimatedSpend()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(NemotronModelRole.allCases, id: \.self) { modelRole in
                    HStack {
                        Text(modelRole.displayName)
                            .frame(width: 130, alignment: .leading)
                        Text(nemotronClient.resolvedModelIDByRole[modelRole] ?? "not resolved")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .font(.callout)
                }
                Text(nemotronClient.modelResolutionStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if nemotronClient.callRecords.isEmpty {
                emptyState(title: "No model calls yet", message: "Each call shows which Nemotron model handled it, how long it took, and what it cost.")
            } else {
                Table(nemotronClient.callRecords) {
                    TableColumn("Time") { callRecord in
                        Text(callRecord.timestamp.formatted(date: .omitted, time: .standard))
                    }
                    .width(70)
                    TableColumn("Model") { callRecord in
                        Text(callRecord.role.displayName)
                            .foregroundColor(callRecord.succeeded ? .primary : .red)
                    }
                    .width(110)
                    TableColumn("Purpose") { callRecord in
                        Text(callRecord.purpose)
                    }
                    TableColumn("Latency") { callRecord in
                        Text(String(format: "%.2fs", callRecord.latencyInSeconds))
                            .monospacedDigit()
                    }
                    .width(60)
                    TableColumn("Tokens in/out") { callRecord in
                        Text("\(callRecord.promptTokenCount) / \(callRecord.completionTokenCount)")
                            .monospacedDigit()
                    }
                    .width(95)
                    TableColumn("Cost") { callRecord in
                        Text(String(format: "$%.5f", callRecord.estimatedCostInUSD))
                            .monospacedDigit()
                    }
                    .width(75)
                }
            }
        }
        .padding(20)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Circle()
                .stroke(SaathiColors.marigold, style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
                .frame(width: 34, height: 34)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
