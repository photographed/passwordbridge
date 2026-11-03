import Foundation

/// Decode a JSON array, one object, or a whitespace-separated stream of objects.
/// Never accept a partial result or include the raw CLI output in an error.
public enum CLIJSON {
    public static func items(_ data: Data) throws -> [[String: Any]] {
        var bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        var index = 0, result = [[String: Any]](), documents = 0
        while index < bytes.count {
            while index < bytes.count && whitespace.contains(bytes[index]) { index += 1 }
            if index == bytes.count { break }
            let start = index
            guard bytes[index] == 123 || bytes[index] == 91 else { throw invalid() }
            var depth = 0, quoted = false, escaped = false
            repeat {
                let ch = bytes[index]
                if quoted {
                    if escaped { escaped = false }
                    else if ch == 92 { escaped = true }
                    else if ch == 34 { quoted = false }
                } else if ch == 34 { quoted = true }
                else if ch == 123 || ch == 91 { depth += 1 }
                else if ch == 125 || ch == 93 { depth -= 1 }
                index += 1
            } while index < bytes.count && (depth > 0 || quoted)
            guard depth == 0, !quoted else { throw invalid() }
            let decoded: Any
            do { decoded = try JSONSerialization.jsonObject(with: Data(bytes[start..<index])) }
            catch { throw invalid() }
            if let object = decoded as? [String: Any] { result.append(object) }
            else if let array = decoded as? [[String: Any]] { result.append(contentsOf: array) }
            else { throw invalid() }
            documents += 1
            // Separate JSON documents must have a whitespace boundary.
            if index < bytes.count && !whitespace.contains(bytes[index]) { throw invalid() }
        }
        guard documents > 0 else { throw invalid() }
        return result
    }
    private static func invalid() -> BridgeError {
        .message("1Passwordの応答形式を読み取れませんでした。空の応答・途中で切れたJSON・未対応形式の可能性があります。途中結果は採用していません。")
    }
}
