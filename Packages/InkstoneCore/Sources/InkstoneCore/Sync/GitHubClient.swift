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
    /// The configured branch is not in the repository.
    ///
    /// Its own case because it used to be indistinguishable from an empty
    /// repository, and the two lead opposite ways: an empty repository means
    /// "upload everything", a missing branch means "you cannot see the remote at
    /// all". Treating the second as the first told the planner the remote had no
    /// files, which is how a mistyped branch became an instruction to delete
    /// every local note that had synced.
    case branchNotFound(branch: String, repository: String, available: [String])
    /// `path` is what the call was about — a file path, or the repository for
    /// calls that are not about one file. Without it a 5xx says only that
    /// something went wrong somewhere, which is the position an actual 503 left
    /// this client in: every operation was individually fine when tried by hand,
    /// and the failing one could not be identified from the error at all.
    case http(status: Int, message: String, path: String)

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
        case .branchNotFound(let branch, let repository, let available):
            let known = available.isEmpty
                ? ""
                : " It has: " + available.prefix(6).joined(separator: ", ") + "."
            return "\(repository) has no branch called \"\(branch)\".\(known)"
        case .tooLarge(let path, let size):
            let mb = Double(size) / 1_048_576
            return String(format: "%@ is %.1f MB. The GitHub Contents API cannot handle files over 100 MB.", path, mb)
        case .http(let status, let message, let path):
            let detail = message.isEmpty ? "" : " \(message)"
            return "GitHub returned \(status) for \(path).\(detail)"
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

    /// How a request that GitHub could not serve is retried.
    ///
    /// GitHub answers a 503 with "Please try resubmitting your request", and
    /// this client did not. A single transient 5xx failed a whole sync — measured
    /// rather than imagined: two runs in five failed this way against a real
    /// repository, always on the same probe path, while every one of the four
    /// operations was individually fine when tried by hand seconds later.
    ///
    /// Only 5xx and 429 are retried. A 4xx is an answer, and repeating a request
    /// that GitHub understood and refused just refuses it again.
    public struct RetryPolicy: Sendable {
        public var attempts: Int
        /// Doubled after each attempt.
        public var initialDelay: Duration

        public init(attempts: Int = 3, initialDelay: Duration = .milliseconds(600)) {
            self.attempts = attempts
            self.initialDelay = initialDelay
        }

        /// No waiting, for tests that would otherwise spend their time asleep.
        public static let immediate = RetryPolicy(attempts: 3, initialDelay: .zero)
    }

    public let configuration: Configuration
    private let token: String
    private let session: URLSession
    private let retry: RetryPolicy

    public init(
        configuration: Configuration,
        token: String,
        session: URLSession = .shared,
        retry: RetryPolicy = RetryPolicy()
    ) {
        self.configuration = configuration
        self.token = token
        self.session = session
        self.retry = retry
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
        // Never serve sync from the URL cache.
        //
        // GitHub answers with `cache-control: private, max-age=60`, and the
        // default protocol policy honours it. Syncing twice inside a minute then
        // sees a *stale* file list: the second run finds the file it just
        // uploaded missing from the remote, and since the recorded state says it
        // was there, three-way comparison reads that as a remote deletion and
        // deletes the local note. A minute-old listing is worthless here; the
        // whole point of the request is to learn what changed.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Inkstone", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest, describing path: String) async throws -> Data {
        var delay = retry.initialDelay
        for attempt in 1...max(1, retry.attempts) {
            do {
                return try await attemptSend(request, describing: path)
            } catch let error as GitHubError {
                guard case .http(let status, _, _) = error,
                      status >= 500 || status == 429,
                      attempt < retry.attempts
                else { throw error }
                if delay > .zero { try? await Task.sleep(for: delay) }
                delay = delay * 2
            }
        }
        // Unreachable: the loop either returns or throws on its last attempt.
        throw GitHubError.http(status: 0, message: "no attempt was made", path: path)
    }

    private func attemptSend(_ request: URLRequest, describing path: String) async throws -> Data {
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
            throw GitHubError.http(status: http.statusCode, message: message, path: path)
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
            // A 404 here is "no such branch", and it used to be swallowed as "the
            // repository is empty". Those lead opposite ways: empty means upload
            // everything, missing means we cannot see the remote at all. Reported
            // as an empty remote, a mistyped branch told the planner every synced
            // file had been deleted remotely — and the planner's answer to that
            // is to delete the local copy.
            //
            // The genuinely empty case is the 409 below, which is what a
            // repository with no commits actually answers.
            throw GitHubError.branchNotFound(
                branch: configuration.branch,
                repository: configuration.repository,
                available: (try? await listBranches()) ?? []
            )
        } catch GitHubError.conflict {
            // A repository with no commits at all answers 409 ("Git Repository
            // is empty"), not 404 — found by pointing this at a freshly created
            // repository, which is exactly how a first sync starts. On this
            // endpoint 409 has no other meaning, so it is the same empty case.
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
    /// Checks the repository *and* the branch.
    ///
    /// The branch was not checked, so "Verify" passed on a configuration that
    /// could not sync a single file — the repository existed and the branch did
    /// not. A check that only tests the half that is usually right is worse than
    /// none: it certifies the failure.
    public func verify() async throws -> String {
        let data = try await send(request(try base()), describing: configuration.repository)
        struct Response: Decodable { let full_name: String }
        let name = try JSONDecoder().decode(Response.self, from: data).full_name

        let branches = try await listBranches()
        // An empty list is a repository with no commits, where the branch cannot
        // exist yet and its absence is not a mistake.
        if !branches.isEmpty, !branches.contains(configuration.branch) {
            throw GitHubError.branchNotFound(
                branch: configuration.branch, repository: name, available: branches
            )
        }
        return name
    }

    /// Repositories this token can reach, most recently pushed first.
    ///
    /// Not scoped to `configuration.repository` — it is what fills the picker
    /// *before* a repository has been chosen, so it deliberately does not go
    /// through `base()`.
    ///
    /// With a fine-grained token this returns only the repositories it was
    /// granted, which is the right list rather than a truncated one: the picker
    /// should offer exactly what the token can actually sync to.
    ///
    /// - Parameter limit: pages are 100; two is plenty to choose from and keeps
    ///   an account with hundreds of repositories from spending a minute here.
    public func listRepositories(pages limit: Int = 2) async throws -> [Repository] {
        var found: [Repository] = []
        for page in 1...max(1, limit) {
            var components = URLComponents(string: "https://api.github.com/user/repos")!
            components.queryItems = [
                .init(name: "per_page", value: "100"),
                .init(name: "page", value: String(page)),
                .init(name: "sort", value: "pushed"),
            ]
            let data = try await send(request(components.url!), describing: "your repositories")
            struct Response: Decodable {
                let full_name: String
                let default_branch: String?
                let permissions: Permissions?
                struct Permissions: Decodable { let push: Bool? }
            }
            let page = try JSONDecoder().decode([Response].self, from: data)
            found += page.map {
                Repository(
                    fullName: $0.full_name,
                    defaultBranch: $0.default_branch ?? "main",
                    canPush: $0.permissions?.push ?? true
                )
            }
            if page.count < 100 { break }
        }
        return found
    }

    /// Branch names on the configured repository, for the branch picker.
    public func listBranches() async throws -> [String] {
        var components = URLComponents(
            url: try base().appending(path: "branches"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [.init(name: "per_page", value: "100")]
        let data: Data
        do {
            data = try await send(request(components.url!), describing: configuration.repository)
        } catch GitHubError.conflict {
            // A repository with no commits has no branches; that is a starting
            // point, not a failure.
            return []
        }
        struct Response: Decodable { let name: String }
        return try JSONDecoder().decode([Response].self, from: data).map(\.name)
    }

    /// One repository as the picker needs it.
    public struct Repository: Hashable, Sendable, Identifiable {
        public let fullName: String
        public let defaultBranch: String
        /// Whether the token may write. Read-only repositories are still listed —
        /// hiding them would leave someone hunting for a repository that is right
        /// there — but sync would fail on the first upload, so the picker says so.
        public let canPush: Bool

        public var id: String { fullName }

        public init(fullName: String, defaultBranch: String, canPush: Bool) {
            self.fullName = fullName
            self.defaultBranch = defaultBranch
            self.canPush = canPush
        }
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
