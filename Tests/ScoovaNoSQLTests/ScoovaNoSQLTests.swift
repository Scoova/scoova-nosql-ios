//
//  ScoovaNoSQLTests.swift
//  Surface-level tests that the public API compiles and the query builder
//  composes the expected wire fields. We don't hit the network here.
//

import XCTest
@testable import ScoovaNoSQL

final class ScoovaNoSQLTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ScoovaNoSQL.configure(
            projectId: "test",
            apiKey: "test_key",
            token: nil
        )
    }

    func testEntryPointShape() {
        let rides = ScoovaNoSQL.shared.collection("rides")
        XCTAssertEqual(rides.collectionPath, "rides")
        XCTAssertEqual(rides.databaseId, "default")
    }

    func testQueryBuilderComposesFilters() {
        let q = ScoovaNoSQL.shared
            .collection("rides")
            .whereField("riderId", isEqualTo: "u-1")
            .whereField("distance", isGreaterThan: 5)
            .order(by: "startedAt", descending: true)
            .limit(to: 50)

        XCTAssertEqual(q.filters.count, 2)
        XCTAssertEqual(q.filters[0].field, "riderId")
        XCTAssertEqual(q.filters[0].op, .equal)
        XCTAssertEqual(q.filters[1].field, "distance")
        XCTAssertEqual(q.filters[1].op, .greaterThan)
        XCTAssertEqual(q.orders.first?.field, "startedAt")
        XCTAssertEqual(q.orders.first?.descending, true)
        XCTAssertEqual(q.limitValue, 50)
    }

    func testDocumentReferencePath() {
        let doc = ScoovaNoSQL.shared.collection("rides").document("abc")
        XCTAssertEqual(doc.path, "rides/abc")
    }

    func testJSONValueRoundtrip() throws {
        let original: [String: Any] = [
            "name": "ride",
            "distance": 8.4,
            "count": 12,
            "verified": true,
            "tags": ["fast", "smooth"],
            "nested": ["lat": 33.5, "lng": -7.6] as [String: Any],
        ]
        let value = JSONValue(original)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        // Coerce back via JSONValue.anyValue and confirm we keep the keys.
        guard case .object(let obj) = decoded else {
            XCTFail("expected object"); return
        }
        XCTAssertEqual(obj.keys.sorted(), original.keys.sorted())
    }

    func testCodableDecoding() throws {
        struct Ride: Codable, Equatable {
            let id: String
            let distance: Double
        }
        let ref = ScoovaNoSQL.shared.collection("rides").document("abc")
        let snap = DocumentSnapshot(
            ref: ref,
            documentID: "abc",
            data: ["id": "abc", "distance": 8.4],
            exists: true,
            updateTime: nil
        )
        let decoded = try snap.data(as: Ride.self)
        XCTAssertEqual(decoded, Ride(id: "abc", distance: 8.4))
    }
}
