import Foundation
import ClipdCore

// Offline conversion only: the caller stops the app and supplies a backup copy.
// Neither clipboard contents nor key material are printed.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: convert-archive-to-plaintext <source-directory> <new-directory>\n", stderr)
    exit(1)
}

do {
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let targetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let targetFile = targetURL.appendingPathComponent("clipd.sqlite3")
    guard !FileManager.default.fileExists(atPath: targetFile.path) else {
        throw CocoaError(.fileWriteFileExists)
    }
    let key = try String(contentsOf: sourceURL.appendingPathComponent("db.key"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let original = try Store(directory: sourceURL, passphrase: key)
    defer { original.close() }
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    try original.exportPlaintext(to: targetFile)
    let converted = try Store(directory: targetURL)
    defer { converted.close() }
    let records = try original.recent(limit: Int.max)
    let count = try converted.count()
    guard count == records.count else { throw CocoaError(.fileReadCorruptFile) }
    for record in records {
        guard try converted.item(id: record.id) == record else { throw CocoaError(.fileReadCorruptFile) }
    }
    let originalPinned = try original.pinned(limit: Int.max)
    guard try converted.pinned(limit: Int.max) == originalPinned else { throw CocoaError(.fileReadCorruptFile) }
    var searchChecks = 0
    var attempted = Set<String>()
    for record in records where !record.searchText.isEmpty {
        if searchChecks == 20 { break }
        let query = String(record.searchText.prefix(12)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, attempted.insert(query).inserted else { continue }
        let before = try original.search(query, limit: 200).map(\.id)
        guard !before.isEmpty else { continue }
        let after = try converted.search(query, limit: 200).map(\.id)
        guard before == after else { throw CocoaError(.fileReadCorruptFile) }
        searchChecks += 1
    }
    let header = try FileHandle(forReadingFrom: targetFile)
    defer { try? header.close() }
    guard try header.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let result: [String: Any] = ["original_count": records.count, "converted_count": count,
        "unchanged_records": records.count, "pinned_unchanged": true,
        "search_checks": searchChecks, "plaintext_sqlite": true]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: output, as: UTF8.self))
} catch {
    fputs("Conversion or verification failed. The original archive was not replaced.\n", stderr)
    exit(1)
}
