// AccountTesting.swift
//
// "Test Connection" for every account type in Preferences → Accounts.
// Each test makes the cheapest authenticated call the provider offers and
// returns a human-readable success line ("Connected as mroumanos") or throws
// a user-actionable error.  Tokens/keys come from the Keychain, keyed by the
// account id (see KeychainService).

import Foundation

enum AccountTestError: LocalizedError {
    case missingSecret(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingSecret(let what): return "No \(what) stored — add one first."
        case .failed(let message):     return message
        }
    }
}

enum AccountTesting {

    // MARK: - Storage backends

    /// Tests a backend account's credentials (GitHub/GitLab implemented).
    static func test(backend account: BackendAccount) async throws -> String {
        guard let token = KeychainService.secret(for: account.id), !token.isEmpty else {
            throw AccountTestError.missingSecret("personal access token")
        }
        switch account.provider {
        case .github:
            let login = try await GitHubBackendService().authenticatedLogin(token: token)
            return "Connected to GitHub as \(login)"
        case .gitlab:
            let user = try await getJSON(
                url: "https://gitlab.com/api/v4/user",
                headers: ["PRIVATE-TOKEN": token])
            let login = user["username"] as? String ?? "?"
            return "Connected to GitLab as \(login)"
        default:
            throw AccountTestError.failed("\(account.provider.rawValue) connections aren't implemented yet.")
        }
    }

    // MARK: - AI services

    /// Tests an AI service account's API key (Claude/OpenAI/Ollama implemented).
    static func test(aiService account: AIServiceAccount) async throws -> String {
        switch account.provider {
        case .claude:
            let key = try requireKey(for: account.id)
            _ = try await getJSON(
                url: "https://api.anthropic.com/v1/models",
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
            return "Connected to Anthropic"
        case .chatgpt:
            let key = try requireKey(for: account.id)
            _ = try await getJSON(
                url: "https://api.openai.com/v1/models",
                headers: ["Authorization": "Bearer \(key)"])
            return "Connected to OpenAI"
        case .ollama:
            _ = try await getJSON(url: "http://localhost:11434/api/tags", headers: [:])
            return "Connected to local Ollama"
        case .gemini:
            throw AccountTestError.failed("Gemini connections aren't implemented yet.")
        }
    }

    private static func requireKey(for id: UUID) throws -> String {
        guard let key = KeychainService.secret(for: id), !key.isEmpty else {
            throw AccountTestError.missingSecret("API key")
        }
        return key
    }

    // MARK: - HTTP

    private static func getJSON(url: String, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AccountTestError.failed("Could not reach the service: \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401, 403: throw AccountTestError.failed("The credentials were rejected (\(code)). Check the token/key.")
            default:       throw AccountTestError.failed("The service returned HTTP \(code).")
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0 } ?? [:]
    }
}
