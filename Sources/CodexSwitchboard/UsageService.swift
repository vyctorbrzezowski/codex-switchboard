import Foundation

/// Fetches best-effort Codex usage data from chatgpt.com.
final class UsageService: Sendable {

    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private struct AccountMetadata: Sendable {
        let workspaceName: String?
        let planRenewalDate: Date?
    }

    // MARK: - Public

    func loadAll() async -> [Account] {
        let collection = AccountProfileStore.load()
        let profiles = collection.profiles
        let validKeys = collection.orderedKeys.filter { profiles[$0] != nil }

        // Demo mode: return mock data when all tokens are mock tokens.
        let allMock = validKeys.allSatisfy {
            (profiles[$0]?["access"] as? String)?.hasPrefix("mock_") == true
        }
        if allMock && !validKeys.isEmpty {
            return mockAccounts(for: profiles, keys: validKeys)
        }

        // Fetch usage concurrently
        let usages: [String: [String: Any]] = await withTaskGroup(
            of: (String, [String: Any]).self
        ) { group in
            for key in validKeys {
                if let tok = profiles[key]?["access"] as? String, !tok.isEmpty {
                    group.addTask { (key, await self.fetchUsage(token: tok)) }
                }
            }
            var map: [String: [String: Any]] = [:]
            for await (k, v) in group { map[k] = v }
            return map
        }

        var teamNames = TeamNameCacheStore.load()
        let workspaceNamedAccountIDs = workspaceNamedAccountIDs(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let metadataTokens = accountMetadataTokens(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let tokenAccountMetadata = await fetchAccountMetadata(for: metadataTokens)
        let accountMetadataByID = mergedAccountMetadata(from: tokenAccountMetadata)

        if !tokenAccountMetadata.isEmpty {
            var resolvedNames: [String: String] = [:]
            for tokenMap in tokenAccountMetadata.values {
                for (aid, metadata) in tokenMap
                where workspaceNamedAccountIDs.contains(aid)
                    && !aid.isEmpty
                    && metadata.workspaceName?.isEmpty == false
                    && metadata.workspaceName?.isGenericWorkspaceName == false {
                    guard let name = metadata.workspaceName else { continue }
                    if teamNames[aid] == nil || teamNames[aid]?.isGenericWorkspaceName == true {
                        teamNames[aid] = name
                    }
                    resolvedNames[aid] = name
                }
            }
            TeamNameCacheStore.save(resolvedNames)
        }

        // Build Account list
        var accounts: [Account] = []
        var seenEmails = Set<String>()

        for key in validKeys {
            guard let p = profiles[key], let usage = usages[key] else { continue }

            let email = (p["email"]     as? String)
                     ?? (usage["email"] as? String)
                     ?? (p["accountId"] as? String)
                     ?? key.components(separatedBy: ":").last ?? key

            let aid = (usage["account_id"] as? String) ?? (p["accountId"] as? String) ?? ""
            let dedup = "\(email.lowercased())|\(aid)"
            guard !seenEmails.contains(dedup) else { continue }
            seenEmails.insert(dedup)

            let usageError = usageErrorMessage(from: usage)
            let rl  = usage["rate_limit"]       as? [String: Any]
            let pw  = rl?["primary_window"]     as? [String: Any] ?? [:]
            let sw  = rl?["secondary_window"]   as? [String: Any] ?? [:]
            let hasUsage = usageError == nil && rl != nil
            let h5  = hasUsage ? (pw["used_percent"] as? Double ?? 0) : 100
            let wk  = hasUsage ? (sw["used_percent"] as? Double ?? 0) : 100

            let planType = resolvedPlanType(profile: p, usage: usage)
            let usesWorkspaceName = workspaceNamedAccountIDs.contains(aid)
            var ws = usesWorkspaceName ? teamNames[aid] : nil
            var planRenewalDate: Date?

            // Retry with the current account token when the real workspace name is unavailable.
            if let tok = p["access"] as? String,
               !tok.isEmpty {
                let metadata = tokenAccountMetadata[tok]?[aid] ?? accountMetadataByID[aid]
                if let metadata {
                    planRenewalDate = metadata.planRenewalDate

                    if usesWorkspaceName,
                       (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true),
                       let resolved = metadata.workspaceName,
                       !resolved.isEmpty {
                        ws = resolved
                        teamNames[aid] = resolved
                    } else if usesWorkspaceName,
                              (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true) {
                        // Last fallback: use any non-generic workspace name returned by this token.
                        if let tokenMap = tokenAccountMetadata[tok],
                           let anyRealName = tokenMap.values.compactMap(\.workspaceName).first(where: { !$0.isEmpty && !$0.isGenericWorkspaceName }) {
                            ws = anyRealName
                        }
                    }
                }
            }

            let workspaceName = ws
                ?? planType
                ?? "?"

            accounts.append(Account(
                id: dedup,
                profileKey: key,
                email: email,
                workspace: workspaceName,
                plan: planType ?? "?",
                sessionFree: max(0, 100 - h5),
                weeklyFree:  max(0, 100 - wk),
                sessionResetSeconds: pw["reset_after_seconds"] as? Double ?? 0,
                weeklyResetSeconds:  sw["reset_after_seconds"] as? Double ?? 0,
                planRenewalDate: planRenewalDate,
                hasError: !hasUsage,
                errorMessage: usageError ?? (rl == nil ? "Codex usage unavailable" : nil)
            ))
        }
        applyWorkspacePlanDates(to: &accounts)
        return accounts
    }

    // MARK: - Private Helpers

    private func fetchUsage(token: String) async -> [String: Any] {
        await apiGet("/backend-api/codex/usage", token: token)
    }

    private func fetchAccountMetadata(token: String) async -> [String: AccountMetadata] {
        let data = await apiGet("/backend-api/accounts/check/v4-2023-04-27", token: token)
        var result: [String: AccountMetadata] = [:]
        if let accts = data["accounts"] as? [String: [String: Any]] {
            for (aid, info) in accts {
                let account = info["account"] as? [String: Any]
                let entitlement = info["entitlement"] as? [String: Any]
                result[aid] = AccountMetadata(
                    workspaceName: account?["name"] as? String,
                    planRenewalDate: planRenewalDate(from: entitlement)
                )
            }
        }
        return result
    }

    private func fetchAccountMetadata(for tokens: Set<String>) async -> [String: [String: AccountMetadata]] {
        guard !tokens.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, [String: AccountMetadata]).self) { group in
            for token in tokens {
                group.addTask { (token, await self.fetchAccountMetadata(token: token)) }
            }

            var result: [String: [String: AccountMetadata]] = [:]
            for await (token, names) in group {
                result[token] = names
            }
            return result
        }
    }

    private func mergedAccountMetadata(
        from tokenAccountMetadata: [String: [String: AccountMetadata]]
    ) -> [String: AccountMetadata] {
        var result: [String: AccountMetadata] = [:]

        for metadataMap in tokenAccountMetadata.values {
            for (accountID, metadata) in metadataMap {
                guard !accountID.isEmpty else { continue }

                if let existing = result[accountID] {
                    result[accountID] = AccountMetadata(
                        workspaceName: existing.workspaceName ?? metadata.workspaceName,
                        planRenewalDate: existing.planRenewalDate ?? metadata.planRenewalDate
                    )
                } else {
                    result[accountID] = metadata
                }
            }
        }

        return result
    }

    private func applyWorkspacePlanDates(to accounts: inout [Account]) {
        var datesByWorkspace: [String: Date] = [:]

        for account in accounts {
            guard let date = account.planRenewalDate,
                  !account.workspace.isGenericWorkspaceName else { continue }
            datesByWorkspace[account.workspace] = date
        }

        guard !datesByWorkspace.isEmpty else { return }

        for index in accounts.indices where accounts[index].planRenewalDate == nil {
            let workspace = accounts[index].workspace
            guard !workspace.isGenericWorkspaceName,
                  let date = datesByWorkspace[workspace] else { continue }
            accounts[index].planRenewalDate = date
        }
    }

    private func apiGet(_ endpoint: String, token: String) async -> [String: Any] {
        guard let url = URL(string: "https://chatgpt.com\(endpoint)") else {
            return ["error": "bad URL"]
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.setValue(ua,                  forHTTPHeaderField: "User-Agent")
        req.setValue("application/json",  forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com",  forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9",   forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj["http_status"] = statusCode
                if !(200...299).contains(statusCode), obj["error"] == nil {
                    obj["error"] = readableAPIError(from: obj) ?? "HTTP \(statusCode)"
                }
                return obj
            }
        } catch {
            return ["error": error.localizedDescription]
        }
        return ["error": "parse error"]
    }

    private func usageErrorMessage(from data: [String: Any]) -> String? {
        if let detail = data["detail"] as? [String: Any],
           let code = detail["code"] as? String,
           !code.isEmpty {
            switch code {
            case "deactivated_workspace":
                return "Workspace deactivated"
            default:
                return code.replacingOccurrences(of: "_", with: " ")
            }
        }

        if let error = data["error"] as? String, !error.isEmpty {
            return error.replacingOccurrences(of: "_", with: " ")
        }

        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }

        if let status = data["http_status"] as? Int, !(200...299).contains(status) {
            return "HTTP \(status)"
        }

        return nil
    }

    private func readableAPIError(from data: [String: Any]) -> String? {
        if let detail = data["detail"] as? [String: Any],
           let code = detail["code"] as? String,
           !code.isEmpty {
            return code
        }
        if let detail = data["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private func accountMetadataTokens(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var tokens = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            if usage["error"] == nil,
               let token = profile["access"] as? String,
               !token.isEmpty {
                tokens.insert(token)
            }
        }

        return tokens
    }

    private func workspaceNamedAccountIDs(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var accountIDs = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            let accountID = (usage["account_id"] as? String) ?? (profile["accountId"] as? String) ?? ""
            guard !accountID.isEmpty else { continue }

            let planType = resolvedPlanType(profile: profile, usage: usage)
            if shouldUseWorkspaceName(planType: planType, accountID: accountID) {
                accountIDs.insert(accountID)
            }
        }

        return accountIDs
    }

    private func resolvedPlanType(
        profile: [String: Any],
        usage: [String: Any]
    ) -> String? {
        let planType = (usage["plan_type"] as? String) ?? (profile["plan"] as? String)
        let trimmed = planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private func shouldUseWorkspaceName(planType: String?, accountID: String) -> Bool {
        if accountID.isLikelyPersonalAccountID {
            return false
        }

        guard let planType else {
            return true
        }

        if planType.isUnknownPlanType {
            return true
        }

        return !planType.isPersonalPlanType
    }

    private func planRenewalDate(from entitlement: [String: Any]?) -> Date? {
        guard let entitlement else { return nil }
        return dateValue(entitlement["renews_at"])
            ?? dateValue(entitlement["expires_at"])
            ?? dateValue((entitlement["discount"] as? [String: Any])?["discount_expires_at"])
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            return Self.isoDateWithFractionalSeconds.date(from: string)
                ?? Self.isoDate.date(from: string)
        }

        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }

        if let number = value as? Int {
            let double = Double(number)
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }

        return nil
    }

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoDateWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func mockAccounts(for profiles: [String: [String: Any]], keys: [String]) -> [Account] {
        var accounts: [Account] = []
        var seen = Set<String>()
        let now = Date()
        let fixtures: [(workspace: String, plan: String, sessionFree: Double, weeklyFree: Double, hasError: Bool, errorMessage: String?)] = [
            ("Acme Engineering", "team", 82, 64, false, nil),
            ("startup.io", "plus", 35, 12, false, nil),
            ("plus", "plus", 8, 3, false, nil),
            ("OldCorp", "team", 0, 0, true, "Workspace deactivated"),
        ]
        for (index, key) in keys.enumerated() {
            guard let p = profiles[key] else { continue }
            let email = (p["email"] as? String) ?? key.components(separatedBy: ":").last ?? key
            let aid = (p["accountId"] as? String) ?? ""
            let dedup = "\(email.lowercased())|\(aid)"
            guard !seen.contains(dedup) else { continue }
            seen.insert(dedup)
            let f = fixtures[index % fixtures.count]
            accounts.append(Account(
                id: dedup,
                profileKey: key,
                email: email,
                workspace: f.workspace,
                plan: f.plan,
                sessionFree: f.sessionFree,
                weeklyFree: f.weeklyFree,
                sessionResetSeconds: 1800,
                weeklyResetSeconds: 86400 * 2 + 3600 * 5,
                planRenewalDate: f.hasError ? nil : now.addingTimeInterval(86400 * 14),
                hasError: f.hasError,
                errorMessage: f.errorMessage
            ))
        }
        return accounts
    }
}
