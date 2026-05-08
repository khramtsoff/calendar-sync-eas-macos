import Foundation

/// Common EAS status codes (subset from MS-ASCMD §2.2.4.x). We only need
/// classification: success / retry-after-provision / hard fail.
enum EASStatus {
    case success
    case provisioningNeeded   // 142, 144 (and a few rare ones)
    case authRequired         // 401-equivalent at protocol layer
    case syncKeyInvalid       // 3, 12 - need to reset SyncKey
    case other(Int)

    static func classify(_ code: Int) -> EASStatus {
        switch code {
        case 1: return .success
        case 3, 12: return .syncKeyInvalid
        case 142, 144, 145: return .provisioningNeeded
        case 110, 111, 112: return .authRequired
        default: return .other(code)
        }
    }
}
