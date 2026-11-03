import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BridgeCore

@MainActor final class Model: ObservableObject {
    @Published var apple: [Entry] = [] { didSet { refreshComparison() } }
    @Published var target: [Entry] = [] { didSet { refreshComparison() } }
    @Published var selection = Set<String>()
    @Published var status = "サンプル、またはAppleのCSVから開始してください。"
    @Published var busy = false
    @Published var live = false
    @Published var demo = false
    @Published var loaded = false
    @Published var account = ""
    @Published var vault = ""
    @Published var executable = "/opt/homebrew/bin/op"
    @Published var search = "" { didSet { page = 0 } }
    @Published var filter: Verdict? = nil { didSet { page = 0 } }
    @Published var page = 0
    @Published var sortOrder: [KeyPathComparator<Comparison>] = [KeyPathComparator(\Comparison.sortTitle, comparator: .localizedStandard)] { didSet { page = 0 } }
    @Published var verified = Set<String>()
    @Published private(set) var results: [Comparison] = []
    private func refreshComparison() { results = compare(apple, target); page = 0 }
    var filtered: [Comparison] {
        results.filter { r in
            (filter == nil || r.verdict == filter) && (search.isEmpty || r.entry.title.localizedCaseInsensitiveContains(search) || r.entry.url.localizedCaseInsensitiveContains(search) || r.entry.username.localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }
    var pageCount: Int { max(1, (filtered.count + 49) / 50) }
    var visible: [Comparison] { Array(filtered.dropFirst(min(page, pageCount - 1) * 50).prefix(50)) }
    var selected: [Entry] { results.filter { selection.contains($0.id) && $0.verdict == .new }.map(\.entry) }
    var client: OPClient { OPClient(executable: executable, account: account, vault: vault) }
    func resetConnection() { live = false; loaded = false; target = []; selection = []; verified = [] }
    func loadCSV(appleSide: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "CSVを読み込み中…"
        Task {
            do {
                let values = try await Task.detached {
                    try CSV.entries(String(contentsOf: url, encoding: .utf8))
                }.value
                if appleSide { apple = values; demo = false; verified = [] }
                else { target = values; live = false; loaded = true }
                selection = []; status = "\(values.count)件を読み込みました。CSVは元の場所に残っています。"
            } catch { status = error.localizedDescription }
            busy = false
        }
    }

    func sample() {
        apple = [Entry(title: "一致するアカウント", url: "https://example.com", username: "sample@example.com", password: "demo-A"), Entry(title: "新規アカウント", url: "https://new.example.com", username: "sample", password: "demo-B"), Entry(title: "パスワード競合", url: "https://conflict.example.com", username: "sample", password: "demo-old")]
        target = [apple[0], Entry(title: "比較先", url: "https://conflict.example.com", username: "sample", password: "demo-new")]
        demo = true; live = false; loaded = true; selection = []; verified = []; status = "サンプル表示中。実際の移行は無効です。"
    }
    @Published var readCompleted = 0
    @Published var readTotal: Int? = nil
    @Published var readStarted: Date? = nil
    @Published var fetchStarted: Date? = nil
    private var readControl: ReadControl?
    var reading: Bool { readControl != nil }
    func cancelRead() {
        readControl?.cancel()
        status = "読み取りを中断しています…"
    }
    func readTimeText(now: Date) -> String {
        guard let started = readStarted else { return "" }
        let elapsed = max(0, Int(now.timeIntervalSince(started)))
        guard let fetchStarted, readCompleted > 0, let total = readTotal, readCompleted < total else {
            return "経過 \(elapsed)秒 / 残り時間を計測中"
        }
        let remaining = max(1, Int(now.timeIntervalSince(fetchStarted) / Double(readCompleted) * Double(total - readCompleted)))
        return "経過 \(elapsed)秒 / 残り目安 約\(remaining)秒（認証・通信で変動）"
    }
    func connect() {
        guard !busy else { return }
        let c = client, control = ReadControl()
        readControl = control; readStarted = Date(); fetchStarted = nil; readCompleted = 0; readTotal = nil
        busy = true; live = false; loaded = false; target = []; selection = []; verified = []
        status = "保管庫の一覧を取得中。認証画面が出ている場合は確認してください。"
        Task {
            do {
                let items = try await c.readFast(control: control) { event in
                    await MainActor.run { [weak self] in
                        guard let self, self.readControl === control else { return }
                        switch event {
                        case .listing:
                            self.status = "一覧取得・認証の応答待ち…"
                        case .fetching(let completed, let total):
                            if self.fetchStarted == nil { self.fetchStarted = Date() }
                            self.readCompleted = completed; self.readTotal = total
                            self.status = "項目を取得中：\(completed) / \(total)件"
                        }
                    }
                }
                try control.check()
                target = items; live = true; loaded = true
                let elapsed = Int(Date().timeIntervalSince(readStarted ?? Date()))
                status = "読み取り・再比較が完了しました（\(readTotal ?? 0)項目・\(elapsed)秒）。他の保管庫は比較対象外です。"
            } catch is CancellationError {
                status = "読み取りを中断しました。部分的な結果は破棄しました。再実行できます。"
            } catch { status = error.localizedDescription }
            readControl = nil; busy = false
        }
    }
    func migrate() {
        let items = selected; guard live && !demo && !items.isEmpty else { return }
        let c = client; busy = true; selection = []
        Task {
            var count = 0
            for e in items {
                status = "\(count + 1)/\(items.count)件目を登録・照合中…"
                do {
                    _ = try await Task.detached { try c.createAndVerify(e) }.value
                    verified.insert(e.id); target.append(e); count += 1
                } catch { status = "\(count)件の照合完了後に停止。" + error.localizedDescription; busy = false; return }
            }
            status = "\(count)件を登録し、読み直して照合しました。ログイン・パスキーは別途確認してください。"; busy = false
        }
    }
    func exportChecklist() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Apple整理チェックリスト.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = results.filter { $0.verdict == .identical }.map { r in
            "□ \(r.entry.title.replacingOccurrences(of: "\n", with: " "))\n  \(r.entry.url)\n  ID: \(r.entry.username)\n  保存内容一致 / ログイン未確認 / パスキー・共有・付随情報未確認\n"
        }
        do { try ("Apple側の削除は、1Passwordでのログインと、未移行のパスキー・共有・付随情報がないことを確認してから行ってください。iCloud同期先にも影響します。\nこの一覧にはサイト名とユーザー名が含まれます。秘密そのものは含みません。\n\n" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8); status = "チェックリストを保存しました。" } catch { status = "保存できませんでした。" }
    }
}
@main struct PasswordBridgeApp: App {
    @StateObject private var model = Model()
    var body: some Scene { WindowGroup { MainView(m: model).frame(minWidth: 1060, minHeight: 700) } }
}
struct MainView: View {
    @ObservedObject var m: Model
    @State private var confirming = false
    @State private var detail: Comparison?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "key.horizontal.fill").font(.largeTitle).foregroundStyle(.teal)
                VStack(alignment: .leading) { Text("Password Bridge").font(.largeTitle.bold()); Text("Appleから1Passwordへ、確認しながら移行").foregroundStyle(.secondary) }
                Spacer()
                Button("サンプルを見る") { m.sample() }.disabled(m.busy)
            }
            HStack {
                Button("① Apple CSVを開く") { m.loadCSV(appleSide: true) }.disabled(m.busy)
                Button("比較用CSVを開く") { m.loadCSV(appleSide: false) }.disabled(m.busy)
                Spacer()
                Text("秘密はメモリ内で比較 / Apple側の自動削除なし").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("② 1Passwordへ接続（指定した1保管庫のみ比較）") {
                HStack {
                    TextField("opの絶対パス", text: $m.executable)
                    TextField("アカウントID", text: $m.account)
                    TextField("保管庫ID", text: $m.vault)
                    Button("読み取り・再比較") { m.connect() }.disabled(m.account.isEmpty || m.vault.isEmpty)
                }.padding(6)
            }.disabled(m.busy)
            HStack {
                stat("Apple", m.apple.count)
                ForEach(Verdict.allCases, id: \.self) { v in stat(v.rawValue, m.results.filter { $0.verdict == v }.count) }
            }
            if !m.loaded { Text("比較先が未読込です。判定は暫定表示です。1Passwordまたは比較用CSVを読み込んでください。").foregroundStyle(.orange) }
            TextField("サイト・タイトル・IDで絞り込み", text: $m.search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("判定", selection: $m.filter) {
                    Text("すべて").tag(Optional<Verdict>.none)
                    ForEach(Verdict.allCases, id: \.self) { v in Text(v.rawValue).tag(Optional(v)) }
                }.frame(width: 270)
                Text("\(m.filtered.count)件 / 選択中 \(m.selected.count)件").font(.callout)
                Text("列見出しで昇順・降順").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("前へ") { m.page -= 1 }.disabled(m.page == 0)
                Text("\(m.page + 1) / \(m.pageCount)ページ（50件ずつ）").font(.caption)
                Button("次へ") { m.page += 1 }.disabled(m.page + 1 >= m.pageCount)
            }
            Table(m.visible, sortOrder: $m.sortOrder) {
                TableColumn("選択") { r in
                    if r.verdict == .new && m.live && !m.demo {
                        Button {
                            if m.selection.contains(r.id) { m.selection.remove(r.id) } else { m.selection.insert(r.id) }
                        } label: {
                            Image(systemName: m.selection.contains(r.id) ? "checkmark.square.fill" : "square").font(.title3).frame(width: 32, height: 30)
                        }.buttonStyle(.borderless).disabled(m.busy).accessibilityLabel("移行対象に選択")
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(46)
                TableColumn("確認") { r in Button("詳細") { detail = r }.buttonStyle(.borderless) }.width(48)
                TableColumn("タイトル", value: \.sortTitle) { r in Text(r.entry.title.isEmpty ? "名称なし" : r.entry.title) }.width(min: 110)
                TableColumn("URL", value: \.sortURL) { r in Text(r.entry.url) }.width(min: 130)
                TableColumn("ユーザー名", value: \.sortUsername) { r in Text(r.entry.username) }.width(min: 120)
                TableColumn("判定", value: \.sortVerdict) { r in Text(m.verified.contains(r.id) ? "登録・再照合済み" : r.verdict.rawValue).foregroundStyle(color(r.verdict)) }.width(130)
                TableColumn("理由", value: \.sortReason) { r in Text(r.reason).font(.caption).foregroundStyle(.secondary) }.width(min: 200)
            }
            HStack {
                Button("このページの移行候補を選択") { m.selection.formUnion(m.visible.filter { $0.verdict == .new }.map(\.id)) }.disabled(!m.live || m.demo)
                Button("③ 選択した\(m.selected.count)件を移行") { confirming = true }.buttonStyle(.borderedProminent).disabled(m.selected.isEmpty || !m.live || m.demo)
                Button("選択を解除") { m.selection = [] }
                Spacer()
                Button("④ 整理チェックリストを保存") { m.exportChecklist() }.disabled(!m.loaded || m.demo)
                Button("データを閉じる") { m.apple = []; m.resetConnection(); m.demo = false; m.status = "データを閉じました。元CSVは削除していません。" }
            }
            .disabled(m.busy)
            if m.reading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let total = m.readTotal, total > 0 {
                            ProgressView(value: Double(m.readCompleted), total: Double(total))
                            Text("\(m.readCompleted) / \(total)件").monospacedDigit()
                        } else { ProgressView().controlSize(.small) }
                        Button("読み取りを中断") { m.cancelRead() }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(m.readTimeText(now: context.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(m.status).font(.callout).textSelection(.enabled)
            Text("CSVに含まれないパスキー・Wi-Fi・共有状態・履歴は検証できません。保存内容一致だけでは削除せず、ログインと付随情報を確認してください。CSVは平文です。作業後に元ファイルの保管・削除を確認してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .sheet(item: $detail) { r in
            DetailView(comparison: r)
        }
        .onChange(of: m.account) { m.resetConnection() }
        .onChange(of: m.vault) { m.resetConnection() }
        .onChange(of: m.executable) { m.resetConnection() }
        .confirmationDialog("指定した保管庫に\(m.selected.count)件を新規作成します", isPresented: $confirming) {
            Button("移行を実行") { m.migrate() }
        } message: { Text("アカウント: \(m.account)\n保管庫: \(m.vault)\n各項目を登録直前に再比較します。既存項目の更新・削除は行いません。") }
    }
    func stat(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading) { Text("\(count)").font(.title2.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    func color(_ v: Verdict) -> Color { switch v { case .new: .blue; case .identical: .teal; case .conflict, .invalid: .orange; default: .secondary } }
}

struct DetailView: View {
    let comparison: Comparison
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("1件ずつ確認").font(.title2.bold()); Spacer(); Button("閉じる") { dismiss() } }
            Text(comparison.verdict.rawValue).font(.headline)
            Text(comparison.reason).foregroundStyle(.secondary)
            GroupBox("Apple側") { info(comparison.entry).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            Text("1Password側の候補：\(comparison.matches.count)件").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if comparison.matches.isEmpty { Text("指定保管庫では候補が見つかっていません。別の保管庫・別ドメインは未確認です。") }
                    ForEach(Array(comparison.matches.enumerated()), id: \.offset) { _, candidate in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                info(candidate)
                                Text("パスワード：" + (candidate.password == comparison.entry.password ? "一致" : "異なる"))
                                Text("TOTP設定：" + (candidate.otp == comparison.entry.otp ? "一致（両方空の場合を含む）" : "異なる"))
                                Text("メモ：" + (candidate.notes == comparison.entry.notes ? "一致" : "異なる"))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }
            }
            Text("関連候補は自動統合・新規登録の対象外です。ユーザー名の大文字小文字やURLのパスが異なる場合、同じアカウントかを確認してください。秘密そのものは表示しません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 720, height: 620)
    }
    func info(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e.title.isEmpty ? "名称なし" : e.title).font(.headline)
            Text("URL：\(e.url)")
            Text("ユーザー名：\(e.username)")
        }.textSelection(.enabled)
    }
}
