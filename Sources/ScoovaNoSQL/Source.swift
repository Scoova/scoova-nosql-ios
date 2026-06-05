//
//  Source.swift
//  ScoovaNoSQL
//
//  Read-source enum matching Firestore's `FirestoreSource`. Controls
//  whether `getDocument` / `getDocuments` consult the local cache, the
//  server, or both.
//

import Foundation

public enum Source: Sendable {
    /// Try cache first; if anything is cached, return it immediately AND
    /// kick a background refresh from the server. If cache is empty, fall
    /// back to a synchronous server fetch. Matches Firestore's `.default`.
    case `default`
    /// Always go to the network. Throws on offline.
    case server
    /// Only return cached data, even if stale or missing. Equivalent of
    /// Firestore's `.cache` — useful for offline-first paths.
    case cache
}
