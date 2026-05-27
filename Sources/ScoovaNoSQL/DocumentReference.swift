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

    /// One-shot read. Throws if the network fails or the document is missing.
    public func getDocument() async throws -> DocumentSnapshot {
        let raw = try await sdk.apiClient.getDocument(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            documentID: documentID
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
        try await sdk.apiClient.upsertDocument(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            documentID: documentID,
            data: data,
            merge: false
        )
    }

    /// Merge `data` into the existing document — fields not present in
    /// `data` are preserved. Fails if the document doesn't exist.
    public func updateData(_ data: [String: Any]) async throws {
        try await sdk.apiClient.upsertDocument(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            documentID: documentID,
            data: data,
            merge: true
        )
    }

    /// Delete the document. Idempotent — succeeds even if already gone.
    public func delete() async throws {
        try await sdk.apiClient.deleteDocument(
            projectId: sdk.config.projectId,
            databaseId: databaseId,
            collection: collectionPath,
            documentID: documentID
        )
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
