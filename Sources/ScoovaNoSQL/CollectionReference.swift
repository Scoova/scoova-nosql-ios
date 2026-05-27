//
//  CollectionReference.swift
//  ScoovaNoSQL
//
//  A reference to a collection. Mirrors Firestore's API closely — same method
//  names, same return shapes — so migrating off Firestore is mostly a
//  find/replace on the import.
//

import Foundation

public struct CollectionReference: Sendable {

    let sdk: ScoovaNoSQL
    public let collectionPath: String
    public let databaseId: String

    /// Get a document reference by ID.
    public func document(_ documentID: String) -> DocumentReference {
        DocumentReference(
            sdk: sdk,
            collectionPath: collectionPath,
            documentID: documentID,
            databaseId: databaseId
        )
    }

    /// Add a document with an auto-generated ID.
    ///
    /// Returns the newly-created `DocumentReference` so callers can keep
    /// listening, updating, or capturing the assigned ID.
    @discardableResult
    public func addDocument(_ data: [String: Any]) async throws -> DocumentReference {
        let id = UUID().uuidString
        let doc = document(id)
        try await doc.setData(data)
        return doc
    }

    // MARK: - Query builder entry points
    //
    // Each of these returns a `Query` value rather than mutating self, so
    // chained builders never share state and are safe to compose / share.

    public func whereField(_ field: String, isEqualTo value: Any) -> Query {
        baseQuery().whereField(field, isEqualTo: value)
    }
    public func whereField(_ field: String, isNotEqualTo value: Any) -> Query {
        baseQuery().whereField(field, isNotEqualTo: value)
    }
    public func whereField(_ field: String, isLessThan value: Any) -> Query {
        baseQuery().whereField(field, isLessThan: value)
    }
    public func whereField(_ field: String, isLessThanOrEqualTo value: Any) -> Query {
        baseQuery().whereField(field, isLessThanOrEqualTo: value)
    }
    public func whereField(_ field: String, isGreaterThan value: Any) -> Query {
        baseQuery().whereField(field, isGreaterThan: value)
    }
    public func whereField(_ field: String, isGreaterThanOrEqualTo value: Any) -> Query {
        baseQuery().whereField(field, isGreaterThanOrEqualTo: value)
    }
    public func whereField(_ field: String, arrayContains value: Any) -> Query {
        baseQuery().whereField(field, arrayContains: value)
    }
    public func whereField(_ field: String, arrayContainsAny values: [Any]) -> Query {
        baseQuery().whereField(field, arrayContainsAny: values)
    }
    public func whereField(_ field: String, in values: [Any]) -> Query {
        baseQuery().whereField(field, in: values)
    }
    public func whereField(_ field: String, notIn values: [Any]) -> Query {
        baseQuery().whereField(field, notIn: values)
    }
    public func order(by field: String, descending: Bool = false) -> Query {
        baseQuery().order(by: field, descending: descending)
    }
    public func limit(to count: Int) -> Query {
        baseQuery().limit(to: count)
    }

    /// Fetch every document in the collection (no filtering). Equivalent to
    /// `query().getDocuments()`. Avoid on large collections.
    public func getDocuments() async throws -> QuerySnapshot {
        try await baseQuery().getDocuments()
    }

    /// Async sequence of snapshots for this collection. Sends an initial
    /// snapshot, then a new snapshot for every write.
    public func snapshots() -> AsyncThrowingStream<QuerySnapshot, Error> {
        baseQuery().snapshots()
    }

    // MARK: - Internals

    private func baseQuery() -> Query {
        Query(
            sdk: sdk,
            collectionPath: collectionPath,
            databaseId: databaseId,
            filters: [],
            orders: [],
            limitValue: nil
        )
    }
}
