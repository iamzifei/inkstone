import Foundation
import CryptoKit

/// Computes the SHA-1 that git — and therefore the GitHub API — uses to identify
/// a blob.
///
/// This is why the sync planner can compare local files against remote entries
/// directly: both sides are named by the same hash, so "has this changed?" needs
/// no timestamps, no clock agreement between machines, and no extra round trip
/// to fetch content just to compare it.
///
/// The format is git's, not a plain hash of the bytes:
///     sha1("blob " + <byte count> + "\0" + <contents>)
public func gitBlobSHA(_ data: Data) -> String {
    var payload = Data("blob \(data.count)\0".utf8)
    payload.append(data)
    return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
}

/// A file as the remote repository sees it.
public struct RemoteFile: Hashable, Sendable {
    public let path: String
    public let sha: String
    public let size: Int

    public init(path: String, sha: String, size: Int) {
        self.path = path
        self.sha = sha
        self.size = size
    }
}

public enum GitHubError: LocalizedError, Sendable {
    case notConfigured
    case badRepository(String)
    case unauthorised
    case notFound(String)
    case rateLimited(resetAt: Date?)
    case conflict(String)
    case tooLarge(path: String, size: Int)
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set a repository and a personal access token in Settings › Sync first."
        case .badRepository(let value):
            return "\"\(value)\" is not an owner/repository pair."
        case .unauthorised:
            return "GitHub rejected the token. Check that it has not expired and grants Contents: read and write."
        case .notFound(let path):
            return "GitHub could not find \(path). Check the repository name and branch."
        case .rateLimited(let resetAt):
            guard let resetAt else { return "GitHub rate limit reached. Try again shortly." }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "GitHub rate limit reached. It resets at \(formatter.string(from: resetAt))."
        case .conflict(let path):
            return "\(path) changed on GitHub while syncing. Run sync again."
        case .tooLarge(let path, let size):
            let mb = Double(size) / 1_048_576
            return String(format: "%@ is %.1f MB. The GitHub Contents API cannot handle files over 100 MB.", path, mb)
        case .http(let status, let message):
            return "GitHub returned \(status). \(message)"
        }
    }
}

/// Minimal GitHub Contents/Git API client, only what syncing a vault needs.
///
/// Deliberately not libgit2: a real git implementation on iOS is a swamp of
/// build problems, and a notes vault does not need history, branches or merges —
/// it needs "what files are there, give me this one, put this one back".
public struct GitHubClient: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// "owner/repository".
        public var repository: String
        public var branch: String

        public init(repository: String, branch: String = "main") {
            self.repository = repository
            self.branch = branch
        }

        var owner: String? { repository.split(separator: "/").count == 2 ? String(repository.split(separator: "/")[0]) : nil }
        var name: String? { repository.split(separator: "/").count == 2 ? String(repository.split(separator: "/")[1]) : nil }
    }

    public let configuration: Configuration
    private let token: String
    private let session: URLSession

    public init(configuration: Configuration, token: String, session: URLSession = .shared) {
        self.configuration = configuration
        self.token = token
        self.session = session
    }

    // MARK: - Requests

    private func base() throws -> URL {
        guard let owner = configuration.owner, let name = configuration.name,
              !owner.isEmpty, !name.isEmpty
        else { throw GitHubError.badRepository(configuration.repository) }
        return URL(string: "https://api.github.com/repos/\(owner)/\(name)")!
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Inkstone", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest, describing path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            // 403 is also how GitHub reports a spent rate limit, distinguished by
            // the remaining-requests header rather than the status code.
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(Double.init)
                    .map { Date(timeIntervalSince1970: $0) }
                throw GitHubError.rateLimited(resetAt: reset)
            }
            throw GitHubError.unauthorised
        case 404:
            throw GitHubError.notFound(path)
        case 409, 422:
            throw GitHubError.conflict(path)
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String } ?? ""
            throw GitHubError.http(status: http.statusCode, message: message)
        }
    }

    // MARK: - Operations

    /// Every file on the branch, in one request.
    ///
    /// Uses the git trees API rather than walking Contents directory by
    /// directory: a vault with a hundred folders would otherwise cost a hundred
    /// round trips and burn the rate limit before syncing a single note.
    public func listFiles() async throws -> [RemoteFile] {
        let url = try base().appending(path: "git/trees/\(configuration.branch)")
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "1")])

        let data: Data
        do {
            data = try await send(request(url), describing: configuration.branch)
        } catch GitHubError.notFound {
            // An empty repository has no tree yet. That is a legitimate starting
            // point for a first sync, not an error.
            return []
        }

        struct Response: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String
                let sha: String
                let size: Int?
            }
            let tree: [Entry]
        }
        return try JSONDecoder().decode(Response.self, from: data)
            .tree
            .filter { $0.type == "blob" }
            .map { RemoteFile(path: $0.path, sha: $0.sha, size: $0.size ?? 0) }
    }

    /// Downloads one blob by its SHA.
    public func download(sha: String, path: String) async throws -> Data {
        let url = try base().appending(path: "git/blobs/\(sha)")
        var request = request(url)
        // Ask for the bytes directly; the JSON form is base64 and 33% larger.
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        return try await send(request, describing: path)
    }

    /// Creates or updates a file. `sha` must be the blob currently at that path,
    /// or nil when creating.
    @discardableResult
    public func upload(path: String, contents: Data, sha: String?, message: String) async throws -> String {
        guard contents.count <= 100 * 1_048_576 else {
            throw GitHubError.tooLarge(path: path, size: contents.count)
        }
        var payload: [String: Any] = [
            "message": message,
            "content": contents.base64EncodedString(),
            "branch": configuration.branch,
        ]
        if let sha { payload["sha"] = sha }

        let url = try contentsURL(for: path)
        let data = try await send(
            request(url, method: "PUT", body: JSONSerialization.data(withJSONObject: payload)),
            describing: path
        )

        struct Response: Decodable {
            struct Content: Decodable { let sha: String }
            let content: Content
        }
        return try JSONDecoder().decode(Response.self, from: data).content.sha
    }

    public func delete(path: String, sha: String, message: String) async throws {
        let payload: [String: Any] = [
            "message": message,
            "sha": sha,
            "branch": configuration.branch,
        ]
        let url = try contentsURL(for: path)
        _ = try await send(
            request(url, method: "DELETE", body: JSONSerialization.data(withJSONObject: payload)),
            describing: path
        )
    }

    /// Confirms the token and repository work before a sync writes anything.
    public func verify() async throws -> String {
        let data = try await send(request(try base()), describing: configuration.repository)
        struct Response: Decodable { let full_name: String }
        return try JSONDecoder().decode(Response.self, from: data).full_name
    }

    /// Contents-API URL for a vault path.
    ///
    /// The path is handed to `appending(path:)` raw. Percent-encoding it first
    /// double-encodes it — `URL` escapes the `%` again — so "Product Ideas.md"
    /// went out as "Product%2520Ideas.md" and would have been written to a
    /// wrongly named file on GitHub.
    private func contentsURL(for path: String) throws -> URL {
        try base().appending(path: "contents").appending(path: path)
    }
}
