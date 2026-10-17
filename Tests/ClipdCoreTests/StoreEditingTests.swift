import Foundation
import Testing
@testable import ClipdCore

@Test("編輯會同步更新全文索引並保留釘選與來源")
func editingUpdatesIndexAndPreservesMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipd-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(directory: root, passphrase: "fixture")
    defer { store.close() }
    var item = ClipItem(id: makeItemID(), kind: .text, capturedAt: Date(timeIntervalSince1970: 1_000), contentHash: "before",
        preview: "before", searchText: "before", sourceBundleID: "test.editor", sourceAppName: "Editor", isPinned: true)
    try store.insert(item)
    item.searchText = "編輯後的中文字"
    item.preview = item.searchText
    item.contentHash = "after"
    item.representations = [ItemRepresentation(uti: "public.utf8-plain-text", byteCount: item.searchText.utf8.count, inlineText: item.searchText)]
    try store.replaceItem(item)
    #expect(try store.search("before", limit: 10).isEmpty)
    #expect(try store.search("中文字", limit: 10).first == item)
    #expect(try store.pinned(limit: 10) == [item])
    #expect(try store.count() == 1)
    try store.delete(id: item.id)
    #expect(throws: StoreError.self) { try store.replaceItem(item) }
    #expect(try store.count() == 0)
    #expect(try store.search("中文字", limit: 10).isEmpty)
}
