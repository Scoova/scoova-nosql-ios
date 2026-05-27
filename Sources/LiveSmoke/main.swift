//
//  Live end-to-end smoke test for ScoovaNoSQL against cloud.scoo-va.info.
//  Run from package root:   swift run LiveSmoke
//

import Foundation
import ScoovaNoSQL

let projectId = "scoova"
let apiKey    = "nosql_scoova_db83bc97872be1f1b6f62561cc062def"

ScoovaNoSQL.configure(projectId: projectId, apiKey: apiKey)
let rides = ScoovaNoSQL.shared.collection("ios_smoke_rides")
let id    = "smoke-\(Int(Date().timeIntervalSince1970))"
let ref   = rides.document(id)

func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }

print("--- 1) setData (upsert, doc missing → POST fallback) ---")
do {
    try await ref.setData([
        "distance":  8.4,
        "duration":  1820,
        "verified":  true,
        "tags":      ["fast", "smooth"],
        "startedAt": Date().timeIntervalSince1970,
    ])
    print("    PASS")
} catch { fail("\(error)") }

print("--- 2) getDocument ---")
do {
    let snap = try await ref.getDocument()
    guard let data = snap.data() else { fail("nil data") }
    guard let dist = data["distance"] as? Double, dist == 8.4 else {
        fail("distance != 8.4 -> \(String(describing: data["distance"]))")
    }
    print("    PASS  data=\(data)")
} catch { fail("\(error)") }

print("--- 3) updateData (PATCH merge) ---")
do {
    try await ref.updateData(["distance": 9.1, "newField": "added"])
    let snap = try await ref.getDocument()
    let data = snap.data() ?? [:]
    guard let d = data["distance"] as? Double, d == 9.1 else { fail("distance not merged: \(data)") }
    guard data["newField"] as? String == "added" else { fail("newField missing: \(data)") }
    guard data["verified"] as? Bool == true else { fail("verified not preserved: \(data)") }
    print("    PASS  merged data=\(data)")
} catch { fail("\(error)") }

print("--- 4) list collection ---")
do {
    let snap = try await rides.getDocuments()
    print("    docs returned: \(snap.count)")
    guard snap.documents.contains(where: { $0.documentID == id }) else {
        fail("didn't see our doc in the list")
    }
    print("    PASS")
} catch { fail("\(error)") }

print("--- 5) Codable decode ---")
struct Ride: Codable {
    let distance: Double
    let verified: Bool
    let newField: String
}
do {
    let snap = try await ref.getDocument()
    let r = try snap.data(as: Ride.self)
    print("    PASS  decoded: distance=\(r.distance) verified=\(r.verified) newField=\(r.newField)")
} catch { fail("\(error)") }

print("--- 6) delete + verify ---")
do {
    try await ref.delete()
    do {
        _ = try await ref.getDocument()
        fail("doc still exists after delete")
    } catch ScoovaNoSQLError.notFound {
        print("    PASS")
    }
} catch { fail("\(error)") }

print("\n=== ALL TESTS PASSED ===")
