import Foundation
import Darwin

public enum ReadProgress: Sendable {
    case listing
    case fetching(completed: Int, total: Int)
}

// Only the subprocesses owned by this operation are interrupted.
public final class ReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var failure: (any Error)?
    private var commands: [UUID: CommandSession] = [:]
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let active = Array(commands.values); lock.unlock()
        for command in active { command.stop(timedOut: false) }
    }
    fileprivate func fail(_ error: any Error) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        failure = error; cancelled = true; let active = Array(commands.values); lock.unlock()
        for command in active { command.stop(timedOut: false) }
    }
    public func check() throws {
        lock.lock(); let stopped = cancelled, error = failure; lock.unlock()
        if let error { throw error }
        if stopped { throw CancellationError() }
    }
    fileprivate func attach(_ command: CommandSession, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        commands[id] = command
    }
    fileprivate func detach(_ id: UUID) { lock.lock(); commands.removeValue(forKey: id); lock.unlock() }
}
private final class CommandSession: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var stopped = false
    private var timedOut = false
    init(_ process: Process) { self.process = process }
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }
        try process.run()
    }
    func stop(timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true; self.timedOut = timedOut
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if timedOut { throw BridgeError.message("1Passwordの応答が制限時間内にありませんでした。認証・接続を確認し、再実行してください。") }
        if stopped { throw CancellationError() }
    }
}

public struct OPClient: Sendable {
    public let executable: String
    public let account: String
    public let vault: String
    public let commandTimeout: TimeInterval
    public init(executable: String, account: String, vault: String, commandTimeout: TimeInterval = 120) {
        self.executable = executable; self.account = account; self.vault = vault; self.commandTimeout = commandTimeout
    }
    private func run(_ args: [String], input: Data? = nil, control: ReadControl? = nil) throws -> Data {
        guard executable.hasPrefix("/"), !account.isEmpty, !vault.isEmpty else { throw BridgeError.message("CLIの絶対パス、アカウントID、保管庫IDを指定してください。") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args + ["--account", account, "--format", "json"]
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        p.standardOutput = output; p.standardError = errors; p.standardInput = stdin
        // Drain stderr concurrently, never expose CLI output in UI/logs.
        let errorDrain = DispatchQueue(label: "bridge.stderr")
        let session = CommandSession(p), id = UUID()
        try control?.attach(session, id: id)
        defer { control?.detach(id) }
        try session.start()
        let timeout = DispatchWorkItem { session.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timeout)
        defer { timeout.cancel() }
        errorDrain.async { _ = errors.fileHandleForReading.readDataToEndOfFile() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); errorDrain.sync {}
        try session.check()
        try control?.check()
        guard p.terminationStatus == 0 else { throw BridgeError.message("1Password操作に失敗しました。ロック解除・CLI連携・対象ID・権限を確認してください。自動再試行はしません。") }
        return data
    }
    private func object(_ data: Data) throws -> [String: Any] {
        let items = try CLIJSON.items(data)
        guard items.count == 1, let value = items.first else { throw BridgeError.message("1Passwordの単一項目の応答形式を読み取れません。") }; return value
    }
    private func entries(_ item: [String: Any]) -> [Entry] {
        let fields = item["fields"] as? [[String: Any]] ?? []
        func field(_ id: String) -> String { fields.first { ($0["id"] as? String) == id }?["value"] as? String ?? "" }
        let otp = fields.first { ($0["type"] as? String) == "OTP" }?["value"] as? String ?? ""
        let urls = (item["urls"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
        return (urls.isEmpty ? [""] : urls).map { url in
            Entry(id: (item["id"] as? String ?? UUID().uuidString) + url, title: item["title"] as? String ?? "", url: url, username: field("username"), password: field("password"), otp: otp, notes: field("notesPlain"))
        }
    }
    private func listIDs(control: ReadControl?) throws -> [String] {
        let data = try run(["item", "list", "--vault", vault], control: control)
        let items = try CLIJSON.items(data)
        let ids = try items.map { item in
            guard let id = item["id"] as? String, !id.isEmpty else { throw BridgeError.message("項目IDがありません。比較を中止しました。") }
            return id
        }
        guard Set(ids).count == ids.count else { throw BridgeError.message("一覧に重複IDがあります。再取得してください。") }
        return ids
    }
    private func fetch(_ ids: [String], control: ReadControl?) throws -> [Entry] {
        try control?.check()
        // Official CLI stdin input accepts an array of objects containing item IDs.
        let input = try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] })
        let data = try run(["item", "get", "-", "--vault", vault], input: input, control: control)
        let items = try CLIJSON.items(data)
        let returnedIDs = items.compactMap { $0["id"] as? String }
        guard returnedIDs.count == ids.count, Set(returnedIDs) == Set(ids) else {
            throw BridgeError.message("取得結果に欠落または重複があります。部分的な結果では比較しません。再取得してください。")
        }
        return items.flatMap { entries($0) }
    }
    public func read() throws -> [Entry] {
        let ids = try listIDs(control: nil)
        var result = [Entry]()
        for start in stride(from: 0, to: ids.count, by: 50) {
            result += try fetch(Array(ids[start..<min(start + 50, ids.count)]), control: nil)
        }
        return result
    }
    public func readFast(control: ReadControl, progress: @escaping @Sendable (ReadProgress) async -> Void) async throws -> [Entry] {
        try control.check(); await progress(.listing)
        let ids = try await Task.detached { try listIDs(control: control) }.value
        try control.check(); await progress(.fetching(completed: 0, total: ids.count))
        let batches = stride(from: 0, to: ids.count, by: 50).map { Array(ids[$0..<min($0 + 50, ids.count)]) }
        do {
            let result = try await withThrowingTaskGroup(of: (Int, [Entry], Int).self) { group in
                var next = 0, completed = 0
                var results = [Int: [Entry]]()
                func enqueue(_ index: Int) {
                    let batch = batches[index]
                    group.addTask {
                        do {
                            let entries = try await Task.detached { try fetch(batch, control: control) }.value
                            return (index, entries, batch.count)
                        } catch {
                            control.fail(error)
                            try control.check()
                            throw error
                        }
                    }
                }
                while next < min(3, batches.count) { enqueue(next); next += 1 }
                while let (index, entries, count) = try await group.next() {
                    try control.check()
                    results[index] = entries; completed += count
                    await progress(.fetching(completed: completed, total: ids.count))
                    if next < batches.count { enqueue(next); next += 1 }
                }
                return batches.indices.flatMap { results[$0] ?? [] }
            }
            try control.check(); return result
        } catch {
            control.cancel()
            throw error
        }
    }
    public func createAndVerify(_ e: Entry) throws -> String {
        let existing = try read()
        guard compare([e], existing).first?.verdict == .new else { throw BridgeError.message("対象保管庫が変化したか、既存項目があります。再比較してください。") }
        var fields: [[String: String]] = [
            ["id": "username", "type": "STRING", "purpose": "USERNAME", "value": e.username],
            ["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "value": e.password],
            ["id": "notesPlain", "type": "STRING", "value": e.notes]
        ]
        if !e.otp.isEmpty { fields.append(["id": "TOTP", "label": "one-time password", "type": "OTP", "value": e.otp]) }
        let payload: [String: Any] = ["title": e.title.isEmpty ? e.url : e.title, "category": "LOGIN", "fields": fields, "urls": [["href": e.url, "primary": true]], "tags": ["PasswordBridge"]]
        let created = try object(run(["item", "create", "-", "--vault", vault], input: JSONSerialization.data(withJSONObject: payload)))
        guard let id = created["id"] as? String else { throw BridgeError.message("登録応答が不明です。再実行前に1Passwordを確認してください。") }
        do {
            let saved = entries(try object(run(["item", "get", id, "--vault", vault])))
            guard saved.contains(where: { $0.identity == e.identity && $0.sameContent(e) }) else { throw BridgeError.message("登録内容が一致しません。") }
        } catch { throw BridgeError.message("登録後の検証に失敗しました。1Passwordで対象を確認し、再比較してください。Apple側を削除しないでください。") }
        return id
    }
}
