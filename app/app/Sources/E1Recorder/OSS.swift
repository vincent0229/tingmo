import CryptoKit
import Foundation

/// Minimal Aliyun OSS client (signature V1) for the WiFi mailbox: list, get, download, delete, put.
struct OSSClient {
    let endpoint: String     // e.g. oss-cn-beijing.aliyuncs.com
    let bucket: String
    let keyId: String
    let secret: String

    /// Never cached: the heartbeat keeps the same URL, and macOS would otherwise hand back a copy that is hours
    /// old (an object unchanged overnight counts as "fresh" for a while). Short idle timeout so a stalled proxy
    /// or network can't hold up the next check for minutes.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 24 * 3600   // a multi-hour recording on a slow line must still finish
        return URLSession(configuration: c)
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private func request(_ method: String, key: String, query: String = "", contentType: String = "") -> URLRequest {
        let date = Self.dateFormatter.string(from: Date())
        let toSign = "\(method)\n\n\(contentType)\n\(date)\n/\(bucket)/\(key)"
        let sig = HMAC<Insecure.SHA1>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        var r = URLRequest(url: URL(string: "https://\(bucket).\(endpoint)/\(encodedKey)\(query)")!, timeoutInterval: 30)
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        r.httpMethod = method
        r.setValue(date, forHTTPHeaderField: "Date")
        r.setValue("OSS \(keyId):\(Data(sig).base64EncodedString())", forHTTPHeaderField: "Authorization")
        if !contentType.isEmpty { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse, ok: Set<Int> = [200]) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard ok.contains(code) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            let c = body.range(of: "<Code>(.*?)</Code>", options: .regularExpression).map { String(body[$0]).replacingOccurrences(of: "<Code>", with: "").replacingOccurrences(of: "</Code>", with: "") } ?? "HTTP \(code)"
            switch c {
            case "InvalidAccessKeyId", "SignatureDoesNotMatch": throw AppError("钥匙不对（\(c)）")
            case "AccessDenied": throw AppError("钥匙没有这个权限（AccessDenied）")
            case "NoSuchBucket": throw AppError("找不到存储空间「\(bucket)」")
            default: throw AppError("OSS 出错（\(c)）")
            }
        }
    }

    /// All object keys under a prefix (follows pagination).
    func list(prefix: String) async throws -> [String] {
        var keys: [String] = [], marker = ""
        while true {
            var q = "?prefix=" + (prefix.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? prefix) + "&max-keys=1000"
            if !marker.isEmpty { q += "&marker=" + (marker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? marker) }
            let (data, resp) = try await Self.session.data(for: request("GET", key: "", query: q))
            try check(data, resp)
            let xml = String(decoding: data, as: UTF8.self)
            let found = xml.components(separatedBy: "<Key>").dropFirst().compactMap { $0.components(separatedBy: "</Key>").first }
            keys += found.map { $0.replacingOccurrences(of: "&amp;", with: "&") }
            guard xml.contains("<IsTruncated>true</IsTruncated>"), let last = found.last else { return keys }
            marker = last
        }
    }

    /// The object, when OSS received it (server clock, so the pen's own clock doesn't matter) and its ETag.
    /// Given the ETag from the last read, an object that hasn't changed since comes back as nil: OSS answers
    /// 304 without a body, so the heartbeat can be looked at every few seconds without downloading it each time.
    func getWithDate(_ key: String, unless etag: String? = nil) async throws -> (data: Data, received: Date?, etag: String?)? {
        var r = request("GET", key: key)
        // Asked for gzip (URLSession's default), OSS compresses JSON of 1 KB and up — and then sends no ETag.
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }   // neither is part of the V1 signature
        let (data, resp) = try await Self.session.data(for: r)
        let http = resp as? HTTPURLResponse
        if etag != nil, http?.statusCode == 304 { return nil }
        try check(data, resp)
        return (data, http?.value(forHTTPHeaderField: "Last-Modified").flatMap { Self.dateFormatter.date(from: $0) },
                http?.value(forHTTPHeaderField: "ETag"))
    }

    func get(_ key: String) async throws -> Data {
        let (data, resp) = try await Self.session.data(for: request("GET", key: key))
        try check(data, resp)
        return data
    }

    func download(_ key: String, to url: URL) async throws {
        let (tmp, resp) = try await Self.session.download(for: request("GET", key: key))
        try check(Data(), resp)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    func delete(_ key: String) async throws {
        let (data, resp) = try await Self.session.data(for: request("DELETE", key: key))
        try check(data, resp, ok: [200, 204])
    }

    func put(_ key: String, _ body: Data, contentType: String = "text/plain") async throws {
        var r = request("PUT", key: key, contentType: contentType)
        r.httpBody = body
        let (data, resp) = try await Self.session.data(for: r)
        try check(data, resp)
    }
}

/// Heartbeat the pen writes to pen/<SN>/status.json.
struct WifiStatus: Decodable {
    struct Item: Decodable { let wavPath: String; let title: String; let created: String?; let durationSec: Int; let uploaded: Bool }
    let sn: String
    let version: String
    let time: String
    let battery: Int
    let charging: Bool
    let freeBytes: Int64
    let ssid: String
    let clockStatus: String?
    let firmware: String?
    let bssid: String?
    let recordings: [Item]?
    /// How often this pen beats (uploader 1.2.1+ says so; older ones beat every 300 s).
    let heartbeatSec: Int?
    /// When the heartbeat reached OSS, by the server's clock (set by the Mac after reading it).
    var receivedAt: Date? = nil

    /// The pen's own clock — only a fallback, it can be minutes off.
    var date: Date? { ISO8601DateFormatter().date(from: time) }
    /// When the pen was last heard from.
    var seen: Date? { receivedAt ?? date }
    /// Offline after two missed beats in a row, plus a minute for this Mac's own check:
    /// 5 minutes with the 2-minute beat, 11 with the old 5-minute one. One lost beat never turns it grey.
    var offlineAfter: TimeInterval { Double(2 * (heartbeatSec ?? 300) + 60) }
    var isOnline: Bool { seen.map { Date().timeIntervalSince($0) < offlineAfter } ?? false }
}

/// What the pen uploads next to each recording (pen/<SN>/rec/<name>/meta.json).
struct WifiMeta: Decodable {
    let recordId: Int
    let type: String
    let title: String
    let created: String?
    let durationSec: Int
    let marks: [Int]?
    let wavPath: String
    let bssids: [String]?
}

enum WifiKeys {
    static let penId = "oss-pen-id", penSecret = "oss-pen-secret", macId = "oss-mac-id", macSecret = "oss-mac-secret"
}

/// "3 分钟前" style.
func relativeTime(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}
