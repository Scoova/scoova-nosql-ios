//
//  Wire.swift
//  ScoovaNoSQL
//
//  On-the-wire DTOs.  Internal types — never returned from the public API.
//  Live-validated against the running NoSQL server at cloud.scoo-va.info.
//

import Foundation

/// Server's representation of a single document. The wire shape is:
///
///     { "id": "abc",
///       "ref": { "collection": "...", "id": "...", "path": "..." },
///       "data": { …user fields… },
///       "exists": true,
///       "metadata": { … } }
///
/// We ignore unknown keys so adding fields server-side stays backward-compat.
struct ServerDocument: Decodable {
    let id: String
    let data: [String: JSONValue]
    let exists: Bool

    enum CodingKeys: String, CodingKey { case id, data, exists }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(String.self, forKey: .id)
        data   = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? true
    }

    /// Convenience: produce a plain dictionary for the public snapshot API.
    var dataDictionary: [String: Any] { data.mapValues { $0.anyValue } }
    /// Backend doesn't return write timestamps yet; placeholder for the API.
    var updatedAt: Date? { nil }
}

/// POST envelope.  Backend insists on `{documentId, data}`; field map is NOT
/// accepted bare for create.
struct CreateDocumentRequest: Encodable {
    let documentId: String
    let data: [String: JSONValue]
}

/// LIST response envelope.  `{documents, size, empty, metadata}`.
struct ListResponse: Decodable {
    let documents: [ServerDocument]
}

/// Realtime envelope on the WebSocket (matches the backend's RealtimeUpdate).
struct RealtimeUpdateWire: Decodable {
    let subscriptionId: String
    let changes: [DocumentChangeWire]
}

struct DocumentChangeWire: Decodable {
    let type: String                 // "ADDED" | "MODIFIED" | "REMOVED"
    let document: ServerDocument
}

// Outgoing WS frames -------------------------------------------------------

struct WSListenFrame: Encodable {
    let type = "listen"
    let collection: String
    let documentId: String?
    // Tenant scoping — required by the server to prevent cross-project leak.
    let projectId: String
    let databaseId: String
}
struct WSUnlistenFrame: Encodable {
    let type = "unlisten"
    let subscriptionId: String
}
struct WSPingFrame: Encodable {
    let type = "ping"
}
