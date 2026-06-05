//
//  ScoovaNoSQL.swift
//  ScoovaNoSQL
//
//  Public entry point. Mirrors the Android `ScoovaDataStore` shape so a single
//  team can move between platforms without retraining; mirrors Firestore's
//  Swift conventions so existing iOS devs can pick it up in minutes.
//

import Foundation

/// SDK entry point. Configure once at app launch, then read `shared` anywhere.
///
///     ScoovaNoSQL.configure(
///         projectId: "scoova",
///         apiKey: "sk_live_…",
///         token: nil          // optional bearer JWT for per-rider auth
///     )
///
///     let rides = ScoovaNoSQL.shared.collection("rides")
///     try await rides.document(rideId).setData(["distance": 8.4])
///
public final class ScoovaNoSQL: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance. Calling this before ``configure(_:)`` traps in debug.
    public static var shared: ScoovaNoSQL {
        guard let v = _shared else {
            fatalError(
                "ScoovaNoSQL.shared accessed before configure(). " +
                "Call ScoovaNoSQL.configure(projectId:apiKey:) at app launch."
            )
        }
        return v
    }
    private static var _shared: ScoovaNoSQL?

    // MARK: - Configuration

    /// Configure the SDK once at app launch.
    ///
    /// - Parameters:
    ///   - projectId: Tenant project slug (e.g. `"scoova"`). Every white-label
    ///     app gets its own project; the slug is compile-time injected at build.
    ///   - apiKey:    Public API key for the tenant. Required.
    ///   - token:     Optional bearer JWT for per-rider auth. If `nil`, the SDK
    ///                runs unauthenticated — fine for app-bootstrap reads
    ///                allowed by security rules, but writes will be rejected.
    ///   - baseURL:   Override for self-hosted or staging environments.
    ///   - databaseId: Reserved for future per-tenant DB sharding; default is `"(default)"`.
    public static func configure(
        projectId: String,
        apiKey: String,
        token: String? = nil,
        baseURL: URL = URL(string: "https://cloud.scoo-va.info/nosql")!,
        databaseId: String = "default"
    ) {
        // Accept "(default)" for Firestore-style callers; backend wants "default".
        let normalisedDb = databaseId == "(default)" ? "default" : databaseId
        let cfg = Configuration(
            projectId: projectId,
            apiKey: apiKey,
            token: token,
            baseURL: baseURL,
            databaseId: normalisedDb
        )
        _shared = ScoovaNoSQL(config: cfg)
    }

    /// Update the bearer token after sign-in / refresh without re-configuring.
    /// Fires-and-forgets the underlying actor updates; subsequent requests
    /// will use the new credentials.
    public func setToken(_ token: String?) {
        config = config.withToken(token)
        let key = config.apiKey
        Task { [apiClient, realtime] in
            await apiClient.updateAuth(apiKey: key, token: token)
            await realtime.updateAuth(apiKey: key, token: token)
        }
    }

    /// The active configuration. Treat as read-mostly; use ``setToken(_:)`` for refresh.
    public private(set) var config: Configuration

    // MARK: - Internal plumbing

    let apiClient: ApiClient
    let realtime: RealtimeClient
    /// Local SQLite-backed cache enabling Firestore-like offline reads,
    /// write-through, and pending-write replay. `nil` only if the cache
    /// failed to open (corrupt disk, missing permissions) — the SDK
    /// silently falls back to network-only mode in that case.
    let cache: PersistentCache?
    /// Background task driving pending-write replay. Held strong so the
    /// task isn't cancelled before the queue drains. Created on demand
    /// after the first failed network write.
    var pendingWriteReplayer: Task<Void, Never>?

    private init(config: Configuration) {
        self.config = config
        self.apiClient = ApiClient(config: config)
        self.realtime = RealtimeClient(config: config)
        self.cache = try? PersistentCache(
            projectId: config.projectId,
            databaseId: config.databaseId
        )
        // If the previous session left unconfirmed writes on disk, kick
        // the replay loop now so they go out as soon as the network is
        // reachable — without waiting for the next in-app write to fail.
        if let cache = cache, !cache.pendingWrites().isEmpty {
            // Schedule on the next runloop tick so `self` is fully
            // initialised when the Task captures it.
            DispatchQueue.main.async { [weak self] in
                self?.schedulePendingWriteReplay()
            }
        }
    }

    // MARK: - Database entry points

    /// Kick the background replay loop. Idempotent — if a replay task is
    /// already running, this is a no-op. Called by DocumentReference whenever
    /// a write fails the network round-trip and gets parked in the queue.
    func schedulePendingWriteReplay() {
        guard let cache = cache else { return }
        if let existing = pendingWriteReplayer, !existing.isCancelled { return }
        let apiClient = self.apiClient
        let cfg = self.config
        pendingWriteReplayer = Task { [weak self] in
            // Try to drain the queue with exponential backoff. Each pass:
            // walk every pending row, attempt its op, and on failure bump
            // retry_count + last_error then sleep before the next pass.
            var delaySec: UInt64 = 2
            while !Task.isCancelled {
                let pending = cache.pendingWrites()
                if pending.isEmpty {
                    self?.pendingWriteReplayer = nil
                    return
                }
                var allOk = true
                for w in pending {
                    do {
                        switch w.op {
                        case "set":
                            try await apiClient.upsertDocument(
                                projectId: cfg.projectId,
                                databaseId: cfg.databaseId,
                                collection: w.collection,
                                documentID: w.docId,
                                data: w.data ?? [:],
                                merge: false
                            )
                        case "update":
                            try await apiClient.upsertDocument(
                                projectId: cfg.projectId,
                                databaseId: cfg.databaseId,
                                collection: w.collection,
                                documentID: w.docId,
                                data: w.data ?? [:],
                                merge: true
                            )
                        case "delete":
                            try await apiClient.deleteDocument(
                                projectId: cfg.projectId,
                                databaseId: cfg.databaseId,
                                collection: w.collection,
                                documentID: w.docId
                            )
                        default:
                            // Unknown op — drop it so we don't loop forever.
                            break
                        }
                        cache.removePendingWrite(id: w.id)
                    } catch {
                        allOk = false
                        cache.recordPendingWriteFailure(
                            id: w.id,
                            error: String(describing: error)
                        )
                    }
                    if Task.isCancelled { return }
                }
                if allOk {
                    self?.pendingWriteReplayer = nil
                    return
                }
                // Back off; cap at 60 s. Next loop will re-read fresh
                // queue contents (caller might have enqueued more).
                try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
                delaySec = min(delaySec * 2, 60)
            }
            self?.pendingWriteReplayer = nil
        }
    }

    /// Return a reference to a collection at the root of the configured database.
    public func collection(_ path: String) -> CollectionReference {
        CollectionReference(
            sdk: self,
            collectionPath: path,
            databaseId: config.databaseId
        )
    }

    /// Return a reference to a database (defaults to `(default)`).  Provided
    /// for symmetry with the Android SDK and Firestore — most callers can
    /// skip straight to ``collection(_:)``.
    public func database(_ id: String? = nil) -> Database {
        Database(sdk: self, id: id ?? config.databaseId)
    }
}

// MARK: - Configuration

extension ScoovaNoSQL {

    public struct Configuration: Sendable {
        public let projectId: String
        public let apiKey: String
        public let token: String?
        public let baseURL: URL
        public let databaseId: String

        func withToken(_ newToken: String?) -> Configuration {
            Configuration(
                projectId: projectId,
                apiKey: apiKey,
                token: newToken,
                baseURL: baseURL,
                databaseId: databaseId
            )
        }
    }
}
