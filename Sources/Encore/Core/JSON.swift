import Foundation

/// Loosely-typed JSON value used to walk InnerTube responses defensively.
/// Every accessor returns `.null` instead of failing, so unknown or changed
/// response shapes degrade to "missing data" rather than crashes.
@dynamicMemberLookup
enum JSON: Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(_ any: Any?) {
        switch any {
        case let d as [String: Any]: self = .object(d.mapValues { JSON($0) })
        case let a as [Any]: self = .array(a.map { JSON($0) })
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        default: self = .null
        }
    }

    init(data: Data) throws {
        self = JSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(dynamicMember key: String) -> JSON { self[key] }

    subscript(key: String) -> JSON {
        if case .object(let d) = self { return d[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var exists: Bool { !isNull }

    /// Joined text of a `runs` / `simpleText` text object.
    /// NOTE: the raw "text" key must be read with `node["text"]` because this
    /// property shadows dynamic member lookup for that name.
    var text: String? {
        if let s = self["simpleText"].string { return s }
        if case .string(let s) = self { return s }
        let runs = self["runs"].array
        if runs.isEmpty { return nil }
        return runs.compactMap { $0["text"].string }.joined()
    }

    /// First value found for `key` anywhere beneath this node (depth-first).
    func find(_ key: String) -> JSON {
        switch self {
        case .object(let d):
            if let v = d[key] { return v }
            for (_, v) in d { let r = v.find(key); if r.exists { return r } }
        case .array(let a):
            for v in a { let r = v.find(key); if r.exists { return r } }
        default: break
        }
        return .null
    }

    /// All values for `key` anywhere beneath this node.
    func findAll(_ key: String, into out: inout [JSON]) {
        switch self {
        case .object(let d):
            for (k, v) in d {
                if k == key { out.append(v) } else { v.findAll(key, into: &out) }
            }
        case .array(let a):
            for v in a { v.findAll(key, into: &out) }
        default: break
        }
    }
    func findAll(_ key: String) -> [JSON] { var r: [JSON] = []; findAll(key, into: &r); return r }

    /// Converts back to Foundation types for re-serialisation.
    var foundation: Any {
        switch self {
        case .object(let d): return d.mapValues { $0.foundation }
        case .array(let a): return a.map { $0.foundation }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}
