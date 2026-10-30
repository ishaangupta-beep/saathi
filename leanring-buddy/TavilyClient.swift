//
//  TavilyClient.swift
//  leanring-buddy
//
//  Researches a task on the web before acting, so the agent follows the
//  official steps on the official site instead of guessing. Also powers
//  the lookalike-site check: if the page you're on doesn't match the
//  official domain Tavily found, Saathi warns you.
//

import Foundation

struct TavilyResearchResult {
    let summaryText: String
    let sourceTitlesAndURLs: [(title: String, url: URL)]

    /// Hosts of the sources, used for the official-site check.
    var officialHosts: [String] {
        sourceTitlesAndURLs.compactMap { $0.url.host?.lowercased() }
    }

    /// Text block handed to the planner.
    var promptText: String {
        var promptLines = ["Web research (official steps found before acting):", summaryText]
        for (title, url) in sourceTitlesAndURLs.prefix(4) {
            promptLines.append("- \(title): \(url.absoluteString)")
        }
        return promptLines.joined(separator: "\n")
    }
}

@MainActor
final class TavilyClient {
    static let shared = TavilyClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool {
        SaathiConfiguration.tavilyAPIKey != nil
    }

    /// Searches for the official steps for `taskDescription`. Returns nil when
    /// Tavily isn't configured or the search fails (the agent still works without it).
    func researchOfficialSteps(for taskDescription: String) async -> TavilyResearchResult? {
        guard let tavilyAPIKey = SaathiConfiguration.tavilyAPIKey,
              let searchURL = URL(string: "https://api.tavily.com/search") else {
            return nil
        }

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tavilyAPIKey)", forHTTPHeaderField: "Authorization")

        let requestBody: [String: Any] = [
            "query": "official website and step by step instructions: \(taskDescription) (India)",
            "search_depth": "basic",
            "max_results": 5,
            "include_answer": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let requestStartDate = Date()
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                print("⚠️ Tavily: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }

            let answerText = responseJSON["answer"] as? String ?? ""
            let resultEntries = responseJSON["results"] as? [[String: Any]] ?? []
            let sources: [(title: String, url: URL)] = resultEntries.compactMap { resultEntry in
                guard let urlString = resultEntry["url"] as? String, let url = URL(string: urlString) else { return nil }
                let title = resultEntry["title"] as? String ?? url.host ?? urlString
                return (title: title, url: url)
            }
            print(String(format: "🔎 Tavily research: %d sources in %.2fs", sources.count, Date().timeIntervalSince(requestStartDate)))
            return TavilyResearchResult(summaryText: answerText, sourceTitlesAndURLs: sources)
        } catch {
            print("⚠️ Tavily: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Official-site check

    /// The registrable part of a host: "services.passportindia.gov.in" → "passportindia.gov.in".
    static func registrableDomain(of host: String) -> String {
        let hostLabels = host.lowercased().split(separator: ".").map(String.init)
        guard hostLabels.count > 2 else { return host.lowercased() }
        let twoPartSuffixes: Set<String> = ["gov.in", "nic.in", "co.in", "org.in", "ac.in", "net.in", "co.uk", "gov.uk", "com.au"]
        let lastTwoLabels = hostLabels.suffix(2).joined(separator: ".")
        let labelCountToKeep = twoPartSuffixes.contains(lastTwoLabels) ? 3 : 2
        return hostLabels.suffix(labelCountToKeep).joined(separator: ".")
    }

    /// Returns the official domain to warn about when the current page's domain
    /// isn't among the official ones Tavily found, or nil when it's fine.
    static func officialDomainMismatchWarning(currentPageURL: URL?, research: TavilyResearchResult?) -> String? {
        guard let currentHost = currentPageURL?.host, let research, !research.officialHosts.isEmpty else {
            return nil
        }
        let currentDomain = registrableDomain(of: currentHost)
        let officialDomains = research.officialHosts.map(registrableDomain(of:))
        // Only warn for government-style official sites, where lookalikes are a real risk.
        let governmentOfficialDomains = officialDomains.filter { $0.hasSuffix(".gov.in") || $0.hasSuffix(".nic.in") || $0.hasSuffix(".gov") }
        guard let expectedOfficialDomain = governmentOfficialDomains.first else {
            return nil
        }
        if officialDomains.contains(currentDomain) {
            return nil
        }
        return expectedOfficialDomain
    }
}
