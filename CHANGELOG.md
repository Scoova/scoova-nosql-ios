# Changelog

## 1.0.1 — 2026-06-06

- **fix(document-ref): sanitize NUL characters in setData / updateData.**
  PostgreSQL's `jsonb` column type refuses U+0000 (the JSON spec allows it,
  Postgres explicitly doesn't because TEXT is internally NUL-terminated).
  iOS surfaced this through BLE GATT characteristics that carry a
  C-string-style NUL terminator — `.trimmingCharacters(in: .whitespacesAndNewlines)`
  doesn't touch NUL, so the dirty value flowed all the way to the server
  and 500'd. The SDK now strips NUL characters and their JSON escape
  form from every document write at the SDK boundary, recursing through
  nested dictionaries and arrays. Idempotent and fast-path no-op for
  clean payloads (the vast majority).
- **feat(cache): SQLite-backed offline cache with pending-write replay.**
  Reads honour an optional `Source` enum (`.default` / `.server` / `.cache`)
  matching Firestore's semantics. Writes that fail go onto a replay queue
  and are flushed automatically when the network returns. The replay
  loop also kicks once on init when disk has unflushed writes from a
  previous session.
- **feat(api): `Source` enum + offline-aware reads.**
  Pass `source: .cache` to read entirely offline; pass `source: .server`
  to bypass the cache; default (`.default`) returns cached data
  immediately and refreshes from the server in the background.

## 1.0.0 — 2026-05-27

- Initial release. Firestore-shaped Swift package: collection, document,
  query, snapshot listeners. Backed by Scoova's multi-tenant NoSQL
  platform.
