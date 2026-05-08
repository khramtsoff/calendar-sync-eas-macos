import Foundation

/// Builds an `URLRequest` for an EAS command.
///
/// EAS supports two equivalent encodings:
///   - 14.x and earlier: query string `?Cmd=Foo&User=...&DeviceId=...&DeviceType=...`
///   - 14.1+: also accepts a "base64-encoded query string" header (MS-ASHTTP 2.2.1.1.2).
///
/// We use the legacy form which all servers understand.
///
/// The mailbox principal (`?User=`) and the HTTP-Basic credential are kept
/// separate, because on-prem Exchange servers commonly want
/// `Authorization: Basic base64(DOMAIN\user:pwd)` while `?User=` carries the
/// SMTP address of the mailbox.
struct EASRequestBuilder {
    let baseURL: URL
    /// Mailbox identity sent as `?User=`.
    let principal: String
    /// HTTP Basic login (e.g. `DOMAIN\user` or `user@domain`).
    let authLogin: String
    let password: String
    let deviceId: String
    let deviceType: String       // e.g. "iPhone"
    let userAgent: String        // e.g. "Apple-iPhone15C2/2106.83"
    let protocolVersion: String  // e.g. "14.1"
    let policyKey: String?

    func makeOptions() throws -> URLRequest {
        guard let url = optionsURL() else { throw EASError.invalidHost(baseURL.absoluteString) }
        var req = URLRequest(url: url)
        req.httpMethod = "OPTIONS"
        attachAuth(&req)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    func makeCommand(_ cmd: String, body: Data) throws -> URLRequest {
        guard let url = commandURL(cmd) else { throw EASError.invalidHost(baseURL.absoluteString) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/vnd.ms-sync.wbxml", forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.ms-sync.wbxml", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "MS-ASProtocolVersion")
        if let pk = policyKey, pk != "0", !pk.isEmpty {
            req.setValue(pk, forHTTPHeaderField: "X-MS-PolicyKey")
        }
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        attachAuth(&req)
        return req
    }

    private func optionsURL() -> URL? {
        var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comp?.path = "/Microsoft-Server-ActiveSync"
        comp?.queryItems = nil
        return comp?.url
    }

    private func commandURL(_ cmd: String) -> URL? {
        var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comp?.path = "/Microsoft-Server-ActiveSync"
        comp?.queryItems = [
            URLQueryItem(name: "Cmd", value: cmd),
            URLQueryItem(name: "User", value: principal),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "DeviceType", value: deviceType)
        ]
        return comp?.url
    }

    private func attachAuth(_ req: inout URLRequest) {
        let token = "\(authLogin):\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
}
