import Foundation
import RuyioCore

/// Abstraction over remote access so resolution and market logic can be tested without the network.
public protocol RemoteFetching: Sendable {
    func fetch(_ url: URL, maxBytes: Int, accept: String?, timeout: TimeInterval) async throws -> FetchResult
    func download(_ url: URL, to destination: URL, maxBytes: Int, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws
}

public extension RemoteFetching {
    func fetch(_ url: URL, maxBytes: Int, accept: String? = nil) async throws -> FetchResult {
        try await fetch(url, maxBytes: maxBytes, accept: accept, timeout: SourceFetcher.totalTimeout)
    }
}

public struct FetchResult: Sendable {
    public var data: Data
    public var finalURL: URL
    public var statusCode: Int
    public var headers: [String: String]

    public init(data: Data, finalURL: URL, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Restricted HTTPS client for remote sources (plan §14.2).
///
/// Every request and redirect is https-only and its host must resolve exclusively to public addresses.
/// No cookies, cache, stored credentials or system proxy are used; responses are size- and time-limited.
/// Limitation (P0-07): DNS is checked before URLSession connects, so a rebinding race between check and
/// connect is not excluded. Opening arbitrary HTTPS sources for formal release is gated on P0-07, which
/// may replace this with a Network.framework connection pinned to the verified address.
public final class SourceFetcher: NSObject, URLSessionTaskDelegate, RemoteFetching, @unchecked Sendable {
    public static let maxRedirects = 5
    public static let connectTimeout: TimeInterval = 10
    public static let totalTimeout: TimeInterval = 30

    private var session: URLSession!
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]
    public var hostCheck: @Sendable (String) throws -> Void = NetworkPolicy.checkHost

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:] // PRD §23 #14 pending; see P0-07.
        configuration.timeoutIntervalForRequest = Self.connectTimeout
        configuration.timeoutIntervalForResource = Self.totalTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Ruyio/\(HostInfo.version)"]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func fetch(_ url: URL, maxBytes: Int, accept: String? = nil, timeout: TimeInterval = SourceFetcher.totalTimeout) async throws -> FetchResult {
        try validate(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as RuyioError {
            throw error
        } catch {
            throw RuyioError(.networkFailure, objectID: url.host, retryable: true, diagnostic: (error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw RuyioError(.networkFailure, objectID: url.host, retryable: true)
        }
        try validate(finalURL)
        if http.statusCode == 403 || http.statusCode == 429 {
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset") ?? http.value(forHTTPHeaderField: "Retry-After") ?? ""
            throw RuyioError(.rateLimited, objectID: url.host, retryable: true, diagnostic: reset)
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > maxBytes {
            throw RuyioError(.sourceInvalid, objectID: url.host, diagnostic: "response larger than \(maxBytes) bytes")
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 1 << 20))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw RuyioError(.sourceInvalid, objectID: url.host, diagnostic: "response larger than \(maxBytes) bytes") }
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return FetchResult(data: data, finalURL: finalURL, statusCode: http.statusCode, headers: headers)
    }

    /// Downloads a package to a file, streaming with a byte limit and cooperative cancellation.
    public func download(_ url: URL, to destination: URL, maxBytes: Int, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws {
        try validate(url)
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 300))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let finalURL = http.url else {
            throw RuyioError(.networkFailure, objectID: url.host, retryable: true)
        }
        try validate(finalURL)
        let expected = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        if let expected, expected > Int64(maxBytes) { throw RuyioError(.sourceInvalid, diagnostic: "package exceeds limit") }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var total: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                total += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(total, expected)
                if total > Int64(maxBytes) { throw RuyioError(.sourceInvalid, diagnostic: "package exceeds limit") }
            }
        }
        try handle.write(contentsOf: buffer)
        total += Int64(buffer.count)
        progress?(total, expected)
        if total > Int64(maxBytes) { throw RuyioError(.sourceInvalid, diagnostic: "package exceeds limit") }
    }

    func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host else {
            throw RuyioError(.networkPolicy, diagnostic: "non-https target")
        }
        guard url.user == nil, url.password == nil else { throw RuyioError(.networkPolicy, diagnostic: "credentials in URL") }
        try hostCheck(host)
    }

    // MARK: URLSessionTaskDelegate

    /// Redirects are re-validated hop by hop; short-lived signed download URLs are followed but never stored.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        let count = lock.withLock { () -> Int in
            redirectCounts[task.taskIdentifier, default: 0] += 1
            return redirectCounts[task.taskIdentifier]!
        }
        guard count <= Self.maxRedirects, let url = request.url, (try? validate(url)) != nil else { return nil }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        next.setValue(nil, forHTTPHeaderField: "Referer")
        return next
    }

    /// No stored or interactive credentials are ever sent to a source.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
