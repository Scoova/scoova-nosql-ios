//
//  DocumentSnapshot.swift
//  ScoovaNoSQL
//

import Foundation

public struct DocumentSnapshot: Sendable {

    public let ref: DocumentReference
    public let documentID: String
    // Stored as Sendable JSONValue; converted to `[String: Any]` only at the
    // boundary so we get Swift 6 Sendable compliance for free.
    private let _data: [String: JSONValue]
    public let exists: Bool
    public let updateTime: Date?

    init(
        ref: DocumentReference,
        documentID: String,
        data: [String: Any],
        exists: Bool,
        updateTime: Date?
    ) {
        self.ref = ref
        self.documentID = documentID
        self._data = data.mapValues(JSONValue.init)
        self.exists = exists
        self.updateTime = updateTime
    }

    /// Raw field map. Returns `nil` if the document doesn't exist.
    public func data() -> [String: Any]? {
        exists ? _data.mapValues { $0.anyValue } : nil
    }

    /// Get a single field. Familiar from Firestore, useful for one-off reads.
    public func get(_ field: String) -> Any? { _data[field]?.anyValue }

    /// Decode the document into a Codable type. Uses `JSONSerialization` to
    /// re-encode the dict into JSON, then `JSONDecoder` to produce `T` — same
    /// pattern Firestore Swift uses, kept here so callers can drop in their
    /// existing `Codable` models with no changes.
    public func data<T: Decodable>(as type: T.Type, decoder: JSONDecoder = .scoovaDefault) throws -> T {
        guard exists else { throw ScoovaNoSQLError.notFound(documentID) }
        let plain = _data.mapValues { $0.anyValue }
        let raw = try JSONSerialization.data(withJSONObject: plain, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: raw)
    }
}

extension JSONDecoder {
    /// Decoder configured for the wire format the platform emits: ISO-8601
    /// dates, fractional-second precision, snake-case left intact (the wire
    /// format uses camelCase so no conversion needed).
    public static var scoovaDefault: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    public static var scoovaDefault: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
