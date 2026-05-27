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

    private init(config: Configuration) {
        self.config = config
        self.apiClient = ApiClient(config: config)
        self.realtime = RealtimeClient(config: config)
    }

    // MARK: - Database entry points

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
