//
//  Errors.swift
//  ScoovaNoSQL
//

import Foundation

public enum ScoovaNoSQLError: LocalizedError, Sendable, Equatable {
    /// Document with the given ID does not exist.
    case notFound(String)
    /// Backend returned an error response with status code + body.
    case server(status: Int, message: String)
    /// Caller-provided value cannot be serialized to JSON.
    case invalidValue(String)
    /// Network call failed (connection refused, TLS error, etc.).
    case network(String)
    /// Response body could not be decoded into the expected shape.
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):           return "Document not found: \(id)"
        case .server(let s, let m):       return "Server error \(s): \(m)"
        case .invalidValue(let why):      return "Invalid value: \(why)"
        case .network(let why):           return "Network error: \(why)"
        case .decoding(let why):          return "Decoding error: \(why)"
        }
    }
}
