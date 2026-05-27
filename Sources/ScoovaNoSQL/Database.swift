//
//  Database.swift
//  ScoovaNoSQL
//
//  Lightweight handle on a logical database within a project. Today every
//  project has exactly one database, named "(default)" — the type exists so
//  the future per-tenant sharding API isn't a breaking change.
//

import Foundation

public struct Database: Sendable {

    let sdk: ScoovaNoSQL
    public let id: String

    /// Reference a collection at this database's root.
    public func collection(_ path: String) -> CollectionReference {
        CollectionReference(sdk: sdk, collectionPath: path, databaseId: id)
    }
}
