//
//  NemotronClient.swift
//  leanring-buddy
//
//  OpenAI-compatible chat client for NVIDIA Nemotron models served by
//  Nebius Token Factory (or OpenRouter while testing). Three model roles:
//
//    • vision    — Nemotron 3 Nano Omni: reads screenshots, finds targets
//    • reasoning — Nemotron 3 Super: plans the next step, names skills
//    • fast      — Nemotron 3 Nano: intent routing, cheap high-volume calls
//
//  Every call is logged (model, latency, tokens, estimated cost) for the
//  routing panel, and a hard spend cap refuses calls past the limit.
//

import Combine
import Foundation

enum NemotronModelRole: String, CaseIterable {
    case vision
    case reasoning
    case fast

    var displayName: String {
        switch self {
        case .vision: return "Omni (vision)"
        case .reasoning: return "Super (planning)"
        case .fast: return "Nano (fast)"
        }
    }
}

struct NemotronCallRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let role: NemotronModelRole
    let modelID: String
    let purpose: String
    let latencyInSeconds: Double
    let promptTokenCount: Int
    let completionTokenCount: Int
    let estimatedCostInUSD: Double
    let succeeded: Bool
}

struct NemotronClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A single chat message. `imageJPEGDataList` is only sent for user messages.
struct NemotronChatMessage {
    enum Role: String {
        case system
        case user
        case assistant
    }

    let role: Role
    let text: String
    var imageJPEGDataList: [Data] = []
}

@MainActor
final class NemotronClient: ObservableObject {
    static let shared = NemotronClient()

    @Published private(set) var callRecords: [NemotronCallRecord] = []
    @Published private(set) var estimatedTotalSpendInUSD: Double
    @Published private(set) var resolvedModelIDByRole: [NemotronModelRole: String] = [:]
    @Published private(set) var modelResolutionStatusText: String = "Models not resolved yet"

    private let session: URLSession
    private var modelResolutionTask: Task<Void, Never>?

    private var spendStorageKey: String {
        "saathi.estimatedSpendUSD.\(URL(string: SaathiConfiguration.providerBaseURLString)?.host ?? "provider")"
    }

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)

        let storageKey = "saathi.estimatedSpendUSD.\(URL(string: SaathiConfiguration.providerBaseURLString)?.host ?? "provider")"
        self.estimatedTotalSpendInUSD = UserDefaults.standard.double(forKey: storageKey)
    }

    var isConfigured: Bool {
        SaathiConfiguration.providerAPIKey != nil
    }

    var spendLimitInUSD: Double {
        SaathiConfiguration.spendLimitInUSD
    }

    /// Lets the user reset the running spend estimate from the routing window
    /// (for example after checking the real balance in the provider console).
    func resetEstimatedSpend() {
        estimatedTotalSpendInUSD = 0
        UserDefaults.standard.set(0, forKey: spendStorageKey)
    }

    // MARK: - Model resolution

    /// Resolves model IDs for each role. Explicit IDs from the env file win;
    /// otherwise we pick from the provider's /models list by name.
    func resolveModelsIfNeeded() async {
        if resolvedModelIDByRole.count == NemotronModelRole.allCases.count {
            return
        }
        if let modelResolutionTask {
            await modelResolutionTask.value
            return
        }
        let newResolutionTask = Task { await self.resolveModels() }
        modelResolutionTask = newResolutionTask
        await newResolutionTask.value
        modelResolutionTask = nil
    }

    private func resolveModels() async {
        var availableModelIDs: [String] = []
        do {
            availableModelIDs = try await fetchAvailableModelIDs()
        } catch {
            print("⚠️ Nemotron: could not list models — \(error.localizedDescription)")
        }

        let nemotronModelIDs = availableModelIDs.filter { $0.lowercased().contains("nemotron") }
        let prefersFreeVariants = SaathiConfiguration.providerBaseURLString.contains("openrouter.ai")

        func bestMatch(_ isCandidate: (String) -> Bool) -> String? {
            let candidates = nemotronModelIDs.filter { isCandidate($0.lowercased()) }
            let rankedCandidates = candidates.sorted { firstModelID, secondModelID in
                let firstScore = Self.rankingScore(for: firstModelID, prefersFreeVariants: prefersFreeVariants)
                let secondScore = Self.rankingScore(for: secondModelID, prefersFreeVariants: prefersFreeVariants)
                if firstScore != secondScore { return firstScore > secondScore }
                return firstModelID < secondModelID
            }
            return rankedCandidates.first
        }

        let visionModelID = SaathiConfiguration.configuredVisionModelID
            ?? bestMatch { $0.contains("omni") }
            ?? bestMatch { $0.contains("vl") }
        let fastModelID = SaathiConfiguration.configuredFastModelID
            ?? bestMatch { $0.contains("nano") && !$0.contains("omni") && !$0.contains("vl") }
            ?? visionModelID
        let reasoningModelID = SaathiConfiguration.configuredReasoningModelID
            ?? bestMatch { $0.contains("super") }
            ?? fastModelID

        var resolvedModels: [NemotronModelRole: String] = [:]
        if let visionModelID { resolvedModels[.vision] = visionModelID }
        if let reasoningModelID { resolvedModels[.reasoning] = reasoningModelID }
        if let fastModelID { resolvedModels[.fast] = fastModelID }
        resolvedModelIDByRole = resolvedModels

        if resolvedModels.count == NemotronModelRole.allCases.count {
            modelResolutionStatusText = "Models ready"
        } else {
            let missingRoles = NemotronModelRole.allCases.filter { resolvedModels[$0] == nil }.map(\.rawValue)
            modelResolutionStatusText = "Missing models: \(missingRoles.joined(separator: ", ")). Set them in the .env file."
        }
        print("🧠 Nemotron models → vision: \(visionModelID ?? "none"), reasoning: \(reasoningModelID ?? "none"), fast: \(fastModelID ?? "none")")
    }

    /// Higher is better: prefer the Nemotron 3 generation, and free variants on OpenRouter.
    private static func rankingScore(for modelID: String, prefersFreeVariants: Bool) -> Int {
        let lowercasedModelID = modelID.lowercased()
        var score = 0
        if lowercasedModelID.contains("nemotron-3") || lowercasedModelID.contains("nemotron_3") || lowercasedModelID.contains("nemotron 3") {
            score += 10
        }
        if lowercasedModelID.hasSuffix(":free") {
            score += prefersFreeVariants ? 5 : -5
        }
        if lowercasedModelID.contains("fast") || lowercasedModelID.contains("fp8") {
            score += 1
        }
        return score
    }

    private func fetchAvailableModelIDs() async throws -> [String] {
        guard let modelsURL = URL(string: "\(SaathiConfiguration.providerBaseURLString)/models") else {
            throw NemotronClientError(message: "Invalid provider base URL")
        }
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        if let apiKey = SaathiConfiguration.providerAPIKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NemotronClientError(message: "Listing models failed (HTTP \(statusCode))")
        }
        guard let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelEntries = responseJSON["data"] as? [[String: Any]] else {
            return []
        }
        return modelEntries.compactMap { $0["id"] as? String }
    }

    // MARK: - Chat

    /// Sends a chat completion to the model for `role` and returns the reply text
    /// with any <think>…</think> reasoning removed.
    func complete(
        role: NemotronModelRole,
        messages: [NemotronChatMessage],
        purpose: String,
        maxTokens: Int = 1200,
        temperature: Double = 0.2
    ) async throws -> String {
        guard let apiKey = SaathiConfiguration.providerAPIKey else {
            throw NemotronClientError(message: "No API key. Add PROVIDER_API_KEY to the .env file (\(SaathiConfiguration.loadedEnvironmentFilePath)).")
        }

        guard estimatedTotalSpendInUSD < spendLimitInUSD else {
            throw NemotronClientError(message: String(format: "Spend limit reached ($%.2f of $%.2f). Raise SPEND_LIMIT_USD in the .env file to continue.", estimatedTotalSpendInUSD, spendLimitInUSD))
        }

        await resolveModelsIfNeeded()
        guard let modelID = resolvedModelIDByRole[role] else {
            throw NemotronClientError(message: "No \(role.rawValue) model available. \(modelResolutionStatusText)")
        }

        guard let completionsURL = URL(string: "\(SaathiConfiguration.providerBaseURLString)/chat/completions") else {
            throw NemotronClientError(message: "Invalid provider base URL")
        }

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if SaathiConfiguration.providerBaseURLString.contains("openrouter.ai") {
            request.setValue("Saathi", forHTTPHeaderField: "X-Title")
        }

        let requestBody: [String: Any] = [
            "model": modelID,
            "messages": messages.map(Self.makeRequestMessageDictionary),
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let requestStartDate = Date()

        // Busy or rate-limited providers (429, 5xx) usually recover within
        // seconds, so retry twice with a short wait before giving up.
        let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
        let retryDelaysInSeconds: [Double] = [2, 5]
        var responseData = Data()
        var response: URLResponse = URLResponse()
        for attemptIndex in 0...retryDelaysInSeconds.count {
            do {
                (responseData, response) = try await session.data(for: request)
            } catch {
                recordCall(role: role, modelID: modelID, purpose: purpose, startDate: requestStartDate, promptTokens: 0, completionTokens: 0, reportedCost: nil, succeeded: false)
                throw error
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard retryableStatusCodes.contains(statusCode), attemptIndex < retryDelaysInSeconds.count else {
                break
            }
            let retryDelayInSeconds = retryDelaysInSeconds[attemptIndex]
            print("⏳ Provider busy (HTTP \(statusCode)) — retrying in \(Int(retryDelayInSeconds))s")
            try await Task.sleep(nanoseconds: UInt64(retryDelayInSeconds * 1_000_000_000))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NemotronClientError(message: "Invalid response from provider")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            recordCall(role: role, modelID: modelID, purpose: purpose, startDate: requestStartDate, promptTokens: 0, completionTokens: 0, reportedCost: nil, succeeded: false)
            let errorBodyText = String(data: responseData, encoding: .utf8) ?? ""
            throw NemotronClientError(message: Self.friendlyErrorMessage(statusCode: httpResponse.statusCode, errorBodyText: errorBodyText))
        }

        guard let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw NemotronClientError(message: "Unexpected response format from provider")
        }

        let usage = responseJSON["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0
        let reportedCost = usage?["cost"] as? Double
        recordCall(role: role, modelID: modelID, purpose: purpose, startDate: requestStartDate, promptTokens: promptTokens, completionTokens: completionTokens, reportedCost: reportedCost, succeeded: true)

        let rawContentText: String
        if let contentString = message["content"] as? String {
            rawContentText = contentString
        } else if let contentParts = message["content"] as? [[String: Any]] {
            rawContentText = contentParts.compactMap { $0["text"] as? String }.joined()
        } else {
            rawContentText = ""
        }

        return Self.removeReasoningBlocks(from: rawContentText)
    }

    private static func makeRequestMessageDictionary(_ chatMessage: NemotronChatMessage) -> [String: Any] {
        if chatMessage.imageJPEGDataList.isEmpty {
            return ["role": chatMessage.role.rawValue, "content": chatMessage.text]
        }
        var contentParts: [[String: Any]] = chatMessage.imageJPEGDataList.map { imageData in
            [
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]
            ]
        }
        contentParts.append(["type": "text", "text": chatMessage.text])
        return ["role": chatMessage.role.rawValue, "content": contentParts]
    }

    private static func removeReasoningBlocks(from responseText: String) -> String {
        var cleanedText = responseText
        while let thinkStartRange = cleanedText.range(of: "<think>") {
            if let thinkEndRange = cleanedText.range(of: "</think>", range: thinkStartRange.upperBound..<cleanedText.endIndex) {
                cleanedText.removeSubrange(thinkStartRange.lowerBound..<thinkEndRange.upperBound)
            } else {
                cleanedText.removeSubrange(thinkStartRange.lowerBound..<cleanedText.endIndex)
            }
        }
        // Some templates emit only the closing tag after hidden reasoning.
        if let orphanThinkEndRange = cleanedText.range(of: "</think>") {
            cleanedText = String(cleanedText[orphanThinkEndRange.upperBound...])
        }
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendlyErrorMessage(statusCode: Int, errorBodyText: String) -> String {
        let shortenedBody = String(errorBodyText.prefix(300))
        switch statusCode {
        case 401, 403:
            return "The provider rejected the API key (HTTP \(statusCode)). Check PROVIDER_API_KEY in the .env file."
        case 402:
            return "The provider says the account is out of credit (HTTP 402)."
        case 429:
            return "Rate limited by the provider (HTTP 429). Wait a few seconds and try again."
        case 500, 502, 503, 504:
            return "The model is overloaded right now (HTTP \(statusCode)). Try again in a minute, or switch models in the .env file."
        default:
            return "Provider error (HTTP \(statusCode)): \(shortenedBody)"
        }
    }

    // MARK: - Cost tracking

    /// USD per million tokens (input, output). Token Factory list prices for the
    /// Nemotron 3 family; used only as an estimate for the spend cap.
    private static func estimatedPricePerMillionTokens(for role: NemotronModelRole) -> (input: Double, output: Double) {
        switch role {
        case .vision: return (0.10, 0.40)
        case .reasoning: return (0.30, 0.90)
        case .fast: return (0.06, 0.24)
        }
    }

    private func recordCall(
        role: NemotronModelRole,
        modelID: String,
        purpose: String,
        startDate: Date,
        promptTokens: Int,
        completionTokens: Int,
        reportedCost: Double?,
        succeeded: Bool
    ) {
        let isFreeModel = modelID.hasSuffix(":free")
        let estimatedCost: Double
        if let reportedCost {
            estimatedCost = reportedCost
        } else if isFreeModel {
            estimatedCost = 0
        } else {
            let prices = Self.estimatedPricePerMillionTokens(for: role)
            estimatedCost = (Double(promptTokens) * prices.input + Double(completionTokens) * prices.output) / 1_000_000
        }

        let callRecord = NemotronCallRecord(
            timestamp: startDate,
            role: role,
            modelID: modelID,
            purpose: purpose,
            latencyInSeconds: Date().timeIntervalSince(startDate),
            promptTokenCount: promptTokens,
            completionTokenCount: completionTokens,
            estimatedCostInUSD: estimatedCost,
            succeeded: succeeded
        )
        callRecords.insert(callRecord, at: 0)
        if callRecords.count > 200 {
            callRecords.removeLast(callRecords.count - 200)
        }

        estimatedTotalSpendInUSD += estimatedCost
        UserDefaults.standard.set(estimatedTotalSpendInUSD, forKey: spendStorageKey)

        print(String(format: "🧠 %@ [%@] %.2fs, %d in / %d out, ~$%.5f — %@", role.rawValue, modelID, callRecord.latencyInSeconds, promptTokens, completionTokens, estimatedCost, purpose))
    }

    // MARK: - JSON helper

    /// Models sometimes wrap JSON in prose or code fences. Pulls out the first
    /// top-level {...} object and parses it.
    static func extractFirstJSONObject(from responseText: String) -> [String: Any]? {
        guard let openingBraceIndex = responseText.firstIndex(of: "{") else {
            return nil
        }
        var braceDepth = 0
        var isInsideString = false
        var previousCharacterWasEscape = false
        var currentIndex = openingBraceIndex
        while currentIndex < responseText.endIndex {
            let character = responseText[currentIndex]
            if isInsideString {
                if previousCharacterWasEscape {
                    previousCharacterWasEscape = false
                } else if character == "\\" {
                    previousCharacterWasEscape = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth -= 1
                if braceDepth == 0 {
                    let jsonText = String(responseText[openingBraceIndex...currentIndex])
                    guard let jsonData = jsonText.data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
                }
            }
            currentIndex = responseText.index(after: currentIndex)
        }
        return nil
    }
}

// MARK: - Drop-in replacement for Clicky's ClaudeAPI in the question/answer flow

/// Keeps the same method shape as ClaudeAPI.analyzeImageStreaming so the
/// existing CompanionManager pipeline barely changes. Responses are not
/// streamed — the full reply is delivered in one chunk.
@MainActor
final class NemotronVisionChatClient {
    private let nemotronClient: NemotronClient

    init(nemotronClient: NemotronClient) {
        self.nemotronClient = nemotronClient
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartDate = Date()

        var chatMessages: [NemotronChatMessage] = [NemotronChatMessage(role: .system, text: systemPrompt)]
        for (userPlaceholder, assistantResponse) in conversationHistory {
            chatMessages.append(NemotronChatMessage(role: .user, text: userPlaceholder))
            chatMessages.append(NemotronChatMessage(role: .assistant, text: assistantResponse))
        }

        let imageLabelsText = images.enumerated()
            .map { imageIndex, image in "image \(imageIndex + 1): \(image.label)" }
            .joined(separator: "\n")
        let currentUserText = imageLabelsText.isEmpty ? userPrompt : "\(imageLabelsText)\n\n\(userPrompt)"
        chatMessages.append(NemotronChatMessage(role: .user, text: currentUserText, imageJPEGDataList: images.map(\.data)))

        let responseText = try await nemotronClient.complete(
            role: .vision,
            messages: chatMessages,
            purpose: "Answer spoken question about the screen",
            maxTokens: 1500,
            temperature: 0.4
        )
        onTextChunk(responseText)
        return (text: responseText, duration: Date().timeIntervalSince(requestStartDate))
    }
}
