import Foundation
import Testing
@testable import ClipdCore

// 这一整份测试有一条不可以违反的红线:绝对不碰真实的钥匙圈。
//
// 理由有两个,两个都很实际。第一,钥匙圈的存取会让 macOS 在拥有者的萤幕上跳出登入密码视窗,
// 而自动化测试跑起来的时候人不一定在电脑前面,一个跳出来就卡住的视窗等於整个测试挂住。
// 第二,测试若真的写进钥匙圈,就会在拥有者的登入钥匙圈里留下垃圾项目,那是测试没有资格造成的副作用。
// 所以底下所有的 KeyStore 都用 `keychainEnabled: false` 这个内部建构子建出来,
// 那条路径在程式里是明确关掉的,不可能意外送出任何一个钥匙圈请求。

/// 每个测试拿一个全新的暂存资料夹,测完整个删掉,避免上一个测试的残留变成下一个测试的隐形前提。
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-keystore-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        // 测试中途可能把资料夹权限调成唯读,不先调回来会连删都删不掉,残骸会一直留在暂存区。
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try body(directory)
}

@Test("第一次呼叫会建立金钥档,再呼叫一次会拿到同一把金钥")
func 金钥档建立之後再读回来是同一把() throws {
    try withTemporaryDirectory { directory in
        let keyStore = KeyStore(directory: directory, keychainEnabled: false)

        let created = try keyStore.loadOrCreate()
        #expect(!created.isEmpty)

        let keyURL = directory.appendingPathComponent("db.key")
        #expect(FileManager.default.fileExists(atPath: keyURL.path))

        let reloaded = try keyStore.loadOrCreate()
        #expect(reloaded == created, "第二次读到的金钥必须与第一次完全相同,否则既有的资料库会打不开")

        // 换一个物件再读一次,确认金钥真的是从磁碟读回来的,而不是留在记忆体里的快取。
        let another = KeyStore(directory: directory, keychainEnabled: false)
        #expect(try another.loadOrCreate() == created)
    }
}

@Test("金钥档的格式与权限必须与既有安装完全一致")
func 金钥档的格式与权限维持既有约定() throws {
    try withTemporaryDirectory { directory in
        let keyStore = KeyStore(directory: directory, keychainEnabled: false)
        let key = try keyStore.loadOrCreate()

        let keyURL = directory.appendingPathComponent("db.key")
        let raw = try #require(FileManager.default.contents(atPath: keyURL.path))
        let text = try #require(String(data: raw, encoding: .utf8))
        #expect(text == key, "档案内容就是通行码本身,不包在任何格式里;改这一点会让旧安装打不开资料库")

        // 32 个随机位元组编成 base64 固定是 44 个字元,长度对不上代表金钥强度被改动过。
        let decoded = try #require(Data(base64Encoded: key))
        #expect(decoded.count == 32)

        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600, "金钥档必须只有本人读得到")
    }
}

@Test("内容坏掉的金钥档要明确报错,而不是默默产生一把新的")
func 坏掉的金钥档会明确报错() throws {
    try withTemporaryDirectory { directory in
        let keyURL = directory.appendingPathComponent("db.key")
        try Data("   \n".utf8).write(to: keyURL)

        let keyStore = KeyStore(directory: directory, keychainEnabled: false)
        #expect(throws: KeyStoreError.self) {
            // 这里绝对不可以静静地换一把新金钥:那会让原本还救得回来的资料库变成永远打不开。
            _ = try keyStore.loadOrCreate()
        }
    }
}

@Test("两个存放位置的说明必须讲不同的话,而且各自要把代价讲明白")
func 两个位置的状态说明各自讲清楚代价() throws {
    try withTemporaryDirectory { directory in
        let keyStore = KeyStore(directory: directory, keychainEnabled: false)
        _ = try keyStore.loadOrCreate()

        let status = keyStore.status()
        #expect(status.location == .file)
        #expect(status.isHardened == false, "金钥还是一个读得到的档案,这不能算已经加固")

        let fileSentence = keyStore.sentence(for: .file)
        let keychainSentence = keyStore.sentence(for: .keychain)
        #expect(status.sentence == fileSentence)
        #expect(fileSentence != keychainSentence, "两个位置的处境完全不同,说明不可以是同一句话")

        // 档案模式那句话必须把真正的风险摊开来讲,不可以只说「已加密」就带过。
        #expect(fileSentence.contains(directory.path))
        #expect(fileSentence.contains("家目录"))
        #expect(fileSentence.contains("备份"))
        #expect(fileSentence.contains("挡不住"))

        // 钥匙圈那句话必须讲到三件事:系统保管、不会离开这台机器、以及重新编译会再问密码。
        #expect(keychainSentence.contains("钥匙圈"))
        #expect(keychainSentence.contains("iCloud"))
        #expect(keychainSentence.contains("登入密码"))
        #expect(keychainSentence.contains("ad-hoc"))
    }
}

@Test("还没建立过金钥时,状态要说清楚现在磁碟上什麽都还没有")
func 还没建立金钥时的状态说明() throws {
    try withTemporaryDirectory { directory in
        let keyStore = KeyStore(directory: directory, keychainEnabled: false)
        let status = keyStore.status()
        #expect(status.location == .file)
        #expect(status.isHardened == false)
        #expect(status.sentence.contains("还没有建立"))
    }
}

@Test("搬迁失败时金钥档必须原封不动地留着")
func 搬迁失败不会动到原本的金钥档() throws {
    try withTemporaryDirectory { directory in
        let keyStore = KeyStore(directory: directory, keychainEnabled: false)
        let key = try keyStore.loadOrCreate()
        let keyURL = directory.appendingPathComponent("db.key")

        // 这个实例不准碰钥匙圈,所以搬迁一定会失败。要验的不是它为什麽失败,
        // 而是失败之後那把金钥还在不在 —— 金钥没了等於整份历史永远解不开。
        #expect(throws: KeyStoreError.self) {
            _ = try keyStore.migrateToKeychain()
        }
        #expect(FileManager.default.fileExists(atPath: keyURL.path))
        #expect(try keyStore.loadOrCreate() == key, "搬迁失败之後,资料库必须仍然打得开")

        #expect(throws: KeyStoreError.self) {
            _ = try keyStore.migrateToFile()
        }
        #expect(try keyStore.loadOrCreate() == key)
    }
}

@Test("写不进去的位置要明确报错,而不是回传一把根本没存下来的金钥")
func 资料夹不能写入时明确报错() throws {
    try withTemporaryDirectory { directory in
        // 这里刻意不用「把资料夹权限调成 0o500」来模拟不可写。实测过:那招在这个程式上没有用,
        // 因为写入金钥之前会先把资料夹强制设回 0o700(那一行的用意是收紧权限),而资料夹是我们自己的,
        // 所以那次 chmod 会成功,不可写的状态当场被解除。真正稳定的不可写位置是「上层根本不是资料夹」:
        // 底下先放一个普通档案,再要求把金钥放进它的下一层,系统一定会拒绝,而且不依赖任何权限设定。
        let blocker = directory.appendingPathComponent("这其实是一个档案")
        try Data("我不是资料夹".utf8).write(to: blocker)
        let locked = blocker.appendingPathComponent("子资料夹", isDirectory: true)

        let keyStore = KeyStore(directory: locked, keychainEnabled: false)
        #expect(throws: KeyStoreError.self) {
            // 若这里回传了一把金钥,呼叫端会拿它去加密资料库,而那把金钥其实没有被存下来,
            // 下一次启动就再也找不到 —— 那是最糟糕的一种失败,所以一定要当场丢错误。
            _ = try keyStore.loadOrCreate()
        }
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("db.key").path),
                "失败之後不可以留下一个半成品的金钥档")
    }
}

@Test("错误讯息要写成完整的中文句子,而且讲清楚原本的金钥还在不在")
func 错误讯息是完整的中文句子() throws {
    let writeFailed = KeyStoreError.keychainWriteFailed(status: -34018)
    #expect(writeFailed.description.contains("原本的金钥档没有被动过"))
    #expect(writeFailed.description.contains("errSecMissingEntitlement"))
    #expect(writeFailed.description.hasSuffix("。"))

    let readBackFailed = KeyStoreError.keychainReadBackFailed(status: errSecItemNotFound)
    #expect(readBackFailed.description.contains("一个字都没有动"))
}
