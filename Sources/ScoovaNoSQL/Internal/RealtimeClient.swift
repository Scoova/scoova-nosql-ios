//
//  RealtimeClient.swift
//  ScoovaNoSQL
//
//  Multiplexed WebSocket client for live updates.
//
//  Why multiplex: every snapshotListener creates a logical subscription.
//  Opening one WS per subscription would melt the device on a busy screen.
//  Instead we keep one connection to /ws and route incoming updates to the
//  right caller by `subscriptionId` (which the server stamps on every frame).
//
//  Why a single actor: WS state (socket, in-flight subs, ping timer) is mutable.
//  Wrapping it in an actor keeps callers concurrency-safe with one lock.
//

import Foundation

/// Internal handle for one active server-side subscription. Higher-level
/// types (`DocumentReference.snapshots()`, `Query.snapshots()`) hold one of
/// these for the lifetime of their async sequence; when the caller stops
/// iterating, the subscription is automatically released.
final class Subscription: @unchecked Sendable {

    let changes: AsyncThrowingStream<DocumentChangeWire, Error>
    fileprivate let continuation: AsyncThrowingStream<DocumentChangeWire, Error>.Continuation
    fileprivate weak var client: RealtimeClient?
    fileprivate var serverID: String?           // server-issued subscriptionId
    fileprivate let collection: String
    fileprivate let documentID: String?

    init(
        client: RealtimeClient,
        collection: String,
        documentID: String?
    ) {
        self.client = client
        self.collection = collection
        self.documentID = documentID
        var cont: AsyncThrowingStream<DocumentChangeWire, Error>.Continuation!
        self.changes = AsyncThrowingStream<DocumentChangeWire, Error> {
            cont = $0
        }
        self.continuation = cont
        self.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.client?.cancel(self) }
        }
    }

    func deliver(_ c: DocumentChangeWire) { continuation.yield(c) }
    func fail(_ err: Error)               { continuation.finish(throwing: err) }
    func finish()                         { continuation.finish() }
}

actor RealtimeClient {

    private var apiKey: String
    private var token: String?
    private let baseURL: URL
    private let projectId: String
    private let databaseId: String

    private var task: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var pendingByLocal: [ObjectIdentifier: Subscription] = [:]
    private var byServerID: [String: Subscription] = [:]

    init(config: ScoovaNoSQL.Configuration) {
        self.apiKey     = config.apiKey
        self.token      = config.token
        self.baseURL    = config.baseURL
        self.projectId  = config.projectId
        self.databaseId = config.databaseId
    }

    func updateAuth(apiKey: String, token: String?) {
        self.apiKey = apiKey
        self.token  = token
        // Cycle the socket so the next handshake uses the new credentials.
        Task { await self.reconnect() }
    }

    // MARK: - Public

    func listen(collection: String, documentID: String?) -> Subscription {
        let sub = Subscription(client: self, collection: collection, documentID: documentID)
        pendingByLocal[ObjectIdentifier(sub)] = sub
        Task { await self.ensureConnected(); await self.sendListen(sub) }
        return sub
    }

    func cancel(_ sub: Subscription) async {
        pendingByLocal.removeValue(forKey: ObjectIdentifier(sub))
        if let sid = sub.serverID {
            byServerID.removeValue(forKey: sid)
            let frame = WSUnlistenFrame(subscriptionId: sid)
            try? await sendJSON(frame)
        }
        sub.finish()
    }

    // MARK: - Connection lifecycle

    private func ensureConnected() async {
        if task != nil { return }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // baseURL is https://…/nosql — flip to wss://…/nosql/ws
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = (comps.path as NSString).appendingPathComponent("ws")
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let t = URLSession.shared.webSocketTask(with: req)
        t.resume()
        task = t
        receiverTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func reconnect() async {
        task?.cancel(with: .normalClosure, reason: nil)
        receiverTask?.cancel()
        task = nil
        byServerID.removeAll()
        await ensureConnected()
        // Re-issue every still-live subscription.
        for sub in pendingByLocal.values {
            sub.serverID = nil
            await sendListen(sub)
        }
    }

    private func sendListen(_ sub: Subscription) async {
        let frame = WSListenFrame(
            collection: sub.collection,
            documentId: sub.documentID,
            projectId: projectId,
            databaseId: databaseId
        )
        do { try await sendJSON(frame) }
        catch { sub.fail(error) }
    }

    private func sendJSON<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScoovaNoSQLError.invalidValue("frame is not UTF-8")
        }
        do { try await task?.send(.string(text)) }
        catch { throw ScoovaNoSQLError.network(error.localizedDescription) }
    }

    // MARK: - Receive

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s): await handle(text: s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { await handle(text: s) }
                @unknown default: break
                }
            } catch {
                // Connection dropped — propagate to every active subscription
                // and let them re-subscribe on the next listen() call.
                for sub in pendingByLocal.values {
                    sub.fail(ScoovaNoSQLError.network(error.localizedDescription))
                }
                pendingByLocal.removeAll()
                byServerID.removeAll()
                self.task = nil
                return
            }
        }
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        // Frames are tagged by `type`. Peek before fully decoding.
        struct Header: Decodable { let type: String? }
        let header = (try? JSONDecoder().decode(Header.self, from: data)) ?? Header(type: nil)
        switch header.type {
        case "subscribed":
            await onSubscribed(data)
        case "unsubscribed":
            // Server confirms unlisten — nothing to do; we already cleaned up locally.
            break
        case "error":
            await onError(data)
        case "connected", "pong":
            // Server keep-alives; ignore.
            break
        case nil:
            // No `type` key — likely a RealtimeUpdate envelope.
            await onUpdate(data)
        default:
            // Forward unknown typed frames as updates if they parse.
            await onUpdate(data)
        }
    }

    private func onSubscribed(_ data: Data) async {
        struct Ack: Decodable { let subscriptionId: String }
        guard let ack = try? JSONDecoder().decode(Ack.self, from: data) else { return }
        // Match by FIFO order — the server doesn't echo back what we asked
        // for, so the first un-matched local sub gets this serverID.
        if let next = pendingByLocal.first(where: { $0.value.serverID == nil })?.value {
            next.serverID = ack.subscriptionId
            byServerID[ack.subscriptionId] = next
        }
    }

    private func onError(_ data: Data) async {
        struct Err: Decodable { let message: String? }
        let msg = (try? JSONDecoder().decode(Err.self, from: data))?.message ?? "unknown"
        for sub in pendingByLocal.values where sub.serverID == nil {
            sub.fail(ScoovaNoSQLError.server(status: 0, message: msg))
        }
    }

    private func onUpdate(_ data: Data) async {
        guard let update = try? JSONDecoder().decode(RealtimeUpdateWire.self, from: data),
              let sub = byServerID[update.subscriptionId]
        else { return }
        for change in update.changes { sub.deliver(change) }
    }
}

// MARK: - Convenience extensions used by the public types

extension DocumentChangeWire {
    enum Kind { case added, modified, removed }
    /// Normalised, case-folded view of the wire `type` string.
    var kind: Kind {
        switch type.uppercased() {
        case "ADDED":    return .added
        case "REMOVED":  return .removed
        default:         return .modified
        }
    }
}
