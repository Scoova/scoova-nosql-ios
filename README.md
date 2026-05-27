# ScoovaNoSQL — iOS / macOS SDK

Document database client for Scoova NoSQL. Firestore-shaped Swift API,
backed by the multi-tenant Scoova platform. Talks to the same documents
the Android client writes; same security rules; same realtime channel.

```swift
import ScoovaNoSQL

// Once at app launch
ScoovaNoSQL.configure(
    projectId: "scoova",            // your tenant slug, injected at build time
    apiKey:    "nosql_…",           // tenant API key
    token:     userJwt              // optional, per-rider auth
)

let rides = ScoovaNoSQL.shared.collection("rides")

// Write
try await rides.document(rideId).setData([
    "distance":  8.4,
    "duration":  1820,
    "verified":  true,
    "startedAt": Date().timeIntervalSince1970,
])

// Merge fields without losing existing ones
try await rides.document(rideId).updateData(["distance": 9.1])

// Read
let snap = try await rides.document(rideId).getDocument()
if let data = snap.data() { print(data) }

// Codable
struct Ride: Codable { let distance: Double; let verified: Bool }
let ride = try snap.data(as: Ride.self)

// Query
let recent = try await rides
    .whereField("riderId",   isEqualTo: uid)
    .whereField("startedAt", isGreaterThan: Date().addingTimeInterval(-86_400 * 7).timeIntervalSince1970)
    .order(by: "startedAt", descending: true)
    .limit(to: 50)
    .getDocuments()

for doc in recent.documents { print(doc.documentID, doc.data() ?? [:]) }

// Realtime — async sequence
for try await snap in rides.document(rideId).snapshots() {
    print("ride updated:", snap.data() ?? [:])
}

// Realtime — Combine
let bag = rides.document(rideId)
    .snapshotPublisher()
    .sink(receiveCompletion: { _ in }, receiveValue: { snap in
        print(snap.data() ?? [:])
    })

// Delete (idempotent — succeeds even if already gone)
try await rides.document(rideId).delete()
```

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/Scoova/scoova-nosql-ios", from: "1.0.0")
```

### CocoaPods

```ruby
pod 'ScoovaNoSQL', '~> 1.0'
```

## Capabilities

| Op | Async | Realtime | Notes |
|----|:----:|:----:|----|
| `setData([:])` | ✓ | — | Upserts: merges into existing, creates if missing. |
| `updateData([:])` | ✓ | — | Strict merge; throws `.notFound` if doc missing. |
| `getDocument()` | ✓ | — | Throws `.notFound` if missing. |
| `delete()` | ✓ | — | Idempotent. |
| `getDocuments()` | ✓ | — | Returns `QuerySnapshot`. |
| `snapshots()` | ✓ | ✓ | Initial snapshot + live updates over one multiplexed WebSocket. |
| `snapshotPublisher()` | — | ✓ | Combine flavour of the above. |
| `whereField / order / limit` | ✓ | ✓ | Chainable, immutable. Same operators as Firestore. |

## Configuration

```swift
ScoovaNoSQL.configure(
    projectId:  "scoova",                                        // required
    apiKey:     "nosql_…",                                       // required
    token:      nil,                                             // optional bearer JWT
    baseURL:    URL(string: "https://cloud.scoo-va.info/nosql")!,// override for staging
    databaseId: "default"                                        // "(default)" also accepted
)

// After sign-in, set the bearer JWT:
ScoovaNoSQL.shared.setToken(jwt)

// Or sign out:
ScoovaNoSQL.shared.setToken(nil)
```

## Realtime: one WebSocket, many listeners

The SDK opens a single WebSocket to `wss://<host>/nosql/ws` and multiplexes
all active document / query listeners over it. Cancelling an `AsyncStream`
or a Combine subscription automatically sends `unlisten` to the server.

Connection drops cause an in-flight `network` error to be raised on every
active listener. Re-subscribing reconnects transparently.

## Querying

Filters and ordering are server-side. Available operators:

```
whereField(_, isEqualTo:)
whereField(_, isNotEqualTo:)
whereField(_, isLessThan:)
whereField(_, isLessThanOrEqualTo:)
whereField(_, isGreaterThan:)
whereField(_, isGreaterThanOrEqualTo:)
whereField(_, arrayContains:)
whereField(_, arrayContainsAny:)
whereField(_, in:)
whereField(_, notIn:)
order(by:_, descending:)
limit(to:)
```

## Testing

```sh
swift test            # unit tests (no network)
swift run LiveSmoke   # end-to-end against cloud.scoo-va.info (needs a project)
```

## License

MIT
