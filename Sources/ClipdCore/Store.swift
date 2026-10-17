// clipd 的本机资料库。整个程式只有这个档案直接碰 SQLite 的 C 介面,
// 其余地方一律走 Store 的公开方法,并行与交易才会只有一个把关点。
import Foundation
import SQLCipher

// MARK: - 错误型别

/// 资料库层唯一往外丢的错误。每个 case 都带着 SQLite 自己的讯息,
/// 因为把原始讯息吞掉之後,现场就只剩下「存不进去」这种没有诊断价值的抱怨。
public enum StoreError: Error, CustomStringConvertible {
    case cannotCreateDirectory(path: String, reason: String)
    case cannotOpen(path: String, message: String)
    case exportDestinationExists(path: String)
    case wrongPassphrase(message: String)
    case sql(operation: String, code: Int32, message: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptRow(reason: String)
    case alreadyClosed

    /// 这些句子有机会直接出现在使用者眼前,所以一律写成完整的句子。
    public var description: String {
        switch self {
        case let .cannotCreateDirectory(path, reason): return "无法建立资料夹 \(path),原因是 \(reason)。"
        case let .cannotOpen(path, message): return "无法开启资料库档案 \(path),SQLite 说 \(message)。"
        case let .exportDestinationExists(path): return "匯出目的地 \(path) 已有檔案，為了保留資料所以拒絕覆寫。"
        case let .wrongPassphrase(message): return "通行码不正确,所以资料库解不开,SQLite 说 \(message)。"
        case let .sql(operation, code, message): return "执行「\(operation)」失败,错误码 \(code),SQLite 说 \(message)。"
        case let .unsupportedSchemaVersion(found, supported):
            return "这个资料库的结构版本是 \(found),比本版程式认得的 \(supported) 还新,为了不弄坏资料所以拒绝开启。"
        case let .corruptRow(reason): return "读到一列无法解读的资料,原因是 \(reason)。"
        case .alreadyClosed: return "资料库已经关闭,不能再对它下指令。"
        }
    }
}

/// 告诉 SQLite「这段字串等一下就不保证还在,请你自己复制一份」。
///
/// 把 Swift String 交给 sqlite3_bind_text 时,Swift 只借给 C 一个暂时的 UTF-8 缓冲区,
/// 那块记忆体在这一行结束後就可能被回收。若用预设的 SQLITE_STATIC,SQLite 会一直握着
/// 那根已经失效的指标直到 step,读到的就是别人的记忆体,也就是典型的 use-after-free。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 资料库本体

/// 本机剪贴板资料库。省略通行碼時使用一般 SQLite；提供通行碼可開啟既有加密資料庫。
///
/// 标 `@unchecked Sendable` 成立的唯一理由是:`db` 这根指标与所有 SQLite 状态,
/// 从建构完成那一刻起只会在私有序列佇列 `queue` 上被读写;每个 public 方法一进来就
/// `queue.sync`,没有任何 handle 或 statement 流到佇列之外,回传的又都是 ClipItem
/// 这种 Sendable 值型别。只要有人绕过佇列直接碰 `db`,这个保证就不成立。
public final class Store: @unchecked Sendable {

    /// 本版程式认得的结构版本。改结构时把它加一,并在 `migrate` 补上对应的搬迁步骤。
    private static let schemaVersion = 1

    /// 所有查询共用同一份栏位顺序,解读那段程式才能安心用固定索引取栏位。
    private static let itemColumns = """
        i.id, i.kind, i.captured_at, i.content_hash, i.preview, i.search_text, \
        i.source_bundle_id, i.source_app_name, i.provenance, i.is_pinned
        """

    public let fileURL: URL
    private let queue = DispatchQueue(label: "dev.clipd.store")
    private var db: OpaquePointer?

    public init(directory: URL, passphrase: String? = nil) throws {
        self.fileURL = directory.appendingPathComponent("clipd.sqlite3")
        try Store.ensureDirectory(directory)
        let handle = try Store.openDatabase(at: fileURL)
        do {
            // 这几步刻意不进佇列:建构还没结束,外界拿不到这个物件,不可能有第二条执行绪同时碰它。
            if let passphrase { try Store.unlock(handle, passphrase: passphrase) }
            try Store.applyPragmas(handle)
            try Store.migrate(handle)
        } catch {
            // 钥匙不对或建表失败时一定要收掉 handle,否则这个行程会一直握着档案锁不放。
            sqlite3_close_v2(handle)
            throw error
        }
        self.db = handle
    }

    deinit { close() }

    // MARK: 开档、解锁与结构

    private static func ensureDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        do {
            // 权限设 0o700,也就是只有本人能读写进入。剪贴板历史等於使用者复制过的一切,
            // 同一台机器上的其他帐号没有理由看得到,所以目录一建立就先收紧。
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.cannotCreateDirectory(path: directory.path, reason: error.localizedDescription)
        }
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        // FULLMUTEX 是保险:并行已经由序列佇列挡掉,但万一日後有人绕过佇列,
        // 让 SQLite 自己上锁总比直接踩坏资料库好。
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "开档回传错误码 \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.cannotOpen(path: url.path, message: message)
        }
        return handle
    }

    private static func unlock(_ db: OpaquePointer, passphrase: String) throws {
        // PRAGMA 不吃参数绑定,通行码只能直接写进 SQL 字串,所以要自己跳脱单引号;
        // 少了这一步,一个含有 ' 的通行码就会提前结束字串,等於对自己的资料库做 SQL 注入。
        let escaped = passphrase.replacingOccurrences(of: "'", with: "''")
        try exec(db, "PRAGMA key = '\(escaped)';", operation: "设定通行码")

        // 设完钥匙立刻做一次最轻的读取确认它是对的。SQLCipher 在设定当下不验证,
        // 错的钥匙会潜伏到第一次真正读页面时才炸成看不懂的讯息;这里先逼它现形,
        // 使用者才会拿到「通行码不对」这种看得懂的结论。
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard rc == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            throw StoreError.wrongPassphrase(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func applyPragmas(_ db: OpaquePointer) throws {
        // WAL 让读不挡写,面板翻历史与监看器写入才不会互相卡住。
        try exec(db, "PRAGMA journal_mode = WAL;", operation: "开启 WAL 日志")
        try exec(db, "PRAGMA foreign_keys = ON;", operation: "开启外键约束")
        // 真的撞锁时等五秒再放弃,总比立刻丢一个 database is locked 给使用者好。
        try exec(db, "PRAGMA busy_timeout = 5000;", operation: "设定等待逾时")
        // 暂存留在记忆体,排序或建索引的溢出档就永远不会以明文落到磁碟上。
        try exec(db, "PRAGMA temp_store = MEMORY;", operation: "把暂存放在记忆体")
        // 删除时把旧内容盖掉,免得删掉的纪录还留在未使用的页面里被捞出来。
        try exec(db, "PRAGMA secure_delete = ON;", operation: "开启安全删除")
    }

    private static func migrate(_ db: OpaquePointer) throws {
        let current = try scalarInt(db, "PRAGMA user_version;", operation: "读取结构版本")
        guard current <= schemaVersion else {
            throw StoreError.unsupportedSchemaVersion(found: current, supported: schemaVersion)
        }
        if current < 1 { try createSchema(db) }
        // 日後改结构时在这里依序接上 `if current < 2 { ... }`,旧资料才有路可走。
        if current != schemaVersion {
            try exec(db, "PRAGMA user_version = \(schemaVersion);", operation: "写入结构版本")
        }
    }

    /// 索引与内容的对应选了「另开一张对照表」而不是在 items 上加整数代理键:
    /// FTS5 只认得整数 rowid,而 items 的主键是可排序的字串识别码;把对应关系独立成一张小表,
    /// items 的结构就能保持乾净,日後要整个重建索引也只要动这张表。
    /// 注意 item_rowid 里明写了一根叫 rowid 的栏位,它会盖过 SQLite 的隐含 rowid,
    /// 也就是说这里的 rowid 一律指我们自己存进去的那个值(已实测确认)。
    private static func createSchema(_ db: OpaquePointer) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS items(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, captured_at REAL NOT NULL,
            content_hash TEXT NOT NULL, preview TEXT NOT NULL, search_text TEXT NOT NULL,
            source_bundle_id TEXT, source_app_name TEXT, provenance TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS item_reps(
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL, uti TEXT NOT NULL, byte_count INTEGER NOT NULL,
            blob_path TEXT, inline_text TEXT,
            PRIMARY KEY(item_id, ordinal));
        CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(gram, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS item_rowid(item_id TEXT PRIMARY KEY, rowid INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_item_rowid_rowid ON item_rowid(rowid);
        CREATE INDEX IF NOT EXISTS idx_items_captured_at ON items(captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_content_hash ON items(content_hash);
        """, operation: "建立资料表")
    }

    // MARK: 对外的操作

    /// 匯出完整資料庫到新的未加密檔案，不修改來源，也不複製外部 blob 檔案。
    /// 成功回傳時已解除連接，目的檔可獨立由一般 SQLite 開啟。
    public func exportPlaintext(to destination: URL) throws {
        try withDatabase { db in
            guard destination.isFileURL, !destination.path.contains("\0") else {
                throw StoreError.cannotOpen(path: destination.path, message: "匯出需要有效的本機檔案路徑")
            }
            let fm = FileManager.default
            let paths = [destination.path, destination.path + "-wal", destination.path + "-shm", destination.path + "-journal"]
            guard !paths.contains(where: { fm.fileExists(atPath: $0) }) else {
                throw StoreError.exportDestinationExists(path: destination.path)
            }
            // 排除檢查與建立之間的競態：只允許建立新檔，不能覆寫既有目的地。
            do {
                try Data().write(to: destination, options: .withoutOverwriting)
            } catch {
                if fm.fileExists(atPath: destination.path) {
                    throw StoreError.exportDestinationExists(path: destination.path)
                }
                throw StoreError.cannotOpen(path: destination.path, message: error.localizedDescription)
            }

            var attached = false
            var transaction = false
            do {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                // 路徑使用綁定參數，單引號或其他 SQL 字元也只能是檔名。
                try Store.runOnce(db, "ATTACH DATABASE ? AS clipd_plaintext_export KEY '';",
                                  text: destination.path, operation: "連接純文字匯出檔")
                attached = true
                try Store.exec(db, "PRAGMA clipd_plaintext_export.journal_mode = DELETE;", operation: "設定匯出日誌")
                try Store.exec(db, "BEGIN;", operation: "開始匯出")
                transaction = true
                // 一般讀取會重新檢查 schema cookie；來源可能曾由另一個連線新增資料表。
                _ = try Store.scalarInt(db, "SELECT count(*) FROM main.sqlite_master;", operation: "讀取匯出結構")
                let version = try Store.scalarInt(db, "PRAGMA main.user_version;", operation: "讀取匯出結構版本")
                let applicationID = try Store.scalarInt(db, "PRAGMA main.application_id;", operation: "讀取匯出應用識別碼")
                // SQLCipher 的匯出會複製 schema、虛擬表與資料，但不複製 user_version。
                try Store.exec(db, "SELECT sqlcipher_export('clipd_plaintext_export');", operation: "匯出資料庫")
                try Store.exec(db, "PRAGMA clipd_plaintext_export.user_version = \(version);", operation: "保留匯出結構版本")
                try Store.exec(db, "PRAGMA clipd_plaintext_export.application_id = \(applicationID);", operation: "保留匯出應用識別碼")
                try Store.exec(db, "COMMIT;", operation: "完成匯出")
                transaction = false
                try Store.exec(db, "DETACH DATABASE clipd_plaintext_export;", operation: "關閉匯出檔")
                attached = false
            } catch {
                if transaction { try? Store.exec(db, "ROLLBACK;", operation: "取消匯出") }
                if attached { try? Store.exec(db, "DETACH DATABASE clipd_plaintext_export;", operation: "關閉失敗的匯出") }
                for path in paths { try? fm.removeItem(atPath: path) }
                throw error
            }
        }
    }

    public func insert(_ item: ClipItem, pendingImageOCR: Bool = false) throws {
        try withDatabase { db in
            try Store.exec(db, "BEGIN IMMEDIATE;", operation: "开始交易")
            do {
                try Store.insertItemRow(db, item)
                try Store.insertRepresentations(db, item)
                try Store.insertSearchIndex(db, item)
                if pendingImageOCR {
                    try Store.ensureOCRJobs(db)
                    try Store.runOnce(db, "INSERT INTO image_ocr_jobs(item_id) VALUES (?);", text: item.id, operation: "排入文字辨識")
                }
                try Store.exec(db, "COMMIT;", operation: "提交交易")
            } catch {
                // 任何一段失败就整笔退回,绝不留下「本文有、索引没有」这种半套纪录。
                // 退回本身若也失败,代表连线已经不健康,那时原始错误比较有诊断价值,所以照样丢原始错误。
                try? Store.exec(db, "ROLLBACK;", operation: "回滚交易")
                throw error
            }
        }
    }

    /// Optional work metadata leaves schema version 1 and existing consumers intact.
    private static func ensureOCRJobs(_ db: OpaquePointer) throws {
        try exec(db, "CREATE TABLE IF NOT EXISTS image_ocr_jobs(item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, attempts INTEGER NOT NULL DEFAULT 0);", operation: "建立辨識工作表")
    }

    public func pendingImageOCRIDs(limit: Int = 20) throws -> [String] {
        try withDatabase { db in
            try Store.ensureOCRJobs(db)
            let statement = try Store.prepare(db, "SELECT j.item_id FROM image_ocr_jobs j JOIN items i ON i.id=j.item_id WHERE j.attempts < 3 ORDER BY i.captured_at, i.id LIMIT ?;", operation: "讀取待辨識圖片")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(max(0, limit)))
            var result: [String] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Store.error(db, code: code, operation: "讀取待辨識圖片") }
                result.append(String(cString: text))
            }
        }
    }

    public func noteImageOCRFailure(_ id: String) throws {
        try withDatabase { db in
            try Store.ensureOCRJobs(db)
            try Store.runOnce(db, "UPDATE image_ocr_jobs SET attempts=attempts+1 WHERE item_id=?;", text: id, operation: "記錄辨識重試")
        }
    }

    /// Only OCR text changes: concurrent pin changes survive and deleted rows stay deleted.
    @discardableResult
    public func updateImageOCR(_ id: String, text: String) throws -> Bool {
        try withDatabase { db in
            try Store.exec(db, "BEGIN IMMEDIATE;", operation: "更新圖片文字")
            do {
                try Store.ensureOCRJobs(db)
                let lookup = try Store.prepare(db, "SELECT r.rowid FROM item_rowid r JOIN items i ON i.id=r.item_id WHERE i.id=? AND i.kind='image';", operation: "確認圖片仍存在")
                Store.bind(lookup, 1, id)
                let code = sqlite3_step(lookup)
                let rowid = code == SQLITE_ROW ? sqlite3_column_int64(lookup, 0) : nil
                sqlite3_finalize(lookup)
                guard code == SQLITE_ROW || code == SQLITE_DONE else { throw Store.error(db, code: code, operation: "確認圖片仍存在") }
                if let rowid {
                    let update = try Store.prepare(db, "UPDATE items SET search_text=? WHERE id=?;", operation: "更新辨識文字")
                    Store.bind(update, 1, text); Store.bind(update, 2, id)
                    defer { sqlite3_finalize(update) }
                    try Store.run(update, db, operation: "更新辨識文字")
                    try Store.runOnce(db, "DELETE FROM item_fts WHERE rowid IN (SELECT rowid FROM item_rowid WHERE item_id=?);", text: id, operation: "更新圖片索引")
                    let index = try Store.prepare(db, "INSERT INTO item_fts(rowid,gram) VALUES (?,?);", operation: "更新圖片索引")
                    defer { sqlite3_finalize(index) }
                    sqlite3_bind_int64(index, 1, rowid)
                    Store.bind(index, 2, TextIndex.documentTokens(text))
                    try Store.run(index, db, operation: "更新圖片索引")
                }
                try Store.runOnce(db, "DELETE FROM image_ocr_jobs WHERE item_id=?;", text: id, operation: "完成圖片辨識")
                try Store.exec(db, "COMMIT;", operation: "儲存圖片文字")
                return rowid != nil
            } catch {
                try? Store.exec(db, "ROLLBACK;", operation: "取消圖片文字更新")
                throw error
            }
        }
    }

    public func recent(limit: Int) throws -> [ClipItem] {
        try withDatabase { db -> [ClipItem] in
            // 时间相同时再用识别码决定顺序;识别码本身单调递增,清单顺序才不会每次不一样。
            let stmt = try Store.prepare(db, "SELECT \(Store.itemColumns) FROM items AS i " +
                                             "ORDER BY i.captured_at DESC, i.id DESC LIMIT ?;",
                                         operation: "读取最近清单")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Store.safeLimit(limit))
            return try Store.collect(stmt, db, operation: "读取最近清单")
        }
    }

    public func search(_ query: String, limit: Int, pinnedOnly: Bool = false) throws -> [ClipItem] {
        try withDatabase { db -> [ClipItem] in
            let match = TextIndex.queryTokens(query)
            // 查询字切完後可能什麽都不剩(例如使用者只打了标点),这时直接回空阵列;
            // 把空字串送进 MATCH 会被 FTS5 当成语法错误。
            guard !match.isEmpty else { return [] }

            // 这个查询的形状很重要:一定要先在子查询里让 FTS 表自己 MATCH 并 ORDER BY rank,
            // 拿到排好序的 rowid 之後才 JOIN 回 items。rank 是 FTS5 只在「该表是 MATCH 主体」
            // 时才给得出来的虚拟栏位;把 FTS 表直接 JOIN 进来再 ORDER BY rank,轻则查询计画
            // 整个走样,重则直接失败。先取後接才是稳的写法。
            let pinFilter = pinnedOnly ? "AND rowid IN (SELECT rowid FROM item_rowid WHERE item_id IN (SELECT id FROM items WHERE is_pinned = 1))" : ""
            let stmt = try Store.prepare(db, """
            SELECT \(Store.itemColumns)
            FROM (SELECT rowid AS fts_rowid, rank AS fts_rank
                  FROM item_fts WHERE item_fts MATCH ? \(pinFilter) ORDER BY rank LIMIT ?) AS f
            JOIN item_rowid AS m ON m.rowid = f.fts_rowid
            JOIN items AS i ON i.id = m.item_id
            ORDER BY f.fts_rank;
            """, operation: "搜寻")
            defer { sqlite3_finalize(stmt) }
            Store.bind(stmt, 1, match)
            sqlite3_bind_int(stmt, 2, Store.safeLimit(limit))
            return try Store.collect(stmt, db, operation: "搜寻")
        }
    }

    public func item(id: String) throws -> ClipItem? {
        try withDatabase { db -> ClipItem? in
            let stmt = try Store.prepare(db, "SELECT \(Store.itemColumns) FROM items AS i WHERE i.id = ? LIMIT 1;",
                                         operation: "读取单笔")
            defer { sqlite3_finalize(stmt) }
            Store.bind(stmt, 1, id)
            return try Store.collect(stmt, db, operation: "读取单笔").first
        }
    }

    /// 找出内容雜凑相同、而且是在 `within` 秒内抓到的那一笔。
    /// 监看器靠这个避免重复存:不少程式会在短时间内把同样内容重写回剪贴板,
    /// 那不是使用者又复制了一次,历史清单不该因此多出一笔一模一样的纪录。
    public func existingID(contentHash: String, within: TimeInterval) throws -> String? {
        try withDatabase { db -> String? in
            let stmt = try Store.prepare(db, """
            SELECT i.id FROM items AS i WHERE i.content_hash = ? AND i.captured_at >= ?
            ORDER BY i.captured_at DESC LIMIT 1;
            """, operation: "查重复")
            defer { sqlite3_finalize(stmt) }
            Store.bind(stmt, 1, contentHash)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970 - within)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0) else {
                    throw StoreError.corruptRow(reason: "items 里有一笔的识别码是空的")
                }
                return String(cString: raw)
            }
            guard rc == SQLITE_DONE else { throw Store.error(db, code: rc, operation: "查重复") }
            return nil
        }
    }

    public func setPinned(_ pinned: Bool, id: String) throws {
        try withDatabase { db in
            let stmt = try Store.prepare(db, "UPDATE items SET is_pinned = ? WHERE id = ?;", operation: "更新钉选状态")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            Store.bind(stmt, 2, id)
            // 没更新到任何一列不算错误:那代表这一笔在别处已经被删掉,
            // 对呼叫端来说「它现在不是钉选状态」这个结果仍然成立。
            try Store.run(stmt, db, operation: "更新钉选状态")
        }
    }

    public func delete(id: String) throws {
        try withDatabase { db in
            try Store.exec(db, "BEGIN IMMEDIATE;", operation: "开始交易")
            do {
                // 顺序是先索引、再对照、最後本文。item_reps 由外键的 ON DELETE CASCADE 带走,
                // 前提是 foreign_keys 这个 pragma 有开,那是在开档时就设好的。
                try Store.runOnce(db, "DELETE FROM item_fts WHERE rowid IN (SELECT rowid FROM item_rowid WHERE item_id = ?);",
                                  text: id, operation: "删除搜寻索引")
                try Store.runOnce(db, "DELETE FROM item_rowid WHERE item_id = ?;", text: id, operation: "删除索引对照")
                try Store.runOnce(db, "DELETE FROM items WHERE id = ?;", text: id, operation: "删除本文")
                try Store.exec(db, "COMMIT;", operation: "提交交易")
            } catch {
                try? Store.exec(db, "ROLLBACK;", operation: "回滚交易")
                throw error
            }
        }
    }

    public func count() throws -> Int {
        try withDatabase { db in try Store.scalarInt(db, "SELECT count(*) FROM items;", operation: "计算笔数") }
    }

    public func pinned(limit: Int) throws -> [ClipItem] {
        try withDatabase { db in
            let stmt = try Store.prepare(db, "SELECT \(Store.itemColumns) FROM items AS i WHERE is_pinned = 1 ORDER BY captured_at DESC, id DESC LIMIT ?;", operation: "讀取釘選")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Store.safeLimit(limit))
            return try Store.collect(stmt, db, operation: "讀取釘選")
        }
    }

    /// Update content and its search index in one transaction. A removed item stays removed.
    public func replaceItem(_ item: ClipItem) throws {
        try withDatabase { db in
            try Store.exec(db, "BEGIN IMMEDIATE;", operation: "開始編輯")
            do {
                let exists = try Store.prepare(db, "SELECT 1 FROM items WHERE id = ?;", operation: "確認編輯目標")
                Store.bind(exists, 1, item.id)
                let found = sqlite3_step(exists) == SQLITE_ROW
                sqlite3_finalize(exists)
                guard found else { throw StoreError.corruptRow(reason: "這筆歷史已被移除，未儲存編輯。") }
                try Store.runOnce(db, "DELETE FROM item_fts WHERE rowid IN (SELECT rowid FROM item_rowid WHERE item_id = ?);", text: item.id, operation: "更新索引")
                try Store.runOnce(db, "DELETE FROM item_rowid WHERE item_id = ?;", text: item.id, operation: "更新索引對照")
                try Store.runOnce(db, "DELETE FROM items WHERE id = ?;", text: item.id, operation: "更新內容")
                try Store.insertItemRow(db, item)
                try Store.insertRepresentations(db, item)
                try Store.insertSearchIndex(db, item)
                try Store.exec(db, "COMMIT;", operation: "儲存編輯")
            } catch {
                try? Store.exec(db, "ROLLBACK;", operation: "取消編輯")
                throw error
            }
        }
    }

    /// 关闭资料库。关掉之後任何操作都会明确丢出 `alreadyClosed`,而不是踩到已经释放的指标。
    public func close() {
        queue.sync {
            guard let db else { return }
            self.db = nil
            // 用 close_v2:就算还有没收乾净的 statement,它也会等它们结束才真正释放,不会漏掉档案控制代码。
            sqlite3_close_v2(db)
        }
    }

    /// 所有公开方法唯一的入口:把工作丢到序列佇列上,并且在同一处确认资料库还开着。
    /// 集中在这里是刻意的 —— 只要有人另外写一条不经过它的路径,`@unchecked Sendable`
    /// 的前提就破了,而这种错在这个函式旁边最容易被审出来。
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let db else { throw StoreError.alreadyClosed }
            return try body(db)
        }
    }
}

// MARK: - 写入的细部步骤

extension Store {

    fileprivate static func insertItemRow(_ db: OpaquePointer, _ item: ClipItem) throws {
        let stmt = try prepare(db, """
        INSERT INTO items(id, kind, captured_at, content_hash, preview, search_text,
                          source_bundle_id, source_app_name, provenance, is_pinned)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """, operation: "写入本文")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, item.id)
        bind(stmt, 2, item.kind.rawValue)
        sqlite3_bind_double(stmt, 3, item.capturedAt.timeIntervalSince1970)
        bind(stmt, 4, item.contentHash)
        bind(stmt, 5, item.preview)
        bind(stmt, 6, item.searchText)
        bind(stmt, 7, item.sourceBundleID)
        bind(stmt, 8, item.sourceAppName)
        bind(stmt, 9, item.provenance.rawValue)
        sqlite3_bind_int(stmt, 10, item.isPinned ? 1 : 0)
        try run(stmt, db, operation: "写入本文")
    }

    fileprivate static func insertRepresentations(_ db: OpaquePointer, _ item: ClipItem) throws {
        guard !item.representations.isEmpty else { return }
        let stmt = try prepare(db, """
        INSERT INTO item_reps(item_id, ordinal, uti, byte_count, blob_path, inline_text) VALUES (?,?,?,?,?,?);
        """, operation: "写入表示法")
        defer { sqlite3_finalize(stmt) }
        // 用阵列里的位置当 ordinal,读回来时就能还原成原本的偏好顺序。
        for (ordinal, rep) in item.representations.enumerated() {
            sqlite3_reset(stmt)
            bind(stmt, 1, item.id)
            sqlite3_bind_int(stmt, 2, Int32(ordinal))
            bind(stmt, 3, rep.uti)
            sqlite3_bind_int64(stmt, 4, Int64(rep.byteCount))
            bind(stmt, 5, rep.blobPath)
            bind(stmt, 6, rep.inlineText)
            try run(stmt, db, operation: "写入表示法")
        }
    }

    fileprivate static func insertSearchIndex(_ db: OpaquePointer, _ item: ClipItem) throws {
        let stmt = try prepare(db, "INSERT INTO item_fts(gram) VALUES (?);", operation: "写入搜寻索引")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, TextIndex.documentTokens(item.searchText))
        try run(stmt, db, operation: "写入搜寻索引")

        // 让 FTS5 自己配 rowid 再记进对照表,索引与本文的关联就只有这一处,不必另外维护计数器。
        let assigned = sqlite3_last_insert_rowid(db)
        let mapStmt = try prepare(db, "INSERT INTO item_rowid(item_id, rowid) VALUES (?,?);", operation: "写入索引对照")
        defer { sqlite3_finalize(mapStmt) }
        bind(mapStmt, 1, item.id)
        sqlite3_bind_int64(mapStmt, 2, assigned)
        try run(mapStmt, db, operation: "写入索引对照")
    }
}

// MARK: - SQLite 低阶小工具

extension Store {

    fileprivate static func error(_ db: OpaquePointer, code: Int32, operation: String) -> StoreError {
        StoreError.sql(operation: operation, code: code, message: String(cString: sqlite3_errmsg(db)))
    }

    fileprivate static func exec(_ db: OpaquePointer, _ sql: String, operation: String) throws {
        var raw: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &raw)
        guard rc == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(raw)
            throw StoreError.sql(operation: operation, code: rc, message: message)
        }
        sqlite3_free(raw)
    }

    fileprivate static func prepare(_ db: OpaquePointer, _ sql: String, operation: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw error(db, code: rc, operation: operation)
        }
        return stmt
    }

    fileprivate static func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, text, -1, sqliteTransient) }
        else { sqlite3_bind_null(stmt, index) }
    }

    /// 跑一个不回传资料列的叙述。
    fileprivate static func run(_ stmt: OpaquePointer, _ db: OpaquePointer, operation: String) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw error(db, code: rc, operation: operation) }
    }

    /// 准备、绑一个字串、执行、收掉,一次做完;删除那组三连发就是靠它。
    fileprivate static func runOnce(_ db: OpaquePointer, _ sql: String, text: String, operation: String) throws {
        let stmt = try prepare(db, sql, operation: operation)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text)
        try run(stmt, db, operation: operation)
    }

    fileprivate static func scalarInt(_ db: OpaquePointer, _ sql: String, operation: String) throws -> Int {
        let stmt = try prepare(db, sql, operation: operation)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { throw error(db, code: rc, operation: operation) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// SQLite 的 LIMIT 收到负数代表「不限笔数」,那绝不是呼叫端要的结果,所以先夹回合理范围。
    fileprivate static func safeLimit(_ limit: Int) -> Int32 {
        Int32(max(0, min(limit, Int(Int32.max))))
    }
}

// MARK: - 读取与解读

extension Store {

    /// 把一个已经绑好参数的查询跑完,并且顺手补上每一笔的表示法。
    fileprivate static func collect(_ stmt: OpaquePointer, _ db: OpaquePointer, operation: String) throws -> [ClipItem] {
        var rows: [ClipItem] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { rows.append(try decodeItem(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw error(db, code: rc, operation: operation) }
        }
        return try rows.map { row in
            var filled = row   // 这是值型别的复本,补表示法不会动到原来那一笔。
            filled.representations = try loadRepresentations(db, itemID: row.id)
            return filled
        }
    }

    private static func decodeItem(_ stmt: OpaquePointer) throws -> ClipItem {
        func text(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: raw)
        }
        guard let id = text(0), let rawKind = text(1), let contentHash = text(3),
              let preview = text(4), let searchText = text(5), let rawProvenance = text(8) else {
            throw StoreError.corruptRow(reason: "items 有一列的必填栏位是空的")
        }
        guard let kind = ItemKind(rawValue: rawKind) else {
            throw StoreError.corruptRow(reason: "items 里出现认不得的种类 \(rawKind)")
        }
        // 可信度认不出来时退回 unknown,而不是让整批读不出来:
        // 它只影响介面上的提示强度,不值得为它让整个历史清单打不开。
        return ClipItem(
            id: id, kind: kind,
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            contentHash: contentHash, preview: preview, searchText: searchText,
            sourceBundleID: text(6), sourceAppName: text(7),
            provenance: Provenance(rawValue: rawProvenance) ?? .unknown,
            isPinned: sqlite3_column_int(stmt, 9) != 0,
            representations: []
        )
    }

    private static func loadRepresentations(_ db: OpaquePointer, itemID: String) throws -> [ItemRepresentation] {
        let stmt = try prepare(db, """
        SELECT uti, byte_count, blob_path, inline_text FROM item_reps WHERE item_id = ? ORDER BY ordinal;
        """, operation: "读取表示法")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, itemID)

        func text(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: raw)
        }

        var reps: [ItemRepresentation] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                guard let uti = text(0) else {
                    throw StoreError.corruptRow(reason: "item_reps 里有一列没有型别识别码")
                }
                reps.append(ItemRepresentation(uti: uti,
                                               byteCount: Int(sqlite3_column_int64(stmt, 1)),
                                               blobPath: text(2), inlineText: text(3)))
            } else if rc == SQLITE_DONE { break }
            else { throw error(db, code: rc, operation: "读取表示法") }
        }
        return reps
    }
}

// MARK: - 空间回收

extension Store {

    /// 大量删除之後,请 SQLite 把空出来的页面还回去。
    ///
    /// 为什麽需要这一步:SQLite 删掉资料列并不会让资料库档案变小,它只是把那些页面标成「可以再用」。
    /// 剪贴板历史被清掉一半之後,档案仍然占着原本的大小,拥有者在 Finder 里看到的数字不会动,
    /// 那会让他以为清理根本没有发生。
    ///
    /// 这里用的是渐进式回收(incremental vacuum)而不是完整的 VACUUM,理由是完整 VACUUM 会把
    /// 整个加密资料库重写一遍,过程中磁碟上需要接近两倍的空间,而且期间整个资料库是锁住的;
    /// 对一个在背景默默做清理的工具来说,那个代价太重。
    ///
    /// 必须诚实讲清楚的限制:渐进式回收只有在资料库建立时就设定了 `auto_vacuum = INCREMENTAL`
    /// 才真的会缩小档案。既有的资料库是以预设值(auto_vacuum = NONE)建立的,对它们来说这个
    /// 指令是一个不会出错、但也不会缩小档案的空操作 —— 空出来的页面留在档案里,被之後新增的
    /// 资料重复使用,所以空间不会无限膨胀,只是不会立刻还给档案系统。要改掉这一点必须对既有
    /// 资料库做一次完整 VACUUM,那是另一个决定,不该藏在一次例行清理里面偷偷发生。
    public func reclaimSpace() throws {
        try withDatabase { db in
            try Store.exec(db, "PRAGMA incremental_vacuum;", operation: "回收空出来的页面")
        }
    }
}
