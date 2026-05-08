import Foundation

/// EAS Provision (MS-ASPROV).
///
/// Two-phase exchange:
///   Phase 1: client requests policy with PolicyKey="0" -> server replies with
///            a temporary PolicyKey and an EASProvisionDoc.
///   Phase 2: client acks with the temporary PolicyKey -> server replies with
///            the final, persistent PolicyKey.
///
/// We blindly accept whatever the server sends; this is a sync-only client,
/// not a security-enforcing MDM.
enum ProvisionCommand {
    static let policyType = "MS-EAS-Provisioning-WBXML"

    /// Builds the Phase 1 (initial) WBXML body.
    ///
    /// On EAS 14.1+ the spec recommends sending a `Settings:DeviceInformation`
    /// block alongside the Policies request so the server can register the
    /// device profile (model, OS, UA) at provision time. Older versions just
    /// ignore the extra element.
    static func makeInitialBody(fingerprint: DeviceFingerprint? = nil) throws -> Data {
        var children: [WBXMLNode] = []
        if let fp = fingerprint {
            children.append(makeDeviceInformation(fp))
        }
        children.append(WBXMLBuilder.el(.provision, "Policies", [
            WBXMLBuilder.el(.provision, "Policy", [
                WBXMLBuilder.leaf(.provision, "PolicyType", policyType)
            ])
        ]))
        let root = WBXMLBuilder.el(.provision, "Provision", children)
        return try WBXMLEncoder.encode(root)
    }

    /// Builds `<settings:DeviceInformation><settings:Set>...</settings:Set>`.
    /// Lives on the Settings code page even though the parent is Provision.
    private static func makeDeviceInformation(_ fp: DeviceFingerprint) -> WBXMLNode {
        WBXMLBuilder.el(.settings, "DeviceInformation", [
            WBXMLBuilder.el(.settings, "Set", [
                WBXMLBuilder.leaf(.settings, "Model", fp.model),
                WBXMLBuilder.leaf(.settings, "IMEI", fp.deviceId),
                WBXMLBuilder.leaf(.settings, "FriendlyName", fp.friendlyName),
                WBXMLBuilder.leaf(.settings, "OS", fp.os),
                WBXMLBuilder.leaf(.settings, "OSLanguage", fp.osLanguage),
                WBXMLBuilder.leaf(.settings, "PhoneNumber", ""),
                WBXMLBuilder.leaf(.settings, "MobileOperator", ""),
                WBXMLBuilder.leaf(.settings, "UserAgent", fp.userAgent)
            ])
        ])
    }

    /// Builds the Phase 2 (acknowledgement) body using the temporary key.
    static func makeAckBody(temporaryKey: String) throws -> Data {
        let root = WBXMLBuilder.el(.provision, "Provision", [
            WBXMLBuilder.el(.provision, "Policies", [
                WBXMLBuilder.el(.provision, "Policy", [
                    WBXMLBuilder.leaf(.provision, "PolicyType", policyType),
                    WBXMLBuilder.leaf(.provision, "PolicyKey", temporaryKey),
                    WBXMLBuilder.leaf(.provision, "Status", "1")
                ])
            ])
        ])
        return try WBXMLEncoder.encode(root)
    }

    struct Response {
        let overallStatus: Int
        let policyStatus: Int
        let policyKey: String?
    }

    static func parse(_ data: Data) throws -> Response {
        let root: WBXMLNode
        do {
            root = try WBXMLDecoder.decode(data)
        } catch {
            throw EASError.wbxml(error)
        }
        let overall = Int(root.string(.provision, "Status") ?? "0") ?? 0
        let policyNode = root.child(.provision, "Policies")?.child(.provision, "Policy")
        let policyStatus = Int(policyNode?.string(.provision, "Status") ?? "0") ?? 0
        let key = policyNode?.string(.provision, "PolicyKey")
        return Response(overallStatus: overall, policyStatus: policyStatus, policyKey: key)
    }
}
