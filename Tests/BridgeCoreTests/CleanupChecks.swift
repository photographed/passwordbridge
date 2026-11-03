import Foundation
import BridgeCore

enum CleanupChecks {
    static func login(_ id: String, password: String = "synthetic-only", host: String = "shop.example.com", user: String = "User", vault: String = "a") -> CleanupLogin {
        CleanupLogin(accountID: "account", vaultID: vault, itemID: id, title: "Dummy", username: user, urls: ["https://\(host)/login"], password: password)
    }
    static func run() async throws {
        let items = [login("one"), login("copy", vault: "b"), login("different", host: "mail.example.com"), login("unique", password: "A-Long-Unique-Dummy-974!", host: "unique.example.com")]
        let rows = CleanupAnalyzer.analyze(items)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].reuseCount, 3)
        XCTAssertEqual(rows[0].duplicateIDs, [rows[1].id])
        XCTAssertEqual(rows[2].duplicateIDs.count, 0)
        XCTAssertEqual(rows[0].reuseDescription.contains("別ホスト"), true)
        XCTAssertEqual(rows[3].reuseGroup, nil)
        XCTAssertEqual(CleanupAnalyzer.analyze([items[0], items[0]]).count, 1)
        let duplicateOnly = CleanupAnalyzer.analyze([items[0], items[1]])
        XCTAssertEqual(duplicateOnly[0].reuseDescription, "同一アカウントの重複候補のみ")
        let sameService = CleanupAnalyzer.analyze([login("a"), login("b", user: "Another")])
        XCTAssertEqual(sameService[0].reuseDescription, "同一ホスト内の別IDで再利用")
        let variants = CleanupAnalyzer.analyze([login("a"), login("b", user: "user")])
        XCTAssertEqual(variants[0].duplicateIDs.count, 0)
        XCTAssertEqual(variants[0].caseVariantIDs.count, 1)
        let unicode = CleanupAnalyzer.analyze([login("a", password: "\u{e9}"), login("b", password: "e\u{301}")])
        XCTAssertEqual(unicode[0].reuseCount, 1) // Secrets compare bytes, not canonical Unicode equivalence.
        let empty = CleanupAnalyzer.analyze([login("a", password: ""), login("b", password: "")])
        XCTAssertEqual(empty[0].reuseGroup, nil)
        XCTAssertEqual(empty[0].strength, .missing)
        XCTAssertEqual(LocalStrength.evaluate("password123456"), .weak)
        XCTAssertEqual(LocalStrength.evaluate("Unique-Long-Dummy-Pass-973!"), .noSimpleWarning)
        XCTAssertEqual(AccountCategory.suggest(hosts: ["accounts.google.com"]), .email)
        XCTAssertEqual(AccountCategory.suggest(hosts: ["fakeaccounts.google.com.evil.example"]), .other)
        XCTAssertEqual(AccountCategory.suggest(hosts: ["console.aws.amazon.com"]), .cloud)
        let changed = CleanupAnalyzer.analyze([login("one", password: "Now-Unique-Dummy-482!"), items[1], items[2]])
        XCTAssertEqual(changed[0].id, rows[0].id)
        XCTAssertEqual(changed[0].reuseCount, 1)
        XCTAssertEqual(changed[1].reuseCount, 2)
        try testPersistence()
        try await testReadOnlyCLI()
        print("Cleanup: reuse/duplicates/byte equality/strength/categories/store/read-only CLI passed")
    }
    static func testPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CleanupStore(url: dir.appendingPathComponent("records.json"))
        var record = CleanupRecord(); record.update(status: .important, category: .email)
        record.update(status: .completed, category: .email)
        try store.save(["account:vault:item": record])
        let loaded = try store.load()
        XCTAssertEqual(loaded["account:vault:item"]?.status, .completed)
        XCTAssertEqual(loaded["account:vault:item"]?.history.count, 2)
        let encoded = try String(contentsOf: store.url, encoding: .utf8)
        for forbidden in ["password", "username", "urls", "otp", "synthetic-only", "recovery"] {
            precondition(!encoded.contains(forbidden), "Secret or account content entered record store")
        }
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "broken")
    }
    static func testReadOnlyCLI() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-op")
        let text = #"""
        #!/usr/bin/python3
        import sys, json, os
        root = os.path.dirname(__file__)
        assert os.environ.get('OP_DEBUG') == 'false'
        assert os.environ.get('OP_CACHE') == 'false'
        args = sys.argv[1:]
        assert args[0] == 'item' and args[1] in ['list','get']
        with open(os.path.join(root,'calls'),'a') as f: f.write(args[1] + '\n')
        vault = args[args.index('--vault')+1]
        if args[1] == 'list':
            assert args[args.index('--categories')+1] == 'Login'
            if vault == 'fail': sys.exit(1)
            print(json.dumps([{'id': 'a'},{'id': 'b'}]))
        else:
            for e in json.load(sys.stdin):
                print(json.dumps({'id':e['id'], 'category':'LOGIN' if vault != 'wrong-category' else 'SECURE_NOTE','title':'Dummy','fields':[{'id':'password','value':'synthetic-only'},{'id':'username','value':'demo'},{'type':'OTP','value':'dummy-otp-must-not-retain'}],'urls':[{'href':'https://shop.example.com/?token=dummy-query-must-not-retain'}]}))
        """#
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var logins = [CleanupLogin]()
        for vault in ["first", "second"] {
            let client = OPClient(executable: script.path, account: "account", vault: vault)
            logins += try await client.readCleanupLogins(control: ReadControl()) { _ in }
        }
        let summary = CleanupAnalyzer.analyze(logins)
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(Set(summary.map(\.id)).count, 4)
        XCTAssertEqual(summary[0].reuseCount, 4)
        XCTAssertEqual(summary[0].hosts, ["shop.example.com"])
        let description = String(describing: summary)
        precondition(!description.contains("synthetic-only") && !description.contains("dummy-otp") && !description.contains("dummy-query"))
        for vault in ["fail", "wrong-category"] {
            do {
                _ = try await OPClient(executable: script.path, account: "account", vault: vault).readCleanupLogins(control: ReadControl()) { _ in }
                preconditionFailure("Failed cleanup read accepted")
            } catch {}
        }
        let control = ReadControl(); control.cancel()
        do { _ = try await OPClient(executable: script.path, account: "account", vault: "first").readCleanupLogins(control: control) { _ in }; preconditionFailure("Cancelled read accepted") }
        catch is CancellationError {}
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        precondition(calls.allSatisfy { $0 == "list" || $0 == "get" })
    }
}
