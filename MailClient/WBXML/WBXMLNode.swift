import Foundation

/// Page-qualified element name. EAS reuses the same XML local-name across
/// pages (e.g. `Status`, `Type`), so we always carry the page along.
struct WBXMLName: Equatable, Hashable, CustomStringConvertible {
    let page: WBXMLCodepage
    let name: String

    var description: String { "\(page):\(name)" }
}

/// A node in the parsed WBXML tree.
///
/// We keep elements simple: text content (mapped to `str_i`) and/or children.
/// EAS rarely needs attributes; opaque payload (used for protected data and
/// some calendar fields) is carried as `Data`.
indirect enum WBXMLNode: Equatable {
    case element(WBXMLName, children: [WBXMLNode])
    case text(String)
    case opaque(Data)

    var name: WBXMLName? {
        if case .element(let n, _) = self { return n }
        return nil
    }

    var children: [WBXMLNode] {
        if case .element(_, let c) = self { return c }
        return []
    }

    /// Concatenated `text` content of immediate children.
    var stringValue: String? {
        var pieces: [String] = []
        for child in children {
            if case .text(let s) = child { pieces.append(s) }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }

    /// First immediate child element with the given (page, name).
    func child(_ page: WBXMLCodepage, _ name: String) -> WBXMLNode? {
        for c in children {
            if case .element(let n, _) = c, n.page == page, n.name == name {
                return c
            }
        }
        return nil
    }

    /// All immediate child elements with the given (page, name).
    func children(_ page: WBXMLCodepage, _ name: String) -> [WBXMLNode] {
        children.compactMap { node -> WBXMLNode? in
            if case .element(let n, _) = node, n.page == page, n.name == name {
                return node
            }
            return nil
        }
    }

    func string(_ page: WBXMLCodepage, _ name: String) -> String? {
        child(page, name)?.stringValue
    }
}

/// Convenience builders for the encoder.
enum WBXMLBuilder {
    static func el(_ page: WBXMLCodepage, _ name: String, _ children: [WBXMLNode] = []) -> WBXMLNode {
        .element(WBXMLName(page: page, name: name), children: children)
    }

    static func leaf(_ page: WBXMLCodepage, _ name: String, _ value: String) -> WBXMLNode {
        .element(WBXMLName(page: page, name: name), children: [.text(value)])
    }

    static func leafOpaque(_ page: WBXMLCodepage, _ name: String, _ data: Data) -> WBXMLNode {
        .element(WBXMLName(page: page, name: name), children: [.opaque(data)])
    }
}
