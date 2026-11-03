import Foundation

// Intentionally not Codable: raw secrets must never enter the record store.
public struct CleanupLogin: Sendable {
    public let accountID: String, vaultID: String, itemID: String, title: String, username: String
    public let urls: [String]
    public let password: String
    public var id: String { accountID + ":" + vaultID + ":" + itemID }
    public init(accountID: String, vaultID: String, itemID: String, title: String, username: String, urls: [String], password: String) {
        self.accountID = accountID; self.vaultID = vaultID; self.itemID = itemID; self.title = title; self.username = username; self.urls = urls; self.password = password
    }
}
public enum CleanupStatus: String, Codable, CaseIterable, Sendable {
    case active = "現役", important = "重要", closed = "退会済み", investigating = "調査中", archiveCandidate = "アーカイブ候補", completed = "対応完了"
}
public enum AccountCategory: String, Codable, CaseIterable, Sendable {
    case email = "メール", finance = "金融", domain = "ドメイン管理", cloud = "クラウド管理", other = "その他"
    public static func suggest(hosts: [String]) -> Self {
        func matches(_ domains: [String]) -> Bool { hosts.contains { h in domains.contains { h == $0 || h.hasSuffix("." + $0) } } }
        if matches(["accounts.google.com", "gmail.com", "outlook.com", "login.live.com", "proton.me", "icloud.com", "mail.yahoo.co.jp"]) { return .email }
        if matches(["paypal.com", "wise.com", "smbc.co.jp", "mufg.jp", "rakuten-bank.co.jp"]) { return .finance }
        if matches(["cloudflare.com", "namecheap.com", "onamae.com", "value-domain.com"]) { return .domain }
        if matches(["aws.amazon.com", "console.aws.amazon.com", "portal.azure.com", "console.cloud.google.com", "digitalocean.com"]) { return .cloud }
        return .other
    }
}
public enum LocalStrength: String, Sendable {
    case missing = "未設定・判定対象外", weak = "弱い可能性", moderate = "要確認", noSimpleWarning = "簡易チェック警告なし"
    public static func evaluate(_ password: String) -> Self {
        if password.isEmpty { return .missing }
        let lower = password.lowercased()
        let common = ["password", "123456", "qwerty", "letmein", "welcome", "admin", "iloveyou"]
        if password.count < 10 || Set(password).count <= 3 || common.contains(where: { lower.contains($0) }) { return .weak }
        if password.count < 14 { return .moderate }
        return .noSimpleWarning
    }
}
public struct CleanupRow: Identifiable, Sendable {
    public let id: String, itemID: String, vaultID: String, title: String, username: String
    public let hosts: [String]
    public let strength: LocalStrength
    public let suggestedCategory: AccountCategory
    public var reuseCount = 1
    public var reuseGroup: Int? = nil
    public var reuseDescription = "再利用なし（選択範囲内）"
    public var duplicateIDs: [String] = []
    public var caseVariantIDs: [String] = []
    public var riskSummary: String { "再利用\(reuseCount)項目 / \(strength.rawValue)" }
}
public enum CleanupAnalyzer {
    public static func analyze(_ logins: [CleanupLogin]) -> [CleanupRow] {
        // Deduplicate multi-URL representations by actual account/vault/item ID.
        var seen = Set<String>()
        let items = logins.filter { seen.insert($0.id).inserted }
        var rows = items.map { item in
            let hosts = Set(item.urls.compactMap { url -> String? in
                guard let c = URLComponents(string: url), ["http", "https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host else { return nil }
                return host.lowercased()
            }).sorted()
            return CleanupRow(id: item.id, itemID: item.itemID, vaultID: item.vaultID, title: item.title, username: item.username, hosts: hosts, strength: .evaluate(item.password), suggestedCategory: .suggest(hosts: hosts))
        }
        // These dictionaries and their password keys exist only during this function.
        var passwords = [Data: [Int]](), accounts = [String: [Int]](), folded = [String: [Int]]()
        for i in items.indices {
            if !items[i].password.isEmpty { passwords[Data(items[i].password.utf8), default: []].append(i) }
            if !rows[i].username.isEmpty {
                for host in rows[i].hosts {
                    accounts[host + "\u{0}" + rows[i].username, default: []].append(i)
                    folded[host + "\u{0}" + rows[i].username.lowercased(), default: []].append(i)
                }
            }
        }
        var roots = Array(rows.indices)
        func root(_ i: Int) -> Int { var n = i; while roots[n] != n { n = roots[n] }; return n }
        for candidates in accounts.values {
            if let first = candidates.first { for i in candidates.dropFirst() { roots[root(i)] = root(first) } }
        }
        let groups = passwords.values.filter { $0.count > 1 }.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        for (number, group) in groups.enumerated() {
            let hosts = Set(group.flatMap { rows[$0].hosts })
            let clusterCount = Set(group.map { root($0) }).count
            let unknown = group.contains { rows[$0].hosts.isEmpty || rows[$0].username.isEmpty }
            let description: String
            if unknown { description = "同じパスワード（URLまたはIDがなくサービス判定不可）" }
            else if clusterCount == 1 { description = "同一アカウントの重複候補のみ" }
            else if hosts.count > 1 { description = "別ホスト間の再利用（重複候補が混在する場合あり）" }
            else { description = "同一ホスト内の別IDで再利用" }
            for i in group { rows[i].reuseCount = group.count; rows[i].reuseGroup = number + 1; rows[i].reuseDescription = description }
        }
        for i in rows.indices where !rows[i].username.isEmpty {
            var exact = Set<Int>(), variants = Set<Int>()
            for host in rows[i].hosts {
                exact.formUnion(accounts[host + "\u{0}" + rows[i].username] ?? [])
                variants.formUnion(folded[host + "\u{0}" + rows[i].username.lowercased()] ?? [])
            }
            exact.remove(i); variants.subtract(exact); variants.remove(i)
            rows[i].duplicateIDs = exact.sorted().map { rows[$0].id }
            rows[i].caseVariantIDs = variants.sorted().map { rows[$0].id }
        }
        return rows
    }
}
public struct CleanupEvent: Codable, Sendable {
    public let date: Date
    public let status: CleanupStatus
    public let category: AccountCategory
}
public struct CleanupRecord: Codable, Sendable {
    public var status: CleanupStatus = .investigating
    public var category: AccountCategory = .other
    public var reviewedAt: Date? = nil
    public var history: [CleanupEvent] = []
    public init() {}
    public mutating func update(status: CleanupStatus, category: AccountCategory) {
        self.status = status; self.category = category; reviewedAt = Date()
        history.append(CleanupEvent(date: reviewedAt!, status: status, category: category))
        history = Array(history.suffix(30))
    }
}
// Only scoped IDs, fixed-choice status/category and dates can be serialized.
public struct CleanupStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [String: CleanupRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { return try JSONDecoder().decode([String: CleanupRecord].self, from: Data(contentsOf: url)) }
        catch { throw BridgeError.message("対応記録を読み込めません。元ファイルは上書きしません。") }
    }
    public func save(_ records: [String: CleanupRecord]) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(records).write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw BridgeError.message("対応記録を保存できませんでした。変更は保存されていません。") }
    }
}
