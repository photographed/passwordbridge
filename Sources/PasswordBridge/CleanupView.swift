import SwiftUI
import BridgeCore

@MainActor final class CleanupModel: ObservableObject {
    @Published var executable = "/opt/homebrew/bin/op"
    @Published var account = ""
    @Published var vaults = ""
    @Published var rows: [CleanupRow] = []
    @Published var records: [String: CleanupRecord] = [:]
    @Published var demoRecords: [String: CleanupRecord] = [:]
    @Published var busy = false
    @Published var demo = false
    @Published var status = "まずダミーデータで操作を確認できます。"
    @Published var search = ""
    @Published var filter = "すべて"
    @Published var prioritize = true
    @Published var selectedID: String?
    @Published var changes: [String: String] = [:]
    private var control: ReadControl?
    private var storeReady = false
    private let store = CleanupStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PasswordBridge/cleanup-records.json"))
    init() {
        do { records = try store.load(); storeReady = true }
        catch { status = error.localizedDescription }
    }
    var vaultIDs: [String] { Array(Set(vaults.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).filter { !$0.isEmpty })).sorted() }
    func record(_ row: CleanupRow) -> CleanupRecord {
        if let value = (demo ? demoRecords : records)[row.id] { return value }
        var value = CleanupRecord(); value.category = row.suggestedCategory; return value
    }
    func update(_ row: CleanupRow, status: CleanupStatus? = nil, category: AccountCategory? = nil) {
        var value = record(row)
        value.update(status: status ?? value.status, category: category ?? value.category)
        if demo { demoRecords[row.id] = value; return }
        guard storeReady else { self.status = "保存ファイルに問題があります。上書きを避けるため記録は変更しません。"; return }
        var next = records; next[row.id] = value
        do { try store.save(next); records = next; self.status = "対応状況をMac内に保存しました。1Passwordは変更していません。" }
        catch { self.status = error.localizedDescription }
    }
    func priority(_ row: CleanupRow) -> Int {
        let r = record(row)
        if r.status == .completed || r.status == .closed { return -1 }
        return (r.status == .important || r.category != .other ? 100 : 0) + (row.reuseCount > 1 ? 20 : 0) + (row.strength == .weak ? 10 : 0)
    }
    var visible: [CleanupRow] {
        rows.filter { r in
            let matches = search.isEmpty || r.title.localizedCaseInsensitiveContains(search) || r.username.localizedCaseInsensitiveContains(search) || r.hosts.contains { $0.localizedCaseInsensitiveContains(search) }
            let state = record(r)
            let category: Bool
            switch filter {
            case "再利用": category = r.reuseCount > 1
            case "重複候補": category = !r.duplicateIDs.isEmpty || !r.caseVariantIDs.isEmpty
            case "弱い可能性": category = r.strength == .weak
            case "重要": category = state.status == .important || state.category != .other
            case "未完了": category = state.status != .completed
            case "対応完了": category = state.status == .completed
            default: category = true
            }
            return matches && category
        }.sorted {
            if prioritize && priority($0) != priority($1) { return priority($0) > priority($1) }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    var selected: CleanupRow? { rows.first { $0.id == selectedID } }
    var groupCount: Int { Set(rows.compactMap(\.reuseGroup)).count }
    func sample() {
        guard !busy else { return }
        demo = true; demoRecords = [:]; changes = [:]; selectedID = nil
        rows = CleanupAnalyzer.analyze([
            CleanupLogin(accountID: "demo", vaultID: "personal", itemID: "mail", title: "メール（重要）", username: "sample", urls: ["https://accounts.google.com/login"], password: "demo-reused"),
            CleanupLogin(accountID: "demo", vaultID: "shared", itemID: "shop", title: "ショップ", username: "sample", urls: ["https://shop.example.com"], password: "demo-reused"),
            CleanupLogin(accountID: "demo", vaultID: "personal", itemID: "shop-copy", title: "ショップの重複候補", username: "sample", urls: ["http://shop.example.com/login"], password: "demo-reused"),
            CleanupLogin(accountID: "demo", vaultID: "personal", itemID: "cloud", title: "クラウド管理", username: "admin", urls: ["https://console.aws.amazon.com"], password: "123456"),
            CleanupLogin(accountID: "demo", vaultID: "shared", itemID: "unique", title: "固有のパスワード", username: "sample", urls: ["https://unique.example.com"], password: "Unique-Dummy-Passphrase-472!")
        ])
        status = "ダミーデータです。対応記録もメモリ内だけに保持し、実データの記録には保存しません。"
    }
    func read() {
        guard !busy, !account.isEmpty, !vaultIDs.isEmpty else { return }
        let ids = vaultIDs, accountID = account, path = executable
        let op = ReadControl(); control = op; busy = true
        let previous = demo ? [:] : Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.riskSummary) })
        rows = []; selectedID = nil; changes = [:]; demo = false
        status = "読み取りを開始します。認証画面を確認してください。"
        Task {
            do {
                // Raw secrets never reach @Published properties or the persistence layer.
                let analyzed = try await Task.detached {
                    var secrets = [CleanupLogin]()
                    for (index, vault) in ids.enumerated() {
                        try op.check()
                        let client = OPClient(executable: path, account: accountID, vault: vault)
                        let items = try await client.readCleanupLogins(control: op) { event in
                            await MainActor.run { [weak self] in
                                guard let self, self.control === op else { return }
                                switch event {
                                case .listing: self.status = "保管庫 \(index + 1)/\(ids.count)：ログイン一覧取得・認証待ち"
                                case .fetching(let done, let total): self.status = "保管庫 \(index + 1)/\(ids.count)：\(done)/\(total)ログイン取得"
                                }
                            }
                        }
                        secrets += items
                    }
                    try op.check()
                    let result = CleanupAnalyzer.analyze(secrets)
                    secrets.removeAll(keepingCapacity: false)
                    try op.check(); return result
                }.value
                try op.check()
                rows = analyzed
                for row in rows {
                    if let before = previous[row.id] { changes[row.id] = before == row.riskSummary ? "前回と再利用件数・簡易強度は同じ" : "前回：\(before) → 今回：\(row.riskSummary)" }
                    else { changes[row.id] = "今回初めて分析した項目" }
                }
                status = "\(ids.count)保管庫・\(rows.count)ログインを分析しました。秘密情報は表示モデル・対応記録に保持していません。"
            } catch is CancellationError { status = "中断しました。部分的な結果は破棄しました。対応記録は保持しています。" }
            catch { status = "取得・分析に失敗しました。部分結果は破棄しました。" + error.localizedDescription }
            control = nil; busy = false
        }
    }
    func clear() { guard !busy else { return }; rows = []; changes = [:]; selectedID = nil; demoRecords = [:]; status = "分析結果を閉じました。対応記録は保持しています。" }
    func cancel() { control?.cancel(); status = "中断中…" }
}

struct CleanupView: View {
    @StateObject private var m = CleanupModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) { Text("Security Cleanup").font(.largeTitle.bold()); Text("重要なアカウントから整理 / 1Passwordは読み取り専用").foregroundStyle(.secondary) }
                Spacer()
                Button("ダミーデータ") { m.sample() }.disabled(m.busy)
                Button("結果を閉じる") { m.clear() }.disabled(m.busy)
            }
            GroupBox("対象：1アカウント内の複数保管庫（IDをカンマ・空白・改行で区切る）") {
                HStack {
                    TextField("CLIの絶対パス", text: $m.executable)
                    TextField("アカウントID", text: $m.account)
                    TextField("保管庫ID, 保管庫ID…", text: $m.vaults)
                    Button("読み取り・再比較") { m.read() }.disabled(m.account.isEmpty || m.vaultIDs.isEmpty)
                }.padding(6).disabled(m.busy)
            }
            Text("漏洩判定：未対応（公式CLIに取得機能を確認できません）。1Password Watchtowerで確認してください。簡易強度はWatchtowerの判定とは異なります。")
                .font(.caption).foregroundStyle(.orange)
            HStack {
                Text("\(m.rows.count)ログイン / 再利用 \(m.groupCount)グループ / 弱い可能性 \(m.rows.filter { $0.strength == .weak }.count)件").font(.headline)
                Spacer()
                Toggle("重要アカウントを優先", isOn: $m.prioritize)
            }
            HStack {
                TextField("タイトル・ホスト・ユーザー名で検索", text: $m.search).textFieldStyle(.roundedBorder)
                Picker("表示", selection: $m.filter) {
                    ForEach(["すべて", "再利用", "重複候補", "弱い可能性", "重要", "未完了", "対応完了"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
            }
            HSplitView {
                List(selection: $m.selectedID) {
                    ForEach(m.visible) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.title.isEmpty ? "名称なし" : row.title).font(.headline); Spacer(); Text(m.record(row).status.rawValue).font(.caption) }
                            Text(row.hosts.joined(separator: ", ") + " / " + row.username).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if let group = row.reuseGroup { Text("再利用グループ\(group)：\(row.reuseCount)項目").foregroundStyle(.orange) }
                                if !row.duplicateIDs.isEmpty { Text("重複候補\(row.duplicateIDs.count)件") }
                                Text(row.strength.rawValue)
                            }.font(.caption)
                        }.padding(.vertical, 5).tag(row.id)
                    }
                }.frame(minWidth: 440)
                ScrollView {
                    if let row = m.selected {
                        details(row).padding(16)
                    } else { Text("左の項目を選ぶと、グループと対応状況を確認できます。").foregroundStyle(.secondary).padding(24) }
                }.frame(minWidth: 370, idealWidth: 450)
            }
            HStack { if m.busy { ProgressView().controlSize(.small); Button("読み取りを中断") { m.cancel() } }; Text(m.status).font(.caption).textSelection(.enabled) }
            Text("記録はMac内のアイテムID・状態・分類・日時だけ。パスワード変更は各サービスと1Passwordで手動で行い、その後に再比較してください。完了記録は安全性の証明ではありません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .onChange(of: m.account) { m.clear() }
        .onChange(of: m.vaults) { m.clear() }
        .onChange(of: m.executable) { m.clear() }
    }
    @ViewBuilder func details(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title.isEmpty ? "名称なし" : row.title).font(.title2.bold())
            Text("保管庫ID：\(row.vaultID)").font(.caption).textSelection(.enabled)
            Text("ユーザー名：\(row.username)").textSelection(.enabled)
            Text(row.hosts.joined(separator: ", ")).textSelection(.enabled)
            Text("分類はホストからの提案です。用途に合わせて修正してください。").font(.caption).foregroundStyle(.secondary)
            Picker("分類", selection: Binding(get: { m.record(row).category }, set: { m.update(row, category: $0) })) {
                ForEach(AccountCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("対応状況", selection: Binding(get: { m.record(row).status }, set: { m.update(row, status: $0) })) {
                ForEach(CleanupStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if let date = m.record(row).reviewedAt { Text("記録日時：\(date.formatted())").font(.caption) }
            Divider()
            Text(row.riskSummary).font(.headline)
            Text(row.reuseDescription)
            Text("重複候補は同一ホスト・同じIDを基に判定。URLのパス違いは候補に含めます。別サブドメインは別ホストです。").font(.caption).foregroundStyle(.secondary)
            if !row.caseVariantIDs.isEmpty { Text("IDの大文字小文字が異なる候補：\(row.caseVariantIDs.count)件（同一アカウントとは断定しません）") }
            ForEach(m.rows.filter { candidate in candidate.id != row.id && ((row.reuseGroup != nil && candidate.reuseGroup == row.reuseGroup) || row.duplicateIDs.contains(candidate.id) || row.caseVariantIDs.contains(candidate.id)) }) { candidate in
                Button { m.selectedID = candidate.id } label: {
                    VStack(alignment: .leading) {
                        Text(candidate.title.isEmpty ? "名称なし" : candidate.title)
                        Text(candidate.hosts.joined(separator: ", ") + " / " + candidate.username).font(.caption)
                        if row.duplicateIDs.contains(candidate.id) { Text("同一ホスト・IDの重複候補").font(.caption) }
                        else if row.caseVariantIDs.contains(candidate.id) { Text("IDの大文字小文字が異なる候補").font(.caption) }
                        else { Text("同じパスワードの別アカウント").font(.caption) }
                    }
                }.buttonStyle(.bordered)
            }
            Divider()
            Text(m.changes[row.id] ?? "ダミー分析").font(.caption)
            Text("簡易強度：短い・文字の偏り・一部の典型語を検出します。警告なしでも安全とは断定できません。パスワードそのものの変更検知は行いません。")
                .font(.caption).foregroundStyle(.secondary)
            if m.record(row).status == .completed && (row.reuseCount > 1 || row.strength == .weak) { Text("対応完了の記録がありますが、現在もリスク候補が残っています。再確認してください。").foregroundStyle(.orange) }
            ForEach(Array(m.record(row).history.reversed().enumerated()), id: \.offset) { _, event in
                Text("\(event.date.formatted())：\(event.status.rawValue) / \(event.category.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(m.busy)
    }
}
