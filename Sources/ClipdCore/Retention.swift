// 保留期限管理:让剪贴板历史不要无止尽地长大。
//
// 这个档案存在的理由是一个量测过的数字:一张全萤幕的 Retina 截图存成 PNG 大约是 2.6 MB。
// 剪贴板管理工具会把每一次复制、每一张截图都留下来,如果完全不设上限,只要每天来个几十张截图,
// 几个星期之内储存资料夹就会长到几十 GB。那不是理论上的风险,是这类工具的正常使用量必然的结果。
//
// 这里的每一个动作都是不可逆的删除,所以整个档案的写法都偏保守:
// 先把「要删什麽」算成一份计画,`estimate()` 只把计画讲给拥有者听,`sweep()` 才真的动手,
// 两者共用同一段计算,拥有者事前看到的与事後真的发生的因此不可能不一致。
import Foundation

// MARK: - 政策

/// 保留政策:四个上限,任何一个被突破就会有东西被删掉。
///
/// 四个栏位都是「非正数代表不设限」。这个选择是刻意的:一个不小心被设成 0 的栏位,
/// 若解读成「一笔都不留」,那一瞬间就会把拥有者的整份历史清空;解读成「不设限」最多只是没清乾净,
/// 而没清乾净是可以事後补救的,资料被删掉不行。
public struct RetentionPolicy: Codable, Sendable {
    /// 最多保留几笔纪录。
    public var maximumItems: Int
    /// 最多保留几天以内的纪录。
    public var maximumDays: Int
    /// 图片等外部档案(blob)加起来最多占多少位元组。
    public var maximumBlobBytes: Int
    /// 钉选的纪录是否永远不被清掉。
    public var keepsPinned: Bool

    public init(maximumItems: Int, maximumDays: Int, maximumBlobBytes: Int, keepsPinned: Bool) {
        self.maximumItems = maximumItems
        self.maximumDays = maximumDays
        self.maximumBlobBytes = maximumBlobBytes
        self.keepsPinned = keepsPinned
    }

    /// 预设政策:两万笔、一年、两 GB 的图片、钉选的永远保留。
    ///
    /// 两万笔与一年这两个数字的用意是「几乎不会碰到」:一般人一天复制几十次,一年也才几千笔,
    /// 所以这两条线主要是防呆,不是日常会作用的限制。
    ///
    /// 真正会作用的是那 2 GB 的图片上限,它的推算过程如下:实测一张全萤幕 Retina 截图存成 PNG
    /// 约 2.6 MB,2 GB 大约就是八百张截图。若完全不设这条线,一天二十张截图等於一天 52 MB,
    /// 两个星期就超过 700 MB,几个星期後储存资料夹会长到几十 GB,而且拥有者不会收到任何提示 ——
    /// 一个安静待在背景的小工具悄悄吃掉硬碟,是这类程式最常见也最难被发现的失败方式。
    public static let `default` = RetentionPolicy(
        maximumItems: 20_000,
        maximumDays: 365,
        maximumBlobBytes: 2 * 1024 * 1024 * 1024,
        keepsPinned: true
    )
}

/// 一次清理实际做了什麽。`sentence` 是要直接显示给拥有者看的完整中文句子。
public struct RetentionReport: Sendable {
    public let removedItems: Int
    public let freedBytes: Int
    public let sentence: String

    public init(removedItems: Int, freedBytes: Int, sentence: String) {
        self.removedItems = removedItems
        self.freedBytes = freedBytes
        self.sentence = sentence
    }
}

// MARK: - 本体

/// 依照政策清理资料库与图片档案。
public final class Retention {

    private let store: Store
    /// 相对路径的根。`ItemRepresentation.blobPath` 存的一律是相对於它的路径。
    private let blobDirectory: URL

    /// 政策是可以随时改的:拥有者在设定里调整上限之後,不需要重建这个物件。
    public var policy: RetentionPolicy

    public init(store: Store, blobDirectory: URL, policy: RetentionPolicy = .default) {
        self.store = store
        self.blobDirectory = blobDirectory
        self.policy = policy
    }

    /// 所有 blob 都住在储存资料夹底下这个子目录里。
    ///
    /// 扫描孤儿档案时只准扫这个子目录,这一点是安全关键:`blobDirectory` 是整个储存资料夹的根,
    /// 里面还住着加密资料库 clipd.sqlite3 与金钥档 db.key。如果对整个根目录做「没有被引用就删掉」,
    /// 第一个被判定成孤儿的就会是资料库自己,一次清理就把全部历史连同金钥一起送走。
    private var blobRoot: URL { blobDirectory.appendingPathComponent("blobs", isDirectory: true) }

    // MARK: 对外的三个动作

    /// 依照政策清一次。回传这次实际删掉了什麽。
    public func sweep() throws -> RetentionReport {
        let plan = try makePlan()

        // 顺序是先删资料库纪录、再删磁碟档案。反过来做的话,只要中间失败,
        // 资料库里就会留下一笔指着不存在档案的纪录,面板上会出现一则打不开的图片。
        // 照现在的顺序,中间失败最多留下几个没人引用的档案,而那正好是下一次清理会顺手处理掉的孤儿。
        var removed = 0
        for item in plan.doomed {
            try store.delete(id: item.id)
            removed += 1
        }

        var freed = 0
        var failedFiles = 0
        for url in plan.blobsToDelete + plan.orphanBlobs {
            let size = fileSize(at: url)
            do {
                try FileManager.default.removeItem(at: url)
                freed += size
            } catch {
                // 单一档案删不掉不该让整次清理失败:资料库那一侧已经删乾净了,
                // 这个档案就变成孤儿,下一次清理会再试一次。
                failedFiles += 1
            }
        }

        // 删完之後请 SQLite 把空出来的页面还回去。这一步的限制写在 Store.reclaimSpace 上。
        try store.reclaimSpace()

        var sentence = "这次清理删掉了 \(removed) 则纪录"
        if plan.orphanBlobs.isEmpty {
            sentence += ",并释放了 \(Retention.humanBytes(freed)) 的磁碟空间。"
        } else {
            sentence += ",顺便清掉了 \(plan.orphanBlobs.count) 个已经没有任何纪录指向它的孤儿档案,"
                + "总共释放了 \(Retention.humanBytes(freed)) 的磁碟空间。"
        }
        sentence += plan.reasonSentence
        if failedFiles > 0 {
            sentence += "另外有 \(failedFiles) 个档案这次删不掉,可能是权限或档案正在被使用,"
                + "它们已经没有任何纪录指向,下一次清理会再试一次。"
        }
        if policy.keepsPinned && plan.pinnedKept > 0 {
            sentence += "被钉选的 \(plan.pinnedKept) 则纪录不管多旧、多大,这次一则都没有动。"
        }

        return RetentionReport(removedItems: removed, freedBytes: freed, sentence: sentence)
    }

    /// 现在清一次会删掉什麽 —— 只说,不做。
    ///
    /// 它跟 `sweep()` 走的是同一段计算,所以这句话描述的就是真的会发生的事,不是另外估一个近似值。
    public func estimate() throws -> String {
        let plan = try makePlan()
        let bytes = plan.blobsToDelete.reduce(0) { $0 + fileSize(at: $1) }
            + plan.orphanBlobs.reduce(0) { $0 + fileSize(at: $1) }

        if plan.doomed.isEmpty && plan.orphanBlobs.isEmpty {
            return "目前一共有 \(plan.totalItems) 则纪录,图片档案合计 \(Retention.humanBytes(plan.totalBlobBytes)),"
                + "全部都还在保留政策的范围内,所以现在做一次清理不会删掉任何东西。"
        }
        var sentence = "目前一共有 \(plan.totalItems) 则纪录,图片档案合计 \(Retention.humanBytes(plan.totalBlobBytes))。"
            + "如果现在做一次清理,会删掉 \(plan.doomed.count) 则纪录"
        if !plan.orphanBlobs.isEmpty {
            sentence += "与 \(plan.orphanBlobs.count) 个没有任何纪录指向的孤儿档案"
        }
        sentence += ",预计释放 \(Retention.humanBytes(bytes)) 的磁碟空间。"
        sentence += plan.reasonSentence
        sentence += "这段说明只是试算,现在还没有任何东西被删除。"
        return sentence
    }

    /// 全部销毁。这是诚实版的紧急按钮:它会把话讲完,包括它做不到的部分。
    ///
    /// 正确的心智模型是「销毁金钥」,不是「把位元组磨掉」。
    /// macOS 的档案系统是写入时复制(copy-on-write)的,还会自动保留本机快照(local snapshot),
    /// 时光机也可能已经把旧版本抄走了。在这样的系统上,应用程式层的删除只能保证「从现在起读不到」,
    /// 没有办法保证「那些位元组已经从碟片上消失」。真正让旧资料与旧备份永远打不开的唯一可靠做法,
    /// 是让加密金钥消失 —— 没有金钥,那些密文就只是一堆没有意义的位元组。
    @discardableResult
    public func destroyEverything() throws -> String {
        let items = try store.recent(limit: Int(Int32.max))
        for item in items {
            try store.delete(id: item.id)
        }

        // 整个 blobs 子目录直接移除。只删这个子目录,绝对不动它的上层,
        // 因为上层还住着加密资料库与金钥档,而销毁历史不等於销毁金钥,那是拥有者另外一个决定。
        var blobRemovalFailed: String?
        if FileManager.default.fileExists(atPath: blobRoot.path) {
            do {
                try FileManager.default.removeItem(at: blobRoot)
            } catch {
                blobRemovalFailed = error.localizedDescription
            }
        }

        try store.reclaimSpace()

        var sentence = "已经删除全部 \(items.count) 则纪录"
        if let blobRemovalFailed {
            sentence += ",但存放图片的 blobs 资料夹删不掉,原因是 \(blobRemovalFailed),请自行手动删除它。"
        } else {
            sentence += ",存放图片的 blobs 资料夹也整个移除了。"
        }
        sentence += "接下来是同样重要、但比较少人讲的另一半:"
            + "这个动作只保证从现在起这支程式再也读不到那些内容,它没有办法保证那些位元组已经从磁碟上消失。"
            + "macOS 的档案系统采用写入时复制,而且会自动保留本机快照,"
            + "时光机或任何既有的备份也可能早就抄走了旧的资料库档案;"
            + "这些副本都不在这支程式能触及的范围内。"
            + "如果你的目的是让旧的备份与旧的磁碟内容永远打不开,唯一可靠的做法是销毁加密金钥,"
            + "因为没有金钥的密文就只是一堆没有意义的位元组 —— "
            + "请把心智模型放在「销毁钥匙」,而不是「把资料磨掉」。"
        return sentence
    }

    // MARK: 计画

    /// 一次清理的完整计画。算出来之後才决定要不要执行,`estimate()` 与 `sweep()` 因此不可能讲不同的话。
    private struct Plan {
        var doomed: [ClipItem] = []
        var blobsToDelete: [URL] = []
        var orphanBlobs: [URL] = []
        var totalItems: Int = 0
        var totalBlobBytes: Int = 0
        var pinnedKept: Int = 0
        var byCount: Int = 0
        var byAge: Int = 0
        var byBytes: Int = 0

        /// 把「为什麽删」讲成一句完整的中文。没有任何一条上限被踩到时回传空字串。
        var reasonSentence: String {
            var parts: [String] = []
            if byCount > 0 { parts.append("有 \(byCount) 则是因为纪录总数超过上限,从最旧的开始清") }
            if byAge > 0 { parts.append("有 \(byAge) 则是因为已经超过保留天数") }
            if byBytes > 0 { parts.append("有 \(byBytes) 则是因为图片总量超过上限,从最占空间的开始清") }
            guard !parts.isEmpty else { return "" }
            return "其中" + parts.joined(separator: ",") + "。"
        }
    }

    private func makePlan() throws -> Plan {
        // 一次把全部纪录读进记忆体。以两万笔的上限来说,这些都是短字串与几个栏位,量级完全吃得住;
        // 真正大的图片位元组从来不在纪录里,它们在磁碟上的独立档案里。
        let items = try store.recent(limit: Int(Int32.max))   // recent 已经是由新到旧排好的。
        var plan = Plan()
        plan.totalItems = items.count

        // 每一个 blob 相对路径在磁碟上占多少位元组。同一个档案可能被多则纪录共用
        // (档名是内容杂凑,复制两次同一张图会指向同一个档案),所以这里以路径为单位算一次就好。
        var sizeByPath: [String: Int] = [:]
        for item in items {
            for path in Retention.blobPaths(of: item) where sizeByPath[path] == nil {
                sizeByPath[path] = fileSize(at: blobDirectory.appendingPathComponent(path))
            }
        }

        func isProtected(_ item: ClipItem) -> Bool { policy.keepsPinned && item.isPinned }
        plan.pinnedKept = items.filter(isProtected).count

        var doomedIDs = Set<String>()

        // 第一关:笔数上限,从最旧的开始砍。
        // 钉选的纪录同样占一个名额(否则钉了一堆之後,总数就会悄悄超过拥有者设的上限),
        // 但它们永远不会被砍掉。
        if policy.maximumItems > 0 {
            var kept = 0
            for item in items {
                if isProtected(item) { kept += 1; continue }
                if kept < policy.maximumItems { kept += 1; continue }
                if doomedIDs.insert(item.id).inserted { plan.byCount += 1 }
            }
        }

        // 第二关:天数上限。
        if policy.maximumDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(policy.maximumDays) * 86_400)
            for item in items where !isProtected(item) && item.capturedAt < cutoff {
                if doomedIDs.insert(item.id).inserted { plan.byAge += 1 }
            }
        }

        // 第三关:图片总量上限。先算出「还活着的纪录」引用了哪些档案、合计多少位元组,
        // 超过上限就从最占空间的纪录开始砍,直到回到上限以内。
        // 用引用计数是必要的:两则纪录可能指向同一个档案,砍掉其中一则并不会释放任何空间。
        var referenceCount: [String: Int] = [:]
        for item in items where !doomedIDs.contains(item.id) {
            for path in Retention.blobPaths(of: item) { referenceCount[path, default: 0] += 1 }
        }
        var liveBytes = referenceCount.keys.reduce(0) { $0 + (sizeByPath[$1] ?? 0) }
        plan.totalBlobBytes = sizeByPath.values.reduce(0, +)

        if policy.maximumBlobBytes > 0 && liveBytes > policy.maximumBlobBytes {
            // 候选人按「自己占多少空间」由大到小排。先砍大的,才能用最少的删除量回到上限以内。
            let candidates = items
                .filter { !doomedIDs.contains($0.id) && !isProtected($0) }
                .map { item -> (item: ClipItem, bytes: Int) in
                    let bytes = Set(Retention.blobPaths(of: item)).reduce(0) { $0 + (sizeByPath[$1] ?? 0) }
                    return (item, bytes)
                }
                .filter { $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }

            for candidate in candidates {
                if liveBytes <= policy.maximumBlobBytes { break }
                guard doomedIDs.insert(candidate.item.id).inserted else { continue }
                plan.byBytes += 1
                // 只有在最後一个引用者也被砍掉时,那个档案的空间才真的会被释放。
                for path in Set(Retention.blobPaths(of: candidate.item)) {
                    let remaining = (referenceCount[path] ?? 0) - 1
                    referenceCount[path] = remaining
                    if remaining <= 0 { liveBytes -= sizeByPath[path] ?? 0 }
                }
            }
        }

        plan.doomed = items.filter { doomedIDs.contains($0.id) }

        // 决定哪些档案可以真的删掉:被砍掉的纪录引用过、而且没有任何幸存者还指着它。
        var survivorPaths = Set<String>()
        for item in items where !doomedIDs.contains(item.id) {
            survivorPaths.formUnion(Retention.blobPaths(of: item))
        }
        var doomedPaths = Set<String>()
        for item in plan.doomed { doomedPaths.formUnion(Retention.blobPaths(of: item)) }
        plan.blobsToDelete = doomedPaths.subtracting(survivorPaths)
            .sorted()
            .map { blobDirectory.appendingPathComponent($0) }

        // 孤儿:磁碟上存在、但没有任何一则纪录(不管是要砍的还是留下的)提到它。
        // 这种档案会出现在写档成功但纪录写入失败、或是过去某次清理中途被打断之後。
        let known = survivorPaths.union(doomedPaths)
        plan.orphanBlobs = try orphanFiles(excluding: known)

        return plan
    }

    /// 扫出 blobs 目录底下所有没有被任何纪录引用的档案。
    private func orphanFiles(excluding known: Set<String>) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: blobRoot.path) else { return [] }

        // 用 enumerator 而不是自己递回:目录结构是 blobs/杂凑前两码/档名,层数不深但档案可能很多,
        // enumerator 一次给一个,不必先把整份清单塞进记忆体。
        guard let walker = fm.enumerator(at: blobRoot,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        let rootPath = blobDirectory.standardizedFileURL.path
        var orphans: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // 换算回「相对於储存资料夹」的路径,才能跟纪录里存的 blobPath 直接比对。
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            if !known.contains(relative) { orphans.append(url) }
        }
        return orphans.sorted { $0.path < $1.path }
    }

    // MARK: 小工具

    /// 一则纪录引用到的所有外部档案相对路径。
    private static func blobPaths(of item: ClipItem) -> [String] {
        item.representations.compactMap(\.blobPath)
    }

    /// 档案在磁碟上占多少位元组;读不到就当成 0,因为读不到的档案本来就释放不出空间。
    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// 把位元组数写成人看得懂的样子。刻意自己算而不用系统的格式化工具,
    /// 是为了让同一句中文在任何语言环境下都长得一样,不会因为系统语言不同而变成英文单位。
    static func humanBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) 个位元组" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
