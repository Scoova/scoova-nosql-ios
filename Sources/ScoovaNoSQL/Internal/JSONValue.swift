//
//  JSONValue.swift
//  ScoovaNoSQL
//
//  Minimal Codable JSON value enum.  The public API takes `Any` for ergonomic
//  parity with Firestore; on the way out, we coerce to this enum so the wire
//  encoding stays tight, ordered, and safe.
//

import Foundation

public enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ any: Any?) {
        switch any {
        case .none, is NSNull:                 self = .null
        case let v as Bool:                    self = .bool(v)
        case let v as Int:                     self = .int(Int64(v))
        case let v as Int64:                   self = .int(v)
        case let v as Float:                   self = .double(Double(v))
        case let v as Double:                  self = .double(v)
        case let v as NSNumber:
            // NSNumber is ambiguous re: Bool vs numeric; CFNumber tags decide.
            let tag = CFNumberGetType(v as CFNumber)
            if tag == .charType { self = .bool(v.boolValue) }
            else if CFNumberIsFloatType(v as CFNumber) { self = .double(v.doubleValue) }
            else { self = .int(v.int64Value) }
        case let v as String:                  self = .string(v)
        case let v as Date:                    self = .string(ISO8601DateFormatter().string(from: v))
        case let v as [Any?]:                  self = .array(v.map(JSONValue.init))
        case let v as [String: Any?]:          self = .object(v.mapValues(JSONValue.init))
        case let v as JSONValue:               self = v
        case .some(let other):
            // Last-resort: stringify so we never crash mid-write.
            self = .string(String(describing: other))
        }
    }

    /// Convert back to a plain Foundation type (Bool/Int64/Double/String/Array/Dict/NSNull).
    public var anyValue: Any {
        switch self {
        case .null:              return NSNull()
        case .bool(let b):       return b
        case .int(let i):        return i
        case .double(let d):     return d
        case .string(let s):     return s
        case .array(let a):      return a.map { $0.anyValue }
        case .object(let o):     return o.mapValues { $0.anyValue }
        }
    }

    // Codable
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                              { self = .null;             return }
        if let v = try? c.decode(Bool.self)           { self = .bool(v);          return }
        if let v = try? c.decode(Int64.self)          { self = .int(v);           return }
        if let v = try? c.decode(Double.self)         { self = .double(v);        return }
        if let v = try? c.decode(String.self)         { self = .string(v);        return }
        if let v = try? c.decode([JSONValue].self)    { self = .array(v);         return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v);   return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}
