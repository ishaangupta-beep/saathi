//
//  SaathiConfiguration.swift
//  leanring-buddy
//
//  Reads provider settings (base URL, API keys, model IDs, spend limit)
//  from a plain KEY=VALUE `.env` file so keys never live in source code.
//
//  Lookup order (first file found wins):
//    1. ~/Library/Application Support/Saathi/config.env
//    2. <repo root>/.env  (repo root is derived from this file's compile-time path,
//       so a local Xcode build finds the .env next to the project)
//

import Foundation

enum SaathiConfiguration {

    /// The product name shown in the UI. Change it here to rebrand.
    static let productName = "Saathi"

    /// Folder for app data: config, saved skills.
    static let applicationSupportFolderURL: URL = {
        let baseFolderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let saathiFolderURL = baseFolderURL.appendingPathComponent("Saathi", isDirectory: true)
        try? FileManager.default.createDirectory(at: saathiFolderURL, withIntermediateDirectories: true)
        return saathiFolderURL
    }()

    /// <repo root>/.env — this source file lives at <repo root>/leanring-buddy/SaathiConfiguration.swift,
    /// so the repo root is two folders up from it.
    private static let repositoryEnvironmentFileURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".env")
    }()

    private static let applicationSupportEnvironmentFileURL: URL = {
        applicationSupportFolderURL.appendingPathComponent("config.env")
    }()

    /// Where the settings were loaded from, shown in the panel so it's obvious which file to edit.
    private(set) static var loadedEnvironmentFilePath: String = "not found"

    /// All KEY=VALUE pairs from the first env file found. Loaded once at launch.
    private static let environmentValues: [String: String] = {
        let candidateFileURLs = [applicationSupportEnvironmentFileURL, repositoryEnvironmentFileURL]
        for candidateFileURL in candidateFileURLs {
            guard let fileContents = try? String(contentsOf: candidateFileURL, encoding: .utf8) else {
                continue
            }
            loadedEnvironmentFilePath = candidateFileURL.path
            print("⚙️ Saathi config loaded from \(candidateFileURL.path)")
            return parseEnvironmentFileContents(fileContents)
        }
        print("⚠️ Saathi: no config.env or .env found. Expected one of: \(candidateFileURLs.map(\.path))")
        return [:]
    }()

    private static func parseEnvironmentFileContents(_ fileContents: String) -> [String: String] {
        var parsedValues: [String: String] = [:]
        for rawLine in fileContents.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }
            guard let equalsSignIndex = trimmedLine.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmedLine[..<equalsSignIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmedLine[trimmedLine.index(after: equalsSignIndex)...]).trimmingCharacters(in: .whitespaces)
            // Allow optional surrounding quotes: KEY="value"
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            parsedValues[key] = value
        }
        return parsedValues
    }

    private static func nonEmptyValue(forKey key: String) -> String? {
        guard let value = environmentValues[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Model provider (OpenAI-compatible: Nebius Token Factory or OpenRouter)

    /// e.g. https://api.tokenfactory.nebius.com/v1  or  https://openrouter.ai/api/v1
    static var providerBaseURLString: String {
        let configuredBaseURL = nonEmptyValue(forKey: "PROVIDER_BASE_URL") ?? "https://api.tokenfactory.nebius.com/v1"
        return configuredBaseURL.hasSuffix("/") ? String(configuredBaseURL.dropLast()) : configuredBaseURL
    }

    static var providerAPIKey: String? {
        nonEmptyValue(forKey: "PROVIDER_API_KEY")
    }

    static var isUsingNebiusTokenFactory: Bool {
        providerBaseURLString.contains("tokenfactory.nebius.com")
    }

    static var providerDisplayName: String {
        if isUsingNebiusTokenFactory { return "Nebius Token Factory" }
        if providerBaseURLString.contains("openrouter.ai") { return "OpenRouter (test)" }
        return URL(string: providerBaseURLString)?.host ?? "Custom provider"
    }

    /// Optional explicit model IDs. When blank, NemotronClient resolves them
    /// automatically from the provider's /models list.
    static var configuredVisionModelID: String? { nonEmptyValue(forKey: "VISION_MODEL") }
    static var configuredReasoningModelID: String? { nonEmptyValue(forKey: "REASONING_MODEL") }
    static var configuredFastModelID: String? { nonEmptyValue(forKey: "FAST_MODEL") }

    /// Hard stop: no model call is made once estimated spend reaches this.
    static var spendLimitInUSD: Double {
        if let configuredLimit = nonEmptyValue(forKey: "SPEND_LIMIT_USD"), let limit = Double(configuredLimit) {
            return limit
        }
        return 15.0
    }

    /// Token allowance for the quick Nemotron Nano calls (routing, skill
    /// matching, filling skill fields, naming skills). Nano thinks before it
    /// answers, so a small allowance can cut it off mid-thought.
    /// Set FAST_MAX_TOKENS=300 in .env to go back to the original, faster-but-
    /// cut-off behaviour; default 1000.
    static var fastCallMaxTokens: Int {
        if let configuredValue = nonEmptyValue(forKey: "FAST_MAX_TOKENS"), let tokenCount = Int(configuredValue), tokenCount > 0 {
            return tokenCount
        }
        return 1000
    }

    // MARK: - Tavily

    static var tavilyAPIKey: String? {
        nonEmptyValue(forKey: "TAVILY_API_KEY")
    }
}
