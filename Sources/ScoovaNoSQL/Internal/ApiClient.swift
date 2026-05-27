//
//  ApiClient.swift
//  ScoovaNoSQL
//
//  Thin REST client backed by URLSession.  Endpoints (live-validated):
//
//     POST   v1/projects/{p}/databases/{d}/documents/{c}        body: {documentId,data}
//     PATCH  v1/projects/{p}/databases/{d}/documents/{c}/{id}   body: raw field map (merge only)
//     GET    v1/projects/{p}/databases/{d}/documents/{c}/{id}
//     GET    v1/projects/{p}/databases/{d}/documents/{c}        (list)
//     DELETE v1/projects/{p}/databases/{d}/documents/{c}/{id}   (idempotent)
//
//  setData() does PATCH-then-POST as a fallback to provide Firestore-style
//  upsert: existing docs are merged, missing ones are created. Avoids the
//  backend's POST-on-existing 500 conflict.
//

import Foundation

actor ApiClient {

    private var apiKey: String
    private var token: String?
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(config: ScoovaNoSQL.Configuration, session: URLSession = .shared) {
        self.apiKey   = config.apiKey
        self.token    = config.token
        self.baseURL  = config.baseURL
        self.session  = session

        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e

        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    func updateAuth(apiKey: String, token: String?) {
        self.apiKey = apiKey
        self.token  = token
    }

    // MARK: - Document ops

    func getDocument(
        projectId: String,
        databaseId: String,
        collection: String,
        documentID: String
    ) async throws -> ServerDocument {
        let url = endpoint(projectId, databaseId, collection, documentID)
        let (data, resp) = try await send(url, method: "GET", body: nil)
        try ensureSuccess(resp, data, expectingMissingAs: ScoovaNoSQLError.notFound(documentID))
        return try decode(ServerDocument.self, from: data)
    }

    /// Upsert.
    /// - merge:false → Firestore "set" semantics. Try PATCH (merges into
    ///   existing); on 404 (doc missing), POST to create. Caveat: existing
    ///   fields not in `data` are preserved, not cleared — the backend does
    ///   not currently support full-overwrite, so this matches its capability.
    /// - merge:true  → strict merge. PATCH only; throws if doc missing.
    func upsertDocument(
        projectId: String,
        databaseId: String,
        collection: String,
        documentID: String,
        data: [String: Any],
        merge: Bool
    ) async throws {
        let fields = data.mapValues(JSONValue.init)
        let patchURL = endpoint(projectId, databaseId, collection, documentID)
        let patchBody = try encoder.encode(fields)
        let (patchOut, patchResp) = try await send(patchURL, method: "PATCH", body: patchBody)

        let code = (patchResp as? HTTPURLResponse)?.statusCode ?? -1
        if (200..<300).contains(code) { return }

        // PATCH failed.  For strict merge, propagate.
        if merge {
            if code == 404 { throw ScoovaNoSQLError.notFound(documentID) }
            throw ScoovaNoSQLError.server(
                status: code,
                message: String(data: patchOut, encoding: .utf8) ?? ""
            )
        }
        // For setData fallback, create via POST when doc didn't exist.
        if code == 404 {
            let postURL = endpoint(projectId, databaseId, collection)
            let postBody = try encoder.encode(CreateDocumentRequest(
                documentId: documentID,
                data: fields
            ))
            let (postOut, postResp) = try await send(postURL, method: "POST", body: postBody)
            try ensureSuccess(postResp, postOut)
            return
        }
        // PATCH failed for some other reason.
        throw ScoovaNoSQLError.server(
            status: code,
            message: String(data: patchOut, encoding: .utf8) ?? ""
        )
    }

    func deleteDocument(
        projectId: String,
        databaseId: String,
        collection: String,
        documentID: String
    ) async throws {
        let url = endpoint(projectId, databaseId, collection, documentID)
        let (out, resp) = try await send(url, method: "DELETE", body: nil)
        // 404 on delete = already gone, treat as success.
        if (resp as? HTTPURLResponse)?.statusCode == 404 { return }
        try ensureSuccess(resp, out)
    }

    func listDocuments(
        projectId: String,
        databaseId: String,
        collection: String,
        filters: [Query.Filter],
        orders: [Query.Order],
        limit: Int?
    ) async throws -> [ServerDocument] {
        var comps = URLComponents(url: endpoint(projectId, databaseId, collection),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        // Filters: pass as `where[i].field=…&where[i].op=…&where[i].value=…`
        for (i, f) in filters.enumerated() {
            items.append(URLQueryItem(name: "where[\(i)].field", value: f.field))
            items.append(URLQueryItem(name: "where[\(i)].op",    value: f.op.rawValue))
            items.append(URLQueryItem(name: "where[\(i)].value",
                                       value: try jsonQueryString(f.value)))
        }
        for (i, o) in orders.enumerated() {
            items.append(URLQueryItem(name: "order[\(i)].field",      value: o.field))
            items.append(URLQueryItem(name: "order[\(i)].descending",
                                       value: o.descending ? "true" : "false"))
        }
        if let n = limit { items.append(URLQueryItem(name: "limit", value: String(n))) }
        comps.queryItems = items.isEmpty ? nil : items

        let (data, resp) = try await send(comps.url!, method: "GET", body: nil)
        try ensureSuccess(resp, data)
        if let envelope = try? decoder.decode(ListResponse.self, from: data) {
            return envelope.documents
        }
        // Tolerate bare arrays for future flexibility.
        return try decode([ServerDocument].self, from: data)
    }

    // MARK: - HTTP helpers

    private func send(
        _ url: URL,
        method: String,
        body: Data?
    ) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        do {
            return try await session.data(for: req)
        } catch {
            throw ScoovaNoSQLError.network(error.localizedDescription)
        }
    }

    private func ensureSuccess(
        _ resp: URLResponse,
        _ data: Data,
        expectingMissingAs notFoundErr: ScoovaNoSQLError? = nil
    ) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404, let err = notFoundErr { throw err }
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ScoovaNoSQLError.server(status: code, message: msg)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ScoovaNoSQLError.decoding(String(describing: error)) }
    }

    private func endpoint(
        _ project: String, _ db: String, _ collection: String, _ docId: String? = nil
    ) -> URL {
        var url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("projects")
            .appendingPathComponent(project)
            .appendingPathComponent("databases")
            .appendingPathComponent(db)
            .appendingPathComponent("documents")
            .appendingPathComponent(collection)
        if let id = docId { url.appendPathComponent(id) }
        return url
    }

    private func jsonQueryString(_ v: JSONValue) throws -> String {
        let data = try encoder.encode(v)
        return String(data: data, encoding: .utf8) ?? "null"
    }
}
