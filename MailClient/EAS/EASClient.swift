import Foundation

/// High-level EAS client. Stateless wrt server: every method takes the
/// inputs it needs and returns a parsed result. Sync state lives in
/// `SyncStateStore`.
struct EASClient {
    let baseURL: URL
    /// Mailbox identity sent as `?User=` query param.
    let principal: String
    /// HTTP Basic login (e.g. `DOMAIN\user`).
    let authLogin: String
    let password: String
    let fingerprint: DeviceFingerprint
    let session: URLSession

    /// We funnel diagnostics through `SyncLog.shared` so the lines appear in
    /// Settings → Log, not just unified logging.
    private let log = SyncLog.shared
    private let supportedClientVersions: [String] = ["14.1", "14.0", "12.1", "12.0"]

    init(host: String,
         principal: String,
         authLogin: String,
         password: String,
         fingerprint: DeviceFingerprint,
         session: URLSession? = nil) throws {
        let normalized = host.hasPrefix("http") ? host : "https://\(host)"
        guard let url = URL(string: normalized) else { throw EASError.invalidHost(host) }
        self.baseURL = url
        self.principal = principal
        self.authLogin = authLogin.isEmpty ? principal : authLogin
        self.password = password
        self.fingerprint = fingerprint
        self.session = session ?? Self.makeDefaultSession()
    }

    /// Tight per-request timeouts so a hung server can never park a sync
    /// task indefinitely. The 60s figure matches what iPhone Mail uses.
    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    // MARK: - Probe (OPTIONS)

    /// Issues an `OPTIONS /Microsoft-Server-ActiveSync` and parses the
    /// `MS-ASProtocolVersions`, `MS-ASProtocolCommands`, and
    /// `WWW-Authenticate` headers.
    func probe() async throws -> EASCapabilities {
        let builder = makeBuilder(version: "14.1", policyKey: nil)
        let req = try builder.makeOptions()
        log.info("OPTIONS \(req.url?.absoluteString ?? "?")")
        log.info("  request auth-login = '\(self.authLogin)' (\(self.authLogin.utf8.count) bytes), password \(self.password.utf8.count) bytes")

        let (data, response) = try await sendRaw(req)
        guard let http = response as? HTTPURLResponse else {
            throw EASError.unexpectedResponse("non-HTTP response to OPTIONS")
        }

        // Dump the full set of response headers so we can diagnose servers
        // that omit MS-ASProtocolVersions or use unusual auth schemes.
        log.info("OPTIONS → HTTP \(http.statusCode); headers:\n\(self.formattedHeaders(http))")

        let auth = http.value(forHTTPHeaderField: "WWW-Authenticate")

        if http.statusCode == 401 {
            // Surface 401 as an actual error so the UI doesn't pretend OPTIONS
            // "worked". We still attach the auth challenge so the user can see
            // the realm hint and we keep capabilities empty.
            let excerpt = bodyExcerpt(data)
            throw EASError.authRequired(challenge: auth, bodyExcerpt: excerpt)
        }

        if !(200..<300).contains(http.statusCode) {
            throw EASError.http(http.statusCode, data)
        }

        let versionsHeader = headerValue(http, named: "MS-ASProtocolVersions") ?? ""
        let cmdsHeader = headerValue(http, named: "MS-ASProtocolCommands") ?? ""
        let versions = versionsHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let commands = cmdsHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        // Some EAS implementations (Z-Push, Kerio Connect, Zimbra Mobile) reply
        // 200 OK to OPTIONS but skip the MS-ASProtocolVersions header. Falling
        // back to 14.1 — what real iPhones speak in this exact configuration —
        // keeps us flowing instead of hard-failing.
        let chosen: String?
        if versions.isEmpty {
            log.warn("Server did not advertise MS-ASProtocolVersions; falling back to 14.1.")
            chosen = "14.1"
        } else {
            chosen = pickVersion(serverVersions: versions)
        }

        return EASCapabilities(
            protocolVersions: versions.isEmpty ? ["14.1 (fallback, server did not advertise)"] : versions,
            supportedCommands: commands,
            authChallenge: auth,
            chosenVersion: chosen
        )
    }

    private func formattedHeaders(_ http: HTTPURLResponse) -> String {
        http.allHeaderFields
            .compactMap { (k, v) -> String? in
                guard let key = k as? String, let value = v as? String else { return nil }
                return "  \(key): \(value)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    /// Picks the highest mutually-supported version.
    private func pickVersion(serverVersions: [String]) -> String? {
        for client in supportedClientVersions {
            if serverVersions.contains(client) { return client }
        }
        return nil
    }

    // MARK: - Provision

    /// Performs the two-phase Provision exchange and returns the persistent PolicyKey.
    func provision(protocolVersion: String) async throws -> String {
        // Phase 1
        let includeDeviceInfo = !protocolVersion.hasPrefix("12.")
        let initialBody = try ProvisionCommand.makeInitialBody(
            fingerprint: includeDeviceInfo ? fingerprint : nil
        )
        let phase1 = try await sendCommand(name: "Provision",
                                           protocolVersion: protocolVersion,
                                           policyKey: "0",
                                           body: initialBody)
        let parsed1 = try ProvisionCommand.parse(phase1)

        guard parsed1.overallStatus == 1, parsed1.policyStatus == 1, let tempKey = parsed1.policyKey else {
            throw EASError.provisioningFailed(parsed1.overallStatus != 1 ? parsed1.overallStatus : parsed1.policyStatus)
        }

        // Phase 2
        let ackBody = try ProvisionCommand.makeAckBody(temporaryKey: tempKey)
        let phase2 = try await sendCommand(name: "Provision",
                                           protocolVersion: protocolVersion,
                                           policyKey: tempKey,
                                           body: ackBody)
        let parsed2 = try ProvisionCommand.parse(phase2)
        guard parsed2.overallStatus == 1, parsed2.policyStatus == 1, let finalKey = parsed2.policyKey else {
            throw EASError.provisioningFailed(parsed2.policyStatus)
        }
        return finalKey
    }

    // MARK: - FolderSync

    func folderSync(protocolVersion: String, policyKey: String, syncKey: String) async throws -> EASFolderSyncResult {
        let body = try FolderSyncCommand.makeBody(syncKey: syncKey)
        let data = try await sendCommandWithProvisionRecovery(
            name: "FolderSync",
            protocolVersion: protocolVersion,
            policyKey: policyKey,
            body: body
        )
        return try FolderSyncCommand.parse(data)
    }

    // MARK: - Sync (Calendar)

    func sync(collectionId: String,
              syncKey: String,
              protocolVersion: String,
              policyKey: String,
              windowSize: Int = 100,
              includeClass: Bool = false) async throws -> EASSyncResult? {
        let body = try SyncCommand.makeBody(
            collectionId: collectionId,
            syncKey: syncKey,
            windowSize: windowSize,
            protocolVersion: protocolVersion,
            includeClass: includeClass
        )
        let data = try await sendCommandWithProvisionRecovery(
            name: "Sync",
            protocolVersion: protocolVersion,
            policyKey: policyKey,
            body: body
        )
        return try SyncCommand.parse(data)
    }

    // MARK: - Internals

    private func makeBuilder(version: String, policyKey: String?) -> EASRequestBuilder {
        EASRequestBuilder(
            baseURL: baseURL,
            principal: principal,
            authLogin: authLogin,
            password: password,
            deviceId: fingerprint.deviceId,
            deviceType: fingerprint.deviceType,
            userAgent: fingerprint.userAgent,
            protocolVersion: version,
            policyKey: policyKey
        )
    }

    /// Sends a command and returns the response body. Maps HTTP status codes
    /// into `EASError` cases, including `provisioningRequired` on 449 (the
    /// legacy "retry after Provision" status).
    private func sendCommand(name: String,
                             protocolVersion: String,
                             policyKey: String?,
                             body: Data) async throws -> Data {
        let builder = makeBuilder(version: protocolVersion, policyKey: policyKey)
        let req = try builder.makeCommand(name, body: body)
        log.info("\(name) → \(req.url?.absoluteString ?? "?") (v\(protocolVersion), policyKey=\(policyKey ?? "0"))")
        log.info("  request body (\(body.count) bytes): \(self.hexPreview(body))")
        let (data, response) = try await sendRaw(req)
        guard let http = response as? HTTPURLResponse else {
            throw EASError.unexpectedResponse("non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            log.info("  \(name) ← \(http.statusCode) (\(data.count) bytes): \(self.hexPreview(data))")
            return data
        case 401:
            let challenge = headerValue(http, named: "WWW-Authenticate")
            let excerpt = bodyExcerpt(data)
            throw EASError.authRequired(challenge: challenge, bodyExcerpt: excerpt)
        case 449:
            // "Retry after sending a PROVISION command"
            throw EASError.provisioningRequired
        default:
            log.error("HTTP \(http.statusCode) on \(name); body excerpt: \(self.bodyExcerpt(data) ?? "(empty)")")
            throw EASError.http(http.statusCode, data)
        }
    }

    /// Hex-dump preview of a binary blob — first 128 bytes as `aa bb cc …`.
    /// Useful for diagnosing WBXML structure issues without dumping kilobytes.
    private func hexPreview(_ data: Data, limit: Int = 128) -> String {
        let prefix = data.prefix(limit)
        let hex = prefix.map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? "\(hex) … (+\(data.count - limit) bytes)" : hex
    }

    /// First N bytes of a response body, decoded as UTF-8 if possible.
    private func bodyExcerpt(_ data: Data, limit: Int = 240) -> String? {
        guard !data.isEmpty else { return nil }
        let slice = data.prefix(limit)
        if let s = String(data: slice, encoding: .utf8), !s.isEmpty {
            return s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return "<\(data.count) bytes binary>"
    }

    /// Sends the command, and if the server status code or HTTP status indicates
    /// "needs Provision", we run Provision once and retry.
    private func sendCommandWithProvisionRecovery(name: String,
                                                  protocolVersion: String,
                                                  policyKey: String,
                                                  body: Data) async throws -> Data {
        do {
            return try await sendCommand(name: name,
                                         protocolVersion: protocolVersion,
                                         policyKey: policyKey,
                                         body: body)
        } catch EASError.provisioningRequired {
            log.info("Server requested Provision via 449. Re-provisioning.")
            let newKey = try await provision(protocolVersion: protocolVersion)
            SyncStateStore.shared.mutate { $0.policyKey = newKey }
            return try await sendCommand(name: name,
                                         protocolVersion: protocolVersion,
                                         policyKey: newKey,
                                         body: body)
        }
    }

    private func sendRaw(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw EASError.transport(error)
        }
    }

    private func headerValue(_ http: HTTPURLResponse, named: String) -> String? {
        if let v = http.value(forHTTPHeaderField: named) { return v }
        // Fallback: case-insensitive scan for legacy servers.
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, key.caseInsensitiveCompare(named) == .orderedSame, let value = v as? String {
                return value
            }
        }
        return nil
    }
}
