import Foundation
import ClipdCore

// Compare metadata and full representations without printing clipboard contents or keys.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: check-archive-preservation <backup-directory> <current-directory>\n", stderr)
    exit(1)
}
func open(_ path: String) throws -> Store {
    let root = URL(fileURLWithPath: path)
    if try isPlaintext(root) { return try Store(directory: root) }
    let key = try String(contentsOf: root.appendingPathComponent("db.key"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try Store(directory: root, passphrase: key)
}
func isPlaintext(_ root: URL) throws -> Bool {
    let file = try FileHandle(forReadingFrom: root.appendingPathComponent("clipd.sqlite3"))
    defer { try? file.close() }
    return try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8)
}
do {
    let before = try open(CommandLine.arguments[1])
    let after = try open(CommandLine.arguments[2])
    defer { before.close(); after.close() }
    let original = try before.recent(limit: Int.max)
    var preserved = 0
    for record in original where try after.item(id: record.id) == record { preserved += 1 }
    let beforeRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let afterRoot = URL(fileURLWithPath: CommandLine.arguments[2])
    let plain = try isPlaintext(afterRoot)
    var summary: [String: Any] = ["original_count": original.count, "current_count": try after.count(),
                                "unchanged_original_rows": preserved, "plaintext_sqlite": plain]
    var keyPreserved = true
    if !plain {
        keyPreserved = try Data(contentsOf: beforeRoot.appendingPathComponent("db.key")) == Data(contentsOf: afterRoot.appendingPathComponent("db.key"))
        summary["key_unchanged"] = keyPreserved
    }
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    guard preserved == original.count, keyPreserved else { exit(2) }
} catch {
    fputs("Archive verification failed; no contents or keys were printed.\n", stderr)
    exit(1)
}
