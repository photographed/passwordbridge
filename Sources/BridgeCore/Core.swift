import Foundation

public struct Entry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let username: String
    public let password: String
    public let otp: String
    public let notes: String
    public init(id: String = UUID().uuidString, title: String, url: String, username: String, password: String, otp: String = "", notes: String = "") {
        self.id = id; self.title = title; self.url = url; self.username = username; self.password = password; self.otp = otp; self.notes = notes
    }
    // Preserve paths, ports, subdomains, username case and secret bytes.
    public var identity: String {
        guard var c = URLComponents(string: url), let host = c.host, ["https", "http"].contains(c.scheme?.lowercased() ?? "") else { return url + "\u{0}" + username }
        c.host = host.lowercased(); c.scheme = c.scheme?.lowercased()
        if c.path == "/" { c.path = "" }
        return (c.string ?? url) + "\u{0}" + username
    }
    public var host: String { URLComponents(string: url)?.host?.lowercased() ?? "" }
    public func sameContent(_ other: Entry) -> Bool {
        password == other.password && otp == other.otp && notes == other.notes
    }
}
public enum BridgeError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public enum CSV {
    public static func parse(_ input: String) throws -> [[String]] {
        let chars = Array(input.hasPrefix("\u{feff}") ? String(input.dropFirst()) : input)
        var rows = [[String]](), row = [String](), field = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(ch) }
            } else if ch == "," { row.append(field); field = ""; closed = false }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []; field = ""; closed = false
            } else if ch == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                if closed || ch == "\"" { throw BridgeError.message("CSVの引用符が不正です。") }
                field.append(ch)
            }
            i += 1
        }
        if quoted { throw BridgeError.message("CSVの引用符が閉じていません。") }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
    public static func entries(_ input: String) throws -> [Entry] {
        let rows = try parse(input)
        guard let header = rows.first else { throw BridgeError.message("CSVが空です。") }
        let keys = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard Set(keys).count == keys.count else { throw BridgeError.message("重複した列名があります。") }
        func col(_ names: [String]) -> Int? { names.compactMap { keys.firstIndex(of: $0) }.first }
        guard let p = col(["password"]), let u = col(["username"]), let w = col(["url", "website"]) else { throw BridgeError.message("Username・Password・URL（またはWebsite）列が必要です。") }
        let known: Set<String> = ["title", "url", "website", "username", "password", "otpauth", "otp", "notes", "type"]
        let unknown = keys.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw BridgeError.message("未対応の列があります（情報を落とさないため読み込みを停止）。Apple形式のCSVを使用してください。") }
        return try rows.dropFirst().enumerated().map { n, values in
            guard values.count == header.count else { throw BridgeError.message("CSVの\(n+2)行目の列数が不正です。") }
            func value(_ names: [String]) -> String { col(names).map { values[$0] } ?? "" }
            return Entry(title: value(["title"]), url: values[w], username: values[u], password: values[p], otp: value(["otpauth", "otp"]), notes: value(["notes"]))
        }
    }
}
public enum Verdict: String, Sendable, CaseIterable {
    case related = "関連候補・要確認"
    case new = "未検出・移行候補", identical = "保存内容一致", conflict = "競合・要確認", metadata = "追加情報に差分", duplicate = "Apple内重複", invalid = "手動対応"
}
public struct Comparison: Identifiable, Sendable {
    public var id: String { entry.id }
    public let entry: Entry
    public let verdict: Verdict
    public let reason: String
    public let matches: [Entry]
    public var sortTitle: String { entry.title }
    public var sortURL: String { entry.url }
    public var sortUsername: String { entry.username }
    public var sortVerdict: String { verdict.rawValue }
    public var sortReason: String { reason }
}
public func compare(_ source: [Entry], _ destination: [Entry]) -> [Comparison] {
    let grouped = Dictionary(grouping: destination, by: \.identity)
    let hosts = Dictionary(grouping: destination.filter { !$0.host.isEmpty }, by: \.host)
    let sourceGroups = Dictionary(grouping: source, by: \.identity)
    var seen = [String: [Entry]]()
    return source.map { e in
        let prior = seen[e.identity] ?? []; seen[e.identity, default: []].append(e)
        let targets = grouped[e.identity] ?? []
        let related = (hosts[e.host] ?? []).filter {
            !$0.username.isEmpty && !e.username.isEmpty && $0.username.caseInsensitiveCompare(e.username) == .orderedSame
        }
        let verdict: Verdict; let reason: String
        if e.password.isEmpty || URLComponents(string: e.url)?.host == nil {
            verdict = .invalid; reason = "パスワードまたは有効なURLがありません。"
        } else if prior.contains(where: { $0.sameContent(e) }) {
            verdict = .duplicate; reason = "Apple CSV内に同じURL・ID・内容があります。"
        } else if targets.isEmpty {
            if (sourceGroups[e.identity] ?? []).contains(where: { $0.id != e.id && !$0.sameContent(e) }) {
                verdict = .conflict; reason = "Apple内の同一URL・IDで内容が異なります。"
            } else if !related.isEmpty {
                verdict = .related; reason = "同じホストに、URLのパス・方式またはIDの大文字小文字が異なる項目があります。詳細を確認してください。"
            } else { verdict = .new; reason = "指定保管庫内で一致・関連候補を検出できませんでした。他の保管庫や別ドメインは未確認です。" }
        } else if targets.contains(where: { $0.password != e.password }) {
            verdict = .conflict; reason = "同一URL・IDに異なるパスワードがあります。新旧は未判定。"
        } else if targets.contains(where: { $0.sameContent(e) }) {
            verdict = .identical; reason = "パスワード・TOTP・メモが一致。ログインとパスキーは未確認。"
        } else {
            verdict = .metadata; reason = "パスワードは一致しますが、TOTPまたはメモが異なります。"
        }
        return Comparison(entry: e, verdict: verdict, reason: reason, matches: targets.isEmpty ? related : targets)
    }
}
