import Foundation

enum WBXMLEncodingError: Error, LocalizedError {
    case unknownTag(WBXMLName)

    var errorDescription: String? {
        switch self {
        case .unknownTag(let name): return "Unknown WBXML tag \(name)"
        }
    }
}

/// Encodes a `WBXMLNode` tree into WBXML 1.3 binary suitable for an EAS POST.
///
/// Header layout (MS-ASWBXML 2.1.1):
///   version   = 0x03 (WBXML 1.3)
///   publicId  = 0x01 (unknown / use string table)  -> mb_u_int32 = 0x01
///   charset   = 0x6A (UTF-8) -> mb_u_int32 = 0x6A
///   strTbl    = 0x00 (empty length)
struct WBXMLEncoder {
    private let dict = WBXMLTagDictionary.shared
    private var output = Data()
    private var currentPage: WBXMLCodepage = .airSync

    static func encode(_ root: WBXMLNode) throws -> Data {
        var encoder = WBXMLEncoder()
        return try encoder.run(root)
    }

    private mutating func run(_ root: WBXMLNode) throws -> Data {
        // header
        output.append(0x03)
        output.append(0x01)
        appendMBUInt32(0x6A)
        output.append(0x00)

        // initial page comes from the root element
        if case .element(let name, _) = root {
            try ensurePage(name.page)
        }
        try writeNode(root)
        return output
    }

    private mutating func writeNode(_ node: WBXMLNode) throws {
        switch node {
        case .text(let s):
            output.append(WBXMLToken.str_i)
            if let bytes = s.data(using: .utf8) {
                output.append(bytes)
            }
            output.append(0x00)
        case .opaque(let data):
            output.append(WBXMLToken.opaque)
            appendMBUInt32(UInt32(data.count))
            output.append(data)
        case .element(let name, let children):
            try ensurePage(name.page)
            guard let baseCode = dict.code(for: name.name, page: name.page) else {
                throw WBXMLEncodingError.unknownTag(name)
            }
            if children.isEmpty {
                output.append(baseCode)
            } else {
                output.append(baseCode | WBXMLToken.withContent)
                for child in children {
                    try writeNode(child)
                }
                output.append(WBXMLToken.end)
            }
        }
    }

    private mutating func ensurePage(_ page: WBXMLCodepage) throws {
        guard page != currentPage else { return }
        output.append(WBXMLToken.switchPage)
        output.append(page.rawValue)
        currentPage = page
    }

    /// WBXML mb_u_int32: 7 bits per byte, MSB set on continuation bytes.
    private mutating func appendMBUInt32(_ value: UInt32) {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v != 0 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        output.append(contentsOf: bytes.reversed())
    }
}
