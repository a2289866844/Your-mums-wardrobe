// 资料库金钥的存放位置管理。
//
// 这个档案要回答的是一个非常具体、而且已经在这台机器上被量测过的问题:
// 加密资料库的金钥到底该放哪里。目前的答案是「放在档案里」,而且那是刻意的选择,不是还没做完。
//
// 为什麽不放钥匙圈(先讲清楚,免得日後有人以为是漏做):
//   一、这支程式采用 ad-hoc 签章(codesign --sign -),因为拥有者没有付费的 Apple Developer 帐号。
//       ad-hoc 签章的内容每次重新编译都会变,macOS 於是把每一次建置都当成一支全新的程式。
//       钥匙圈的存取控制是绑在程式身分上的,身分一变就要重新取得授权,也就是要输入一次登入密码。
//       开发期间一天要编译几十次,那就是一天几十次的密码视窗,这条路实际上走不通。
//   二、新版的「资料保护钥匙圈」(data protection keychain)完全不能用:它要求应用程式带着
//       Apple 签发的身分与 keychain-access-groups 权限,没有的话 SecItemAdd 直接回
//       errSecMissingEntitlement,也就是错误码 -34018。这一点已经实测确认。
//
// 所以预设留在档案,并且由 `status()` 用完整的句子把这个选择的代价讲白:金钥就躺在加密资料库旁边。
// 想要更硬的保护时,再由拥有者自己呼叫 `migrateToKeychain()` 搬进旧版的档案式钥匙圈。
import Foundation
import Security

// MARK: - 位置与状态

/// 金钥现在放在哪里。
public enum KeyLocation: String, Codable, Sendable {
    case file       // 放在储存资料夹里的 db.key 档案,权限 0600
    case keychain   // 放在旧版(档案式)钥匙圈里,由 macOS 保管
}

/// 一次金钥位置查询的结果。`sentence` 是要直接显示给拥有者看的完整中文句子,
/// 不是给程式解析用的代号,所以措辞刻意把代价讲满,不做任何美化。
public struct KeyStoreStatus: Sendable {
    public let location: KeyLocation
    public let sentence: String
    /// 只有搬进钥匙圈才算「已经加固」。档案模式再怎麽把权限收紧,金钥仍然是一个读得到的档案。
    public let isHardened: Bool

    public init(location: KeyLocation, sentence: String, isHardened: Bool) {
        self.location = location
        self.sentence = sentence
        self.isHardened = isHardened
    }
}

// MARK: - 错误型别

/// 金钥管理这一层唯一往外丢的错误。
///
/// 每一句都写成完整的中文句子,而且只要牵涉到搬迁,句子里一定明讲「原本的金钥还在不在」。
/// 理由很直接:金钥没了等於整份历史永远解不开,拥有者在这种时刻最需要知道的就是「我还救得回来吗」。
public enum KeyStoreError: Error, CustomStringConvertible {
    case cannotCreateDirectory(path: String, reason: String)
    case unreadableKeyFile(path: String)
    case randomGeneratorUnavailable
    case cannotWriteKeyFile(path: String, reason: String)
    case noKeyToMigrate
    case keychainWriteFailed(status: OSStatus)
    case keychainReadBackFailed(status: OSStatus)
    case keychainContentMismatch
    case keychainUnavailableInThisContext
    case cannotRemoveKeyFile(path: String, reason: String)

    public var description: String {
        switch self {
        case let .cannotCreateDirectory(path, reason):
            return "无法建立存放金钥的资料夹 \(path),原因是 \(reason)。"
        case let .unreadableKeyFile(path):
            return "找到了金钥档 \(path),但里面的内容已经损坏而无法解读。"
                + "如果你愿意放弃现有的剪贴板历史,可以直接删掉整个 Clipd 资料夹重新开始。"
        case .randomGeneratorUnavailable:
            return "系统的乱数产生器没有回应,因此无法替资料库产生新的通行码。"
        case let .cannotWriteKeyFile(path, reason):
            return "无法在 \(path) 建立金钥档,因此没有办法开启加密的资料库,原因是 \(reason)。"
        case .noKeyToMigrate:
            return "目前还没有任何金钥可以搬迁,因为这台机器上还没有建立过资料库。"
                + "请先正常启动一次程式让它产生金钥,再回来做搬迁。"
        case let .keychainWriteFailed(status):
            return "把金钥写进钥匙圈失败,系统回传的错误码是 \(status)。"
                + "原本的金钥档没有被动过,资料库仍然打得开,这次搬迁等於没有发生。"
                + KeyStoreError.hint(for: status)
        case let .keychainReadBackFailed(status):
            return "金钥虽然写进了钥匙圈,但立刻读回来确认的时候失败了,系统回传的错误码是 \(status)。"
                + "为了安全起见,原本的金钥档一个字都没有动,资料库仍然打得开,这次搬迁等於没有发生。"
                + KeyStoreError.hint(for: status)
        case .keychainContentMismatch:
            return "从钥匙圈读回来的金钥内容与写进去的不一样,这代表钥匙圈这条路目前不可靠。"
                + "原本的金钥档没有被动过,资料库仍然打得开,这次搬迁等於没有发生。"
        case .keychainUnavailableInThisContext:
            return "这个 KeyStore 是在「不准碰钥匙圈」的模式下建立的(自动化测试就是这样跑的),"
                + "所以不能做任何与钥匙圈有关的操作。原本的金钥档没有被动过。"
        case let .cannotRemoveKeyFile(path, reason):
            return "金钥已经安全地存进钥匙圈,但旧的金钥档 \(path) 删不掉,原因是 \(reason)。"
                + "现在磁碟上同时存在两份金钥,请自行手动删除那个档案,否则加固等於没有做到。"
        }
    }

    /// 把几个最常见、而且最容易被误解的系统错误码翻成人话。
    private static func hint(for status: OSStatus) -> String {
        switch status {
        case -34018:
            return "错误码 -34018 是 errSecMissingEntitlement,意思是这支程式没有 Apple 签发的身分,"
                + "因此用不了新版的资料保护钥匙圈;这也正是这个专案预设把金钥放在档案里的原因。"
        case errSecUserCanceled:
            return "这个错误码代表你在系统跳出的授权视窗上按了取消。"
        case errSecAuthFailed:
            return "这个错误码代表钥匙圈的授权没有通过,通常是登入密码输入错误。"
        default:
            return ""
        }
    }
}

// MARK: - 本体

/// 管理资料库金钥要放在哪里、怎麽取出来、以及怎麽在两个位置之间搬迁。
///
/// 这个类别不碰资料库本身,它只负责那一串通行码字串。呼叫端拿到字串之後再交给 `Store`。
public final class KeyStore {

    /// 钥匙圈里的服务名称。改动它等於让旧的项目变成找不到的孤儿,所以固定写死在这里。
    private static let keychainService = "dev.clipd.db"
    /// 钥匙圈项目的帐号栏位。一支程式只有一把资料库金钥,所以固定用同一个名字。
    private static let keychainAccount = "clipd-database-passphrase"
    /// 金钥档的档名。这是既有安装已经在用的名字,绝对不能改,改了旧使用者就找不到自己的金钥。
    private static let keyFileName = "db.key"

    private let directory: URL
    private let keyURL: URL

    /// 是否允许这个实例碰钥匙圈。
    ///
    /// 正式执行时永远是 true。自动化测试一律传 false,因为测试绝对不可以让拥有者的萤幕上
    /// 跳出登入密码视窗,也不可以在他真正的钥匙圈里留下垃圾项目。
    private let keychainEnabled: Bool

    public init(directory: URL) {
        self.directory = directory
        self.keyURL = directory.appendingPathComponent(KeyStore.keyFileName, isDirectory: false)
        self.keychainEnabled = true
    }

    /// 测试专用的建构子:把钥匙圈整条路关掉,测试因此不可能碰到真实的钥匙圈。
    init(directory: URL, keychainEnabled: Bool) {
        self.directory = directory
        self.keyURL = directory.appendingPathComponent(KeyStore.keyFileName, isDirectory: false)
        self.keychainEnabled = keychainEnabled
    }

    /// 金钥档的完整路径。介面上要把「金钥就在这里」指给拥有者看的时候会用到。
    public var keyFileURL: URL { keyURL }

    // MARK: 取得金钥

    /// 拿到资料库通行码;没有的话就产生一把新的并存成档案。
    ///
    /// 查找顺序刻意是「先档案、再钥匙圈」,原因有两个:
    /// 一、档案是这个专案的预设位置,先看它可以让绝大多数的启动完全不碰钥匙圈,连一次系统呼叫都省下来;
    /// 二、找不到东西的钥匙圈查询不会跳出任何视窗,所以只有真的搬迁过(档案已被删掉)的安装
    ///     才会走到钥匙圈那一段,平常的开发迴圈不受影响。
    public func loadOrCreate() throws -> String {
        if let existing = try readKeyFile() { return existing }
        // 这里用 try? 是刻意的:钥匙圈查询失败(例如拥有者按了取消)不该让程式整个起不来,
        // 那种情况退回「产生一把新的档案金钥」还有路可走,而丢错误就只剩下死路一条。
        if keychainEnabled, let stored = try? readKeychain() { return stored }
        return try createKeyFile()
    }

    // MARK: 状态

    /// 用一句完整的中文说清楚金钥现在在哪里、以及那对拥有者代表什麽。
    ///
    /// 这个方法不丢错误:拥有者问「我的金钥在哪」的时候,最不该拿到的答案就是一个错误。
    /// 读取失败时一律回报档案模式,因为那才是这个专案的预设,句子本身也会把风险讲完整。
    public func status() -> KeyStoreStatus {
        let fileExists = FileManager.default.fileExists(atPath: keyURL.path)
        if !fileExists, keychainEnabled, (try? readKeychain()) != nil {
            return KeyStoreStatus(location: .keychain, sentence: sentence(for: .keychain), isHardened: true)
        }
        if fileExists {
            return KeyStoreStatus(location: .file, sentence: sentence(for: .file), isHardened: false)
        }
        // 两边都没有,代表程式还没有真正启动过。这仍然算档案模式,因为下一次启动就会在这里建出档案。
        return KeyStoreStatus(location: .file, sentence: notYetCreatedSentence, isHardened: false)
    }

    /// 依位置产生要显示给拥有者看的那一句话。
    ///
    /// 独立成一个方法,是为了让自动化测试能够在完全不碰真实钥匙圈的前提下,
    /// 检查两个位置的说法确实不一样、而且各自该讲明白的代价都讲到了。
    func sentence(for location: KeyLocation) -> String {
        switch location {
        case .file: return fileSentence
        case .keychain: return KeyStore.keychainSentence
        }
    }

    /// 档案模式要讲的话。这段刻意不留任何余地:它是这个专案目前真实的安全边界。
    private var fileSentence: String {
        "资料库的金钥现在存放在档案 \(keyURL.path) 里,也就是跟加密资料库放在同一个资料夹,"
            + "锁跟钥匙摆在一起。这代表任何人、任何程式只要读得到你的家目录,"
            + "就可以拿这把金钥直接打开你完整的剪贴板历史。"
            + "这样的配置真正挡得住的只有两种情况:整台关机的电脑或硬碟被别人拿走,以及备份档被复制走,"
            + "因为那时候磁碟上留下的确实只是一堆解不开的密文。"
            + "但它挡不住任何以你这个使用者身分执行中的软体 —— 那种程式读得到这个档案,就等於读得到全部历史。"
            + "之所以维持这个设定,是因为这支程式采用 ad-hoc 签章,身分每次重新编译都会变,"
            + "把金钥放进钥匙圈会让 macOS 每次重建之後都跳出登入密码视窗,那会让日常开发无法进行。"
    }

    private var notYetCreatedSentence: String {
        "这台机器上还没有建立过资料库金钥,所以现在什麽都还没有存在磁碟上;"
            + "下一次启动程式时,系统会产生一把新的金钥并写成档案 \(keyURL.path),"
            + "届时金钥就会跟加密资料库放在同一个资料夹里,读得到你家目录的程式也就读得到那把金钥。"
    }

    /// 钥匙圈模式要讲的话,包含那个必须先讲明白的代价。
    private static let keychainSentence: String =
        "资料库的金钥已经交给 macOS 的钥匙圈保管,服务名称是 \(KeyStore.keychainService),"
        + "磁碟上不再有任何一个装着金钥的明文档案,程式每次要用都必须向系统请求。"
        + "这一份金钥使用的是「只限本机、解锁後才可读取」的保护等级,"
        + "所以它永远不会同步到 iCloud,也永远不会随着备份被还原到另一台 Mac 上。"
        + "要付出的代价是:这支程式采用 ad-hoc 签章,每次重新编译出来的身分都不一样,"
        + "macOS 会把新的执行档当成另一支程式,因此每次重新建置之後第一次读取金钥时,"
        + "系统都会再问一次你的登入密码,这是正常现象,不是程式出错。"

    // MARK: 搬进钥匙圈

    /// 把金钥从档案搬进旧版(档案式)钥匙圈,成功时回传一句说明发生了什麽事的中文。
    ///
    /// 每一步的顺序都是刻意的:先写、再读回来确认、最後才删档案。
    /// 绝对不可以先删档案再写钥匙圈 —— 只要写入那一步失败,金钥就永远消失,
    /// 而金钥消失等於整个加密资料库变成一堆再也解不开的乱码,拥有者过去所有的剪贴板历史当场归零。
    /// 这不是可以事後补救的错误,所以这里宁可留下两份金钥,也不接受留下零份的风险。
    @discardableResult
    public func migrateToKeychain() throws -> String {
        guard keychainEnabled else { throw KeyStoreError.keychainUnavailableInThisContext }

        guard let key = try readKeyFile() else {
            // 档案不在,先确认是不是早就搬过了,免得对着已经完成的状态再报一次错。
            if try readKeychain() != nil {
                return "金钥早就已经在钥匙圈里了,档案模式的金钥档并不存在,所以这次没有任何东西被改动。"
            }
            throw KeyStoreError.noKeyToMigrate
        }

        try writeKeychain(key)

        // 读回来确认。写入回报成功但读不回来的情况是真的会发生的(例如存取控制被系统挡下),
        // 少了这一步,我们会在金钥其实拿不到的状态下把档案删掉。
        guard let readBack = try readKeychain() else {
            throw KeyStoreError.keychainReadBackFailed(status: errSecItemNotFound)
        }
        guard readBack == key else {
            throw KeyStoreError.keychainContentMismatch
        }

        // 到这里才动档案。确认过钥匙圈里那一份读得回来、而且内容一致之後,留着明文档案才是真正的风险。
        do {
            try FileManager.default.removeItem(at: keyURL)
        } catch {
            throw KeyStoreError.cannotRemoveKeyFile(path: keyURL.path, reason: error.localizedDescription)
        }

        return "金钥已经成功搬进钥匙圈,而且立刻读回来确认过内容一致,原本的金钥档 \(keyURL.path) 也已经删除。"
            + "从现在起磁碟上不再有明文的金钥档案。"
            + "请注意:因为这支程式是 ad-hoc 签章,每次重新编译身分都会改变,"
            + "所以每次重新建置之後第一次启动时,macOS 都会再问一次你的登入密码。"
    }

    /// 把金钥从钥匙圈搬回档案,成功时回传一句说明发生了什麽事的中文。
    ///
    /// 顺序同样是先写档案、确认读得回来,最後才删掉钥匙圈里那一份,理由与搬进去时完全一样。
    @discardableResult
    public func migrateToFile() throws -> String {
        guard keychainEnabled else { throw KeyStoreError.keychainUnavailableInThisContext }

        if let existing = try readKeyFile() {
            // 档案已经在了。这时如果钥匙圈里还留着一份一模一样的,顺手清掉,让状态收敛成单一来源。
            if let stored = try? readKeychain(), stored == existing {
                deleteKeychain()
                return "金钥本来就已经在档案 \(keyURL.path) 里了,钥匙圈里那份重复的旧资料已经一并清除。"
            }
            return "金钥本来就已经在档案 \(keyURL.path) 里了,所以这次没有任何东西被改动。"
        }

        guard let key = try readKeychain() else {
            throw KeyStoreError.noKeyToMigrate
        }

        try write(key: key)

        guard let readBack = try readKeyFile(), readBack == key else {
            throw KeyStoreError.keychainContentMismatch
        }

        // 确认档案这一份读得回来之後,才把钥匙圈里那一份删掉。
        deleteKeychain()

        return "金钥已经从钥匙圈搬回档案 \(keyURL.path),权限设定为只有你本人能读写,"
            + "钥匙圈里那一份已经删除。"
            + "这样一来重新编译之後就不会再跳出登入密码视窗,代价是金钥重新回到加密资料库旁边,"
            + "读得到你家目录的程式也就读得到它。"
    }

    // MARK: 档案这一侧

    /// 读现有的金钥档;档案不存在回传 nil,存在但内容坏掉则丢错误。
    ///
    /// 格式必须与既有安装完全一致:一个纯 UTF-8 文字档,内容就是 base64 字串本身,
    /// 读进来之後去掉前後空白与换行。任何格式上的「改良」都会让旧安装打不开自己的资料库。
    private func readKeyFile() throws -> String? {
        guard let data = FileManager.default.contents(atPath: keyURL.path) else { return nil }
        guard let existing = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty
        else {
            throw KeyStoreError.unreadableKeyFile(path: keyURL.path)
        }
        return existing
    }

    /// 产生一把新金钥并写成档案。
    private func createKeyFile() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyStoreError.randomGeneratorUnavailable
        }
        // 转成 base64 是因为 SQLCipher 的 PRAGMA key 收的是字串,原始位元组里会有放不进字串的值。
        let passphrase = Data(bytes).base64EncodedString()
        try write(key: passphrase)
        return passphrase
    }

    /// 把金钥写成权限 0600 的档案,并且确保上层资料夹是 0700。
    private func write(key: String) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw KeyStoreError.cannotCreateDirectory(path: directory.path, reason: error.localizedDescription)
        }
        // 上面那行只有在「这次真的由我们建立这个资料夹」时才会套用权限。实测过:资料夹如果是程式
        // 其他部分先建好的,权限会是预设的 0755,代表同一台机器上的其他使用者列得出里面有哪些档案。
        // 所以这里不管资料夹是谁建的,都再强制设定一次,确保只有本人进得去。
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // 已经存在时 createFile 会覆盖内容,但不保证套用新的权限属性,所以先删再建,权限才一定是 0600。
        if fm.fileExists(atPath: keyURL.path) {
            try? fm.removeItem(at: keyURL)
        }
        guard fm.createFile(atPath: keyURL.path,
                            contents: Data(key.utf8),
                            attributes: [.posixPermissions: 0o600])
        else {
            throw KeyStoreError.cannotWriteKeyFile(path: keyURL.path,
                                                   reason: "系统拒绝在这个位置建立档案,通常是资料夹权限不足或路径不存在")
        }
    }

    // MARK: 钥匙圈这一侧

    /// 组出用来指认「我们那一个」钥匙圈项目的查询条件。
    ///
    /// `kSecUseDataProtectionKeychain` 明确设成 false 是这整段的关键,而且必须是显式的:
    /// 设成 true(或在某些情境下的预设行为)会把请求送去新版的资料保护钥匙圈,
    /// 而那个钥匙圈要求应用程式带着 Apple 签发的身分与 keychain-access-groups 权限;
    /// 这支程式是 ad-hoc 签章,没有那些东西,SecItemAdd 会直接回 errSecMissingEntitlement(-34018)。
    /// 所以这里一律走旧版的档案式钥匙圈,那是这个签章条件下唯一真的能用的路。
    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    /// 从钥匙圈读金钥。找不到项目回传 nil,那不是错误 —— 预设本来就没有这个项目。
    private func readKeychain() throws -> String? {
        var query = KeyStore.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainReadBackFailed(status: status)
        }
        guard let data = result as? Data,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw KeyStoreError.keychainContentMismatch
        }
        return text
    }

    /// 把金钥写进钥匙圈。
    ///
    /// 存取等级选 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
    /// 「WhenUnlocked」代表萤幕锁着的时候连本机程式都读不到;
    /// 「ThisDeviceOnly」代表这一项不会进入 iCloud 钥匙圈,也不会被写进加密备份还原到另一台 Mac。
    /// 剪贴板历史的金钥没有任何理由离开这台机器,所以这是唯一合理的等级。
    private func writeKeychain(_ key: String) throws {
        // 先删掉可能存在的旧项目。SecItemAdd 撞到同样的 service+account 会回 errSecDuplicateItem,
        // 那时若不处理就会误判成「搬迁失败」,而其实只是上一次留下的残骸。
        deleteKeychain()

        var query = KeyStore.baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrLabel as String] = "clipd 剪贴板资料库的加密金钥"
        query[kSecAttrDescription as String] = "遗失这一项之後,既有的剪贴板历史将永远无法解密。"

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainWriteFailed(status: status)
        }
    }

    /// 删掉钥匙圈里的项目。刻意不回报结果:呼叫这个方法的每一处要的都是「删完之後它不存在」,
    /// 而「本来就不存在」同样满足这个要求。
    private func deleteKeychain() {
        SecItemDelete(KeyStore.baseQuery() as CFDictionary)
    }
}
