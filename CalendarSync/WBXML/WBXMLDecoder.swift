import Foundation

enum WBXMLDecodingError: Error, LocalizedError {
    case unexpectedEOF
    case unsupportedVersion(UInt8)
    case unknownTokenAtRoot(UInt8)

    var errorDescription: String? {
        switch self {
        case .unexpectedEOF: return "WBXML: unexpected EOF"
        case .unsupportedVersion(let v): return "WBXML: unsupported version 0x\(String(v, radix: 16))"
        case .unknownTokenAtRoot(let t): return "WBXML: unexpected token 0x\(String(t, radix: 16)) at root"
        }
    }
}

/// Streaming WBXML decoder that produces a `WBXMLNode` tree.
///
/// Designed to be tolerant: unknown element tokens become elements with
/// synthetic name `unknown_<code>` so higher layers can ignore them safely.
final class WBXMLDecoder {
    private let dict = WBXMLTagDictionary.shared
    private let bytes: [UInt8]
    private var index = 0
    private var currentPage: WBXMLCodepage = .airSync

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    static func decode(_ data: Data) throws -> WBXMLNode {
        let decoder = WBXMLDecoder(data: data)
        return try decoder.run()
    }

    private func run() throws -> WBXMLNode {
        guard let version = read() else { throw WBXMLDecodingError.unexpectedEOF }
        // We accept any 1.x version (0x01..0x03).
        if version > 0x03 {
            throw WBXMLDecodingError.unsupportedVersion(version)
        }
        _ = try readMBUInt32() // publicId
        _ = try readMBUInt32() // charset
        let stLen = try readMBUInt32()
        // skip string table (we don't reference into it)
        try skip(Int(stLen))

        // Skip any leading SWITCH_PAGE before the root element.
        while peek() == WBXMLToken.switchPage {
            _ = read()
            guard let pageRaw = read(), let page = WBXMLCodepage(rawValue: pageRaw) else {
                throw WBXMLDecodingError.unexpectedEOF
            }
            currentPage = page
        }

        guard let token = read() else { throw WBXMLDecodingError.unexpectedEOF }
        return try readElement(token: token)
    }

    private func readElement(token: UInt8) throws -> WBXMLNode {
        let hasContent = (token & WBXMLToken.withContent) != 0
        let hasAttrs = (token & WBXMLToken.withAttrs) != 0
        let tag = token & 0x3F
        let name = dict.name(for: tag, page: currentPage) ?? "unknown_\(currentPage.rawValue)_\(String(tag, radix: 16))"
        let qName = WBXMLName(page: currentPage, name: name)

        if hasAttrs {
            // We don't emit attributes for EAS, but we still skip them gracefully.
            try skipAttributes()
        }

        guard hasContent else {
            return .element(qName, children: [])
        }

        var children: [WBXMLNode] = []
        loop: while true {
            guard let next = read() else { throw WBXMLDecodingError.unexpectedEOF }
            switch next {
            case WBXMLToken.end:
                break loop
            case WBXMLToken.switchPage:
                guard let pageRaw = read(), let page = WBXMLCodepage(rawValue: pageRaw) else {
                    throw WBXMLDecodingError.unexpectedEOF
                }
                currentPage = page
            case WBXMLToken.str_i:
                let s = try readCStringUTF8()
                children.append(.text(s))
            case WBXMLToken.opaque:
                let len = try readMBUInt32()
                let data = try readBytes(Int(len))
                if data.isEmpty {
                    children.append(.opaque(Data()))
                } else if let s = String(data: data, encoding: .utf8), s.utf8.count == data.count, !s.isEmpty {
                    // Heuristic: opaque used here as boxed text. Both EAS server
                    // and clients commonly do this for body/UID/MIME fields.
                    children.append(.text(s))
                } else {
                    children.append(.opaque(data))
                }
            case WBXMLToken.entity:
                _ = try readMBUInt32() // ignore
            case WBXMLToken.literal:
                _ = try readMBUInt32() // ignore literal tag
            default:
                children.append(try readElement(token: next))
            }
        }
        return .element(qName, children: children)
    }

    private func skipAttributes() throws {
        while let t = read() {
            if t == WBXMLToken.end { return }
        }
        throw WBXMLDecodingError.unexpectedEOF
    }

    // MARK: - Byte helpers

    private func read() -> UInt8? {
        guard index < bytes.count else { return nil }
        let b = bytes[index]
        index += 1
        return b
    }

    private func peek() -> UInt8? {
        guard index < bytes.count else { return nil }
        return bytes[index]
    }

    private func skip(_ count: Int) throws {
        guard index + count <= bytes.count else { throw WBXMLDecodingError.unexpectedEOF }
        index += count
    }

    private func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, index + count <= bytes.count else { throw WBXMLDecodingError.unexpectedEOF }
        let slice = Data(bytes[index..<(index + count)])
        index += count
        return slice
    }

    private func readMBUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<5 {
            guard let b = read() else { throw WBXMLDecodingError.unexpectedEOF }
            value = (value << 7) | UInt32(b & 0x7F)
            if (b & 0x80) == 0 { return value }
        }
        throw WBXMLDecodingError.unexpectedEOF
    }

    private func readCStringUTF8() throws -> String {
        var collected: [UInt8] = []
        while let b = read() {
            if b == 0 { return String(decoding: collected, as: UTF8.self) }
            collected.append(b)
        }
        throw WBXMLDecodingError.unexpectedEOF
    }
}
