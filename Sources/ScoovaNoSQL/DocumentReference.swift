//
//  DocumentReference.swift
//  ScoovaNoSQL
//
//  Read/write/listen surface for a single document.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

public struct DocumentReference: Sendable {

    let sdk: ScoovaNoSQL
    public let collectionPath: String
    public let documentID: String
    public let databaseId: String

    /// Path the server sees, e.g. `rides/abc123`.
    public var path: String { "\(collectionPath)/\(documentID)" }

    // MARK: - Reads

    /// One-shot read using the default source (cache-then-server).
    public func getDocument() async throws -> DocumentSnapshot {
        try await getDocument(source: .default)
    }

    /// One-shot read with explicit source control.
    /// - `.default`: return cached value if present; refresh from server
    ///   in the background. If no cache, falls back to a synchronous fetch.
    /// - `.server`: always network. Throws on offline.
    /// - `.cache`: only the cache. Throws `notFound` if not cached.
    public func getDocument(source: Source) async throws -> DocumentSnapshot {
        // Cache-only: fail closed.
        if source == .cache {
            guard let cache = sdk.cache,
                  let data = cache.document(collection: collectionPath, id: documentID)
            else { throw ScoovaNoSQLError.notFound(documentID) }
            return DocumentSnapshot(
                ref: self, documentID: documentID,
                data: data, exists: true, updateTime: nil
            )
        }

        // .default and .server both end up reading from the network, but
        // .default returns the cached copy right away (if any) so the
        // caller can render immediately.
        if source == .default,
           let cache = sdk.cache,
           let cached = cache.document(collection: collectionPath, id: documentID)
        {
            // Fire-and-forget refresh so the cache is fresh for the next
            // call. The returned snapshot is the cached value — Firestore
            // does the same and exposes a "fromCache" metadata flag if
            // the caller cares.
            let sdkRef = sdk
            let col = collectionPath
            let doc = documentID
            let db = databaseId
            Task {
                if let raw = try? await sdkRef.apiClient.getDocument(
                    projectId: sdkRef.config.projectId,
                    databaseId: db,
                    collection: col,
                    documentID: doc
                ) {
                    cache.setDocument(collection: col, id: doc, data: raw.dataDictionary)
                }
            }
            return DocumentSnapshot(
                ref: self, documentID: documentID,
                data: cached, exists: true, updateTime: nil
            )
        }

        // No cache hit (or .server explicitly requested) — synchronous
        // fetch from the server.
        let raw = try await sdk.apiClient.getDocument(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            documentID: documentID
        )
        sdk.cache?.setDocument(
            collection: collectionPath,
            id: documentID,
            data: raw.dataDictionary
        )
        return DocumentSnapshot(
            ref: self,
            documentID: raw.id,
            data: raw.dataDictionary,
            exists: true,
            updateTime: raw.updatedAt
        )
    }

    // MARK: - Writes

    /// Create or overwrite the document.  Any fields not in `data` are dropped.
    public func setData(_ data: [String: Any]) async throws {
        // Write-through: cache reflects the intent immediately so listeners
        // and subsequent cache reads see the new value before the network
        // round-trip completes (Firestore's "latency compensation").
        sdk.cache?.setDocument(
            collection: collectionPath, id: documentID, data: data
        )
        do {
            try await sdk.apiClient.upsertDocument(
                projectId: sdk.config.projectId,
                databaseId: databaseId,
                collection: collectionPath,
                documentID: documentID,
                data: data,
                merge: false
            )
        } catch {
            // Persist the write so it can be replayed once connectivity
            // returns. The cache already has the value, so reads continue
            // to work offline.
            sdk.cache?.enqueueWrite(
                op: "set", collection: collectionPath,
                docId: documentID, merge: false, data: data
            )
            sdk.schedulePendingWriteReplay()
            throw error
        }
    }

    /// Merge `data` into the existing document — fields not present in
    /// `data` are preserved. Fails if the document doesn't exist.
    public func updateData(_ data: [String: Any]) async throws {
        sdk.cache?.mergeDocument(
            collection: collectionPath, id: documentID, data: data
        )
        do {
            try await sdk.apiClient.upsertDocument(
                projectId: sdk.config.projectId,
                databaseId: databaseId,
                collection: collectionPath,
                documentID: documentID,
                data: data,
                merge: true
            )
        } catch {
            sdk.cache?.enqueueWrite(
                op: "update", collection: collectionPath,
                docId: documentID, merge: true, data: data
            )
            sdk.schedulePendingWriteReplay()
            throw error
        }
    }

    /// Delete the document. Idempotent — succeeds even if already gone.
    public func delete() async throws {
        sdk.cache?.deleteDocument(collection: collectionPath, id: documentID)
        do {
            try await sdk.apiClient.deleteDocument(
                projectId: sdk.config.projectId,
                databaseId: databaseId,
                collection: collectionPath,
                documentID: documentID
            )
        } catch {
            sdk.cache?.enqueueWrite(
                op: "delete", collection: collectionPath,
                docId: documentID, merge: false, data: nil
            )
            sdk.schedulePendingWriteReplay()
            throw error
        }
    }

    // MARK: - Realtime listeners

    /// Live updates for this document. Emits the current value on subscribe,
    /// then re-emits on every change. Ends when the caller stops iterating
    /// (which sends `unlisten` to the server).
    public func snapshots() -> AsyncThrowingStream<DocumentSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Initial value — failure here propagates and ends the stream.
                    let first = try await self.getDocument()
                    continuation.yield(first)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                // Subscribe to live updates from the realtime channel.
                let sub = await self.sdk.realtime.listen(
                    collection: self.collectionPath,
                    documentID: self.documentID
                )
                do {
                    for try await change in sub.changes {
                        // Only forward events that match this document.
                        guard change.document.id == self.documentID else { continue }
                        let snap = DocumentSnapshot(
                            ref: self,
                            documentID: change.document.id,
                            data: change.document.dataDictionary,
                            exists: change.kind != .removed,
                            updateTime: change.document.updatedAt
                        )
                        continuation.yield(snap)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(Combine)
    /// Combine flavor of ``snapshots()``. Useful for SwiftUI / view models that
    /// already lean on Combine pipelines.
    public func snapshotPublisher() -> AnyPublisher<DocumentSnapshot, Error> {
        let subject = PassthroughSubject<DocumentSnapshot, Error>()
        let task = Task {
            do {
                for try await snap in snapshots() {
                    subject.send(snap)
                }
                subject.send(completion: .finished)
            } catch {
                subject.send(completion: .failure(error))
            }
        }
        return subject
            .handleEvents(receiveCancel: { task.cancel() })
            .eraseToAnyPublisher()
    }
    #endif
}
