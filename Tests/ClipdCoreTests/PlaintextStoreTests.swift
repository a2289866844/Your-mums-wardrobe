import Foundation
import SQLCipher
import Testing
@testable import ClipdCore

private let plaintextTestKey = "export fixture ' key"

private func plaintextTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("clipd-plaintext-\(UUID())")
}

private func withRawDatabase<T>(_ url: URL, key: String? = nil, _ body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    #expect(result == SQLITE_OK)
    if let key {
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(handle, "PRAGMA key = '\(escaped)';", nil, nil, nil) == SQLITE_OK)
    }
    return try body(handle)
}

private func rawRows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
    let prepared = try #require(statement)
    defer { sqlite3_finalize(prepared) }
    var rows: [[String]] = []
    var result = sqlite3_step(prepared)
    while result == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(prepared)).map { column in
            let type = sqlite3_column_type(prepared, column)
            if type == SQLITE_NULL { return "null" }
            let count = Int(sqlite3_column_bytes(prepared, column))
            guard let bytes = sqlite3_column_blob(prepared, column) else { return "\(type):" }
            return "\(type):" + Data(bytes: bytes, count: count).base64EncodedString()
        })
        result = sqlite3_step(prepared)
    }
    #expect(result == SQLITE_DONE)
    return rows
}

private func databaseSnapshot(_ url: URL, key: String? = nil) throws -> [[[String]]] {
    try withRawDatabase(url, key: key) { db in
        let schema = try rawRows(db, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name;")
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name;", -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement)
        defer { sqlite3_finalize(prepared) }
        var snapshot = [schema]
        while sqlite3_step(prepared) == SQLITE_ROW {
            let name = String(cString: try #require(sqlite3_column_text(prepared, 0)))
            let definition = String(cString: try #require(sqlite3_column_text(prepared, 1)))
            let identifier = name.replacingOccurrences(of: "\"", with: "\"\"")
            let columns = definition.uppercased().contains("WITHOUT ROWID") ? "*" : "rowid, *"
            snapshot.append(try rawRows(db, "SELECT \(columns) FROM \"\(identifier)\";").sorted { $0.lexicographicallyPrecedes($1) })
        }
        snapshot.append(try rawRows(db, "PRAGMA user_version;"))
        snapshot.append(try rawRows(db, "PRAGMA application_id;"))
        return snapshot
    }
}

private func regularSQLite(_ url: URL, sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path, sql]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}

private func exportFixture(id: String, text: String, pinned: Bool = false) -> ClipItem {
    ClipItem(id: id, kind: .text, capturedAt: Date(timeIntervalSince1970: 1234.5),
             contentHash: "hash-\(id)", preview: text, searchText: text,
             sourceBundleID: "fixture.editor", sourceAppName: "編輯器", provenance: .medium,
             isPinned: pinned,
             representations: [
                ItemRepresentation(uti: "public.utf8-plain-text", byteCount: text.utf8.count, inlineText: text),
                ItemRepresentation(uti: "public.html", byteCount: 123, blobPath: "blobs/\(id).html")
             ])
}

@Test("Plaintext Store creates ordinary SQLite and supports reopen, write, and search")
func plaintextStoreCreateAndReopen() throws {
    let root = plaintextTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(directory: root)
    let item = exportFixture(id: "plain", text: "plaintext fixture 中文搜尋")
    try store.insert(item)
    store.close()
    #expect(try Data(contentsOf: store.fileURL).prefix(16) == Data("SQLite format 3\0".utf8))
    #expect(try regularSQLite(store.fileURL, sql: "PRAGMA integrity_check; SELECT count(*) FROM items; PRAGMA user_version;") == "ok\n1\n1\n")
    let reopened = try Store(directory: root)
    defer { reopened.close() }
    #expect(try reopened.item(id: item.id) == item)
    #expect(try reopened.search("中文", limit: 10) == [item])
    try reopened.insert(exportFixture(id: "second", text: "second plaintext entry"))
    #expect(try reopened.count() == 2)
}

@Test("Encrypted export preserves every schema object, table row, rowid, metadata, and source")
func encryptedStoreExportsCompletePlaintextCopy() throws {
    let root = plaintextTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try Store(directory: root.appendingPathComponent("source"), passphrase: plaintextTestKey)
    defer { source.close() }
    let first = exportFixture(id: "first", text: "first 中文搜尋", pinned: true)
    let last = exportFixture(id: "last", text: "last 中文搜尋")
    try source.insert(first)
    try source.insert(exportFixture(id: "deleted", text: "deleted"))
    try source.insert(last)
    try source.delete(id: "deleted")
    try withRawDatabase(source.fileURL, key: plaintextTestKey) { db in
        #expect(sqlite3_exec(db, """
            CREATE TABLE migration_metadata(id INTEGER PRIMARY KEY, payload BLOB, optional TEXT);
            INSERT INTO migration_metadata VALUES(7, X'0011FF', NULL);
            CREATE INDEX migration_metadata_payload ON migration_metadata(payload);
            CREATE VIEW migration_metadata_view AS SELECT id FROM migration_metadata;
            CREATE TRIGGER migration_metadata_trigger AFTER UPDATE ON migration_metadata BEGIN SELECT 1; END;
            PRAGMA application_id = 12345;
            """, nil, nil, nil) == SQLITE_OK)
    }
    let before = try databaseSnapshot(source.fileURL, key: plaintextTestKey)
    let targetRoot = root.appendingPathComponent("copy ' quoted")
    try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
    let target = targetRoot.appendingPathComponent("clipd.sqlite3")
    try source.exportPlaintext(to: target)
    #expect(try databaseSnapshot(target) == before)
    #expect(try databaseSnapshot(source.fileURL, key: plaintextTestKey) == before)
    #expect(try Data(contentsOf: source.fileURL).prefix(16) != Data("SQLite format 3\0".utf8))
    #expect(try Data(contentsOf: target).prefix(16) == Data("SQLite format 3\0".utf8))
    for suffix in ["-wal", "-shm", "-journal"] {
        #expect(!FileManager.default.fileExists(atPath: target.path + suffix))
    }
    #expect(try regularSQLite(target, sql: "PRAGMA integrity_check; SELECT count(*) FROM items; PRAGMA user_version; PRAGMA application_id;") == "ok\n2\n1\n12345\n")
    let plaintext = try Store(directory: targetRoot)
    defer { plaintext.close() }
    #expect(try plaintext.search("中文", limit: 10).map(\.id).sorted() == [first.id, last.id])
    #expect(try plaintext.pinned(limit: 10) == [first])
    #expect(try plaintext.item(id: last.id) == last)
    try plaintext.insert(exportFixture(id: "new", text: "new plaintext content"))
    #expect(try plaintext.search("plaintext", limit: 10).map(\.id) == ["new"])
    #expect(try source.count() == 2)
}

@Test("Plaintext export preserves an arbitrary source user_version")
func plaintextExportPreservesSchemaVersion() throws {
    let root = plaintextTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(directory: root, passphrase: plaintextTestKey)
    defer { store.close() }
    try withRawDatabase(store.fileURL, key: plaintextTestKey) { db in
        #expect(sqlite3_exec(db, "PRAGMA user_version = 37;", nil, nil, nil) == SQLITE_OK)
    }
    let target = root.appendingPathComponent("export.sqlite3")
    try store.exportPlaintext(to: target)
    #expect(try regularSQLite(target, sql: "PRAGMA user_version;") == "37\n")
}

@Test("Plaintext export rejects existing targets and sidecars without changing source or target")
func plaintextExportRejectsOverwrite() throws {
    let root = plaintextTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(directory: root, passphrase: plaintextTestKey)
    defer { store.close() }
    try store.insert(exportFixture(id: "kept", text: "retained fixture"))
    let before = try databaseSnapshot(store.fileURL, key: plaintextTestKey)
    let target = root.appendingPathComponent("existing.sqlite3")
    let sentinel = Data("existing destination".utf8)
    try sentinel.write(to: target)
    #expect(throws: StoreError.self) { try store.exportPlaintext(to: target) }
    #expect(try Data(contentsOf: target) == sentinel)
    #expect(throws: StoreError.self) { try store.exportPlaintext(to: store.fileURL) }
    let sidecarTarget = root.appendingPathComponent("sidecar.sqlite3")
    let sidecar = URL(fileURLWithPath: sidecarTarget.path + "-wal")
    try sentinel.write(to: sidecar)
    #expect(throws: StoreError.self) { try store.exportPlaintext(to: sidecarTarget) }
    #expect(try Data(contentsOf: sidecar) == sentinel)
    #expect(!FileManager.default.fileExists(atPath: sidecarTarget.path))
    #expect(try databaseSnapshot(store.fileURL, key: plaintextTestKey) == before)
    store.close()
    let closedTarget = root.appendingPathComponent("closed.sqlite3")
    #expect(throws: StoreError.self) { try store.exportPlaintext(to: closedTarget) }
    #expect(!FileManager.default.fileExists(atPath: closedTarget.path))
}
