//
//  QuerySnapshot.swift
//  ScoovaNoSQL
//

import Foundation

public struct QuerySnapshot: Sendable {
    public let documents: [DocumentSnapshot]

    public var count: Int { documents.count }
    public var isEmpty: Bool { documents.isEmpty }
}
