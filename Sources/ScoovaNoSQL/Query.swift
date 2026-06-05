//
//  Query.swift
//  ScoovaNoSQL
//
//  Immutable, chainable query builder. Every `whereField` / `order` / `limit`
//  returns a fresh `Query` so chains can be composed and reused without
//  surprising shared state.
//

import Foundation

public struct Query: Sendable {

    let sdk: ScoovaNoSQL
    public let collectionPath: String
    public let databaseId: String

    // Wire-friendly filter list.  Order matters; the server applies in sequence.
    let filters: [Filter]
    let orders: [Order]
    let limitValue: Int?

    public struct Filter: Sendable, Equatable {
        public let field: String
        public let op: Op
        public let value: JSONValue

        public enum Op: String, Sendable {
            case equal              = "EQUAL"
            case notEqual           = "NOT_EQUAL"
            case lessThan           = "LESS_THAN"
            case lessThanOrEqual    = "LESS_THAN_OR_EQUAL"
            case greaterThan        = "GREATER_THAN"
            case greaterThanOrEqual = "GREATER_THAN_OR_EQUAL"
            case arrayContains      = "ARRAY_CONTAINS"
            case arrayContainsAny   = "ARRAY_CONTAINS_ANY"
            case `in`               = "IN"
            case notIn              = "NOT_IN"
        }
    }

    public struct Order: Sendable, Equatable {
        public let field: String
        public let descending: Bool
    }

    // MARK: - Builder

    public func whereField(_ field: String, isEqualTo value: Any) -> Query {
        appending(.init(field: field, op: .equal, value: JSONValue(value)))
    }
    public func whereField(_ field: String, isNotEqualTo value: Any) -> Query {
        appending(.init(field: field, op: .notEqual, value: JSONValue(value)))
    }
    public func whereField(_ field: String, isLessThan value: Any) -> Query {
        appending(.init(field: field, op: .lessThan, value: JSONValue(value)))
    }
    public func whereField(_ field: String, isLessThanOrEqualTo value: Any) -> Query {
        appending(.init(field: field, op: .lessThanOrEqual, value: JSONValue(value)))
    }
    public func whereField(_ field: String, isGreaterThan value: Any) -> Query {
        appending(.init(field: field, op: .greaterThan, value: JSONValue(value)))
    }
    public func whereField(_ field: String, isGreaterThanOrEqualTo value: Any) -> Query {
        appending(.init(field: field, op: .greaterThanOrEqual, value: JSONValue(value)))
    }
    public func whereField(_ field: String, arrayContains value: Any) -> Query {
        appending(.init(field: field, op: .arrayContains, value: JSONValue(value)))
    }
    public func whereField(_ field: String, arrayContainsAny values: [Any]) -> Query {
        appending(.init(field: field, op: .arrayContainsAny, value: JSONValue(values)))
    }
    public func whereField(_ field: String, in values: [Any]) -> Query {
        appending(.init(field: field, op: .in, value: JSONValue(values)))
    }
    public func whereField(_ field: String, notIn values: [Any]) -> Query {
        appending(.init(field: field, op: .notIn, value: JSONValue(values)))
    }

    public func order(by field: String, descending: Bool = false) -> Query {
        Query(
            sdk: sdk,
            collectionPath: collectionPath,
            databaseId: databaseId,
            filters: filters,
            orders: orders + [Order(field: field, descending: descending)],
            limitValue: limitValue
        )
    }

    public func limit(to count: Int) -> Query {
        Query(
            sdk: sdk,
            collectionPath: collectionPath,
            databaseId: databaseId,
            filters: filters,
            orders: orders,
            limitValue: count
        )
    }

    // MARK: - Execute

    /// Run the query once using the default source (cache-then-server).
    public func getDocuments() async throws -> QuerySnapshot {
        try await getDocuments(source: .default)
    }

    /// Run the query with explicit source control. Behavior matches the
    /// `DocumentReference.getDocument(source:)` contract:
    /// - `.default`: return cached results immediately (if any); refresh
    ///   from the server in the background. Falls back to a network call
    ///   on a cold cache.
    /// - `.server`: always go to the network. Refreshes the cache.
    /// - `.cache`: only the cache. Empty result if the query has never
    ///   been fetched.
    public func getDocuments(source: Source) async throws -> QuerySnapshot {
        let qhash = Self.queryHash(
            collection: collectionPath,
            filters: filters, orders: orders, limit: limitValue
        )

        if source == .cache {
            let cached = sdk.cache?.queryResults(qhash) ?? []
            return QuerySnapshot(
                documents: cached.map { (id, data) in
                    DocumentSnapshot(
                        ref: DocumentReference(
                            sdk: sdk,
                            collectionPath: collectionPath,
                            documentID: id,
                            databaseId: databaseId
                        ),
                        documentID: id,
                        data: data,
                        exists: true,
                        updateTime: nil
                    )
                }
            )
        }

        if source == .default,
           let cache = sdk.cache,
           case let cachedRows = cache.queryResults(qhash),
           !cachedRows.isEmpty
        {
            // Refresh in the background; return cached docs synchronously.
            let sdkRef = sdk
            let col = collectionPath
            let db = databaseId
            let f = filters
            let o = orders
            let l = limitValue
            Task {
                guard let fresh = try? await sdkRef.apiClient.listDocuments(
                    projectId: sdkRef.config.projectId,
                    databaseId: db,
                    collection: col,
                    filters: f, orders: o, limit: l
                ) else { return }
                for raw in fresh {
                    cache.setDocument(
                        collection: col, id: raw.id, data: raw.dataDictionary
                    )
                }
                cache.setQueryResults(qhash, docIds: fresh.map { $0.id })
            }
            return QuerySnapshot(
                documents: cachedRows.map { (id, data) in
                    DocumentSnapshot(
                        ref: DocumentReference(
                            sdk: sdk,
                            collectionPath: collectionPath,
                            documentID: id,
                            databaseId: databaseId
                        ),
                        documentID: id, data: data,
                        exists: true, updateTime: nil
                    )
                }
            )
        }

        // Cold cache (or .server) — network fetch with cache write-through.
        let docs = try await sdk.apiClient.listDocuments(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            filters: filters,
            orders: orders,
            limit: limitValue
        )
        if let cache = sdk.cache {
            for raw in docs {
                cache.setDocument(
                    collection: collectionPath, id: raw.id, data: raw.dataDictionary
                )
            }
            cache.setQueryResults(qhash, docIds: docs.map { $0.id })
        }
        return QuerySnapshot(
            documents: docs.map { raw in
                DocumentSnapshot(
                    ref: DocumentReference(
                        sdk: sdk,
                        collectionPath: collectionPath,
                        documentID: raw.id,
                        databaseId: databaseId
                    ),
                    documentID: raw.id,
                    data: raw.dataDictionary,
                    exists: true,
                    updateTime: raw.updatedAt
                )
            }
        )
    }

    /// Stable string hash of this query, used as the cache key.
    private static func queryHash(
        collection: String,
        filters: [Filter], orders: [Order], limit: Int?
    ) -> String {
        let fTuples = filters.map { (
            field: $0.field, op: $0.op.rawValue,
            value: String(describing: $0.value)
        ) }
        let oTuples = orders.map { (field: $0.field, descending: $0.descending) }
        return PersistentCache.hashQuery(
            collection: collection,
            filters: fTuples, orders: oTuples, limit: limit
        )
    }

    /// Live, ordered, filtered view. Emits the current result, then re-emits
    /// whenever any matching document changes.  Server-side filtering means
    /// the client never has to throw away non-matching events.
    public func snapshots() -> AsyncThrowingStream<QuerySnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Cache full current state and re-emit on every change.
                var byID: [String: DocumentSnapshot] = [:]
                do {
                    let initial = try await self.getDocuments()
                    for snap in initial.documents { byID[snap.documentID] = snap }
                    continuation.yield(QuerySnapshot(documents: Array(byID.values)))
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let sub = await self.sdk.realtime.listen(
                    collection: self.collectionPath,
                    documentID: nil
                )
                do {
                    for try await change in sub.changes {
                        switch change.kind {
                        case .added, .modified:
                            byID[change.document.id] = DocumentSnapshot(
                                ref: DocumentReference(
                                    sdk: self.sdk,
                                    collectionPath: self.collectionPath,
                                    documentID: change.document.id,
                                    databaseId: self.databaseId
                                ),
                                documentID: change.document.id,
                                data: change.document.dataDictionary,
                                exists: true,
                                updateTime: change.document.updatedAt
                            )
                        case .removed:
                            byID.removeValue(forKey: change.document.id)
                        }
                        continuation.yield(QuerySnapshot(documents: Array(byID.values)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func appending(_ f: Filter) -> Query {
        Query(
            sdk: sdk,
            collectionPath: collectionPath,
            databaseId: databaseId,
            filters: filters + [f],
            orders: orders,
            limitValue: limitValue
        )
    }
}
