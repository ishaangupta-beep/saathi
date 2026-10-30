//
//  AgentControlsView.swift
//  leanring-buddy
//
//  Saathi's section of the menu bar panel: the Ask box, the trust dial,
//  narration language, and a one-line view of model provider and spend.
//

import SwiftUI

struct AgentControlsView: View {
    @ObservedObject var agentCoordinator: AgentCoordinator
    @ObservedObject var settings: SaathiSettings
    @ObservedObject var nemotronClient: NemotronClient
    @ObservedObject var skillStore: SkillStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            askBox
            trustDial
            languageAndSpotlightRow
            providerStatusRow
            dashboardButton
        }
    }

    // MARK: Ask box

    private var askBox: some View {
        HStack(spacing: 8) {
            TextField("Ask me to do something…", text: $agentCoordinator.askBoxText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit {
                    agentCoordinator.submitAskBox()
                }

            Button(action: {
                if agentCoordinator.isRunning {
                    agentCoordinator.stopCurrentRun(reason: "Stopped. You're in control.")
                } else {
                    agentCoordinator.submitAskBox()
                }
            }) {
                Image(systemName: agentCoordinator.isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 0.75)
        )
    }

    // MARK: Trust dial

    private var trustDial: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(TrustLevel.allCases) { trustLevel in
                    trustLevelButton(trustLevel)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )

            Text(settings.trustLevel.longDescription)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func trustLevelButton(_ trustLevel: TrustLevel) -> some View {
        let isSelected = settings.trustLevel == trustLevel
        return Button(action: {
            settings.trustLevel = trustLevel
        }) {
            HStack(spacing: 5) {
                TrustLevelRingGlyph(trustLevel: trustLevel, isSelected: isSelected)
                Text(trustLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Language + spotlight

    private var languageAndSpotlightRow: some View {
        HStack {
            Text("Voice")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: 0) {
                ForEach(NarrationLanguage.allCases) { narrationLanguage in
                    let isSelected = settings.narrationLanguage == narrationLanguage
                    Button(action: {
                        settings.narrationLanguage = narrationLanguage
                    }) {
                        Text(narrationLanguage.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            Spacer()

            Toggle(isOn: $settings.isSpotlightEnabled) {
                Text("Spotlight")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .toggleStyle(.switch)
            .tint(DS.Colors.accent)
            .controlSize(.mini)
        }
    }

    // MARK: Provider + spend

    private var providerStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(nemotronClient.isConfigured ? DS.Colors.success : Color.orange)
                    .frame(width: 6, height: 6)
                Text(nemotronClient.isConfigured ? SaathiConfiguration.providerDisplayName : "No API key yet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text(String(format: "$%.3f of $%.0f", nemotronClient.estimatedTotalSpendInUSD, nemotronClient.spendLimitInUSD))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if !nemotronClient.isConfigured {
                Text("Add PROVIDER_API_KEY to the .env file, then restart.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            } else if agentCoordinator.isRunning {
                Text(agentCoordinator.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var dashboardButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            AgentDashboardWindowController.shared.showWindow()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
                Text("Receipts, skills & model routing")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(skillStore.skills.count) skill\(skillStore.skills.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Tiny ring glyph that previews each trust level's ring style.
struct TrustLevelRingGlyph: View {
    let trustLevel: TrustLevel
    let isSelected: Bool

    var body: some View {
        let glyphColor = isSelected ? DS.Colors.textOnAccent : SaathiColors.marigold
        ZStack {
            switch trustLevel {
            case .showMe:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(glyphColor, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
            case .walkMeThrough:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(glyphColor, lineWidth: 1.5)
            case .justDoIt:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(glyphColor.opacity(0.35))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(glyphColor, lineWidth: 1.5)
            }
        }
        .frame(width: 11, height: 9)
    }
}
