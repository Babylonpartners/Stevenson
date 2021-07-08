import Vapor

extension Application {
    public var github: GitHubService? {
        get {
            self.storage[GitHubServiceKey.self]
        }
        set {
            self.storage[GitHubServiceKey.self] = newValue
        }
    }
}

struct GitHubServiceKey: StorageKey {
    typealias Value = GitHubService
}

public struct GitHubService {
    public let baseURL = URL(string: "https://api.github.com:443")!
    public let headers: HTTPHeaders

    public init(username: String, token: String) {
        var headers = HTTPHeaders()
        headers.add(name: HTTPHeaders.Name.accept, value: HTTPMediaType.json.description)
        headers.basicAuthorization = BasicAuthorization(username: username, password: token)
        self.headers = headers
    }
}

extension GitHubService {
    public struct Repository {
        public let fullName: String
        public let baseBranch: String

        public init(
            fullName: String,
            baseBranch: String
        ) {
            self.fullName = fullName
            self.baseBranch = baseBranch
        }
    }

    public struct Reference: Decodable {
        public let sha: String

        enum CodingKeys: CodingKey {
            case object
            case sha
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder
                .container(keyedBy: CodingKeys.self)
                .nestedContainer(keyedBy: CodingKeys.self, forKey: .object)

            self.sha = try container.decode(String.self, forKey: .sha)
        }
    }

    public struct Release {
        public let repository: Repository
        public let branch: String
        public let appName: String
        public let version: String
        public let isMatchingTag: (String) -> Bool // To find a tag matching a previous version for the same app

        public init(repository: Repository, branch: String, appName: String, version: String, isMatchingTag: @escaping (String) -> Bool) {
            self.repository = repository
            self.branch = branch
            self.appName = appName
            self.version = version
            self.isMatchingTag = isMatchingTag
        }
    }
}

extension GitHubService {
    public func branch(
        in repo: Repository,
        name: String,
        request: Request
    ) throws -> EventLoopFuture<GitHubService.Reference> {
        let url = URI(
            string: URL(
                string: "/repos/\(repo.fullName)/git/refs/heads/\(name)",
                relativeTo: baseURL
            )!.absoluteString
        )
        return try request.client.get(url, headers: headers).flatMapThrowing {
            try $0.content.decode(GitHubService.Reference.self)
        }.catchError(.capture())
    }

    public func createBranch(
        in repo: Repository,
        name: String,
        from ref: GitHubService.Reference,
        request: Request
    ) throws -> EventLoopFuture<GitHubService.Reference> {
        let url = URI(
            string: URL(
                string: "/repos/\(repo.fullName)/git/refs",
                relativeTo: baseURL
            )!.absoluteString
        )
        return try request.client.post(url, headers: headers) {
            try $0.content.encode(["ref": "refs/heads/\(name)", "sha": ref.sha])
        }
        .catchError(.capture())
        .flatMapThrowing {
            try $0.content.decode(GitHubService.Reference.self)
        }
    }

    /// Return the list the tag names corresponding to all GitHub releases.
    ///
    /// The list is limited to the last 100 releases.
    ///
    /// - Parameters:
    ///   - repo: The repository from which to get the GitHub Releases
    ///   - container: The Vapor Container to run the request on
    /// - Returns: List of tag names for the found GitHub releases.
    /// - Throws: Vapor Exception if the request failed
    public func releases(
        in repo: Repository,
        request: Request
    ) throws -> EventLoopFuture<[String]> {
        struct Response: Content {
            let tag_name: String
        }
        let url = URI(
            string: URL(
                string: "/repos/\(repo.fullName)/releases?per_page=100",
                relativeTo: baseURL
            )!.absoluteString
        )
        return try request.client.get(url, headers: headers)
            .catchError(.capture())
            .flatMapThrowing{ try $0.content.decode([Response].self) }
            .map { (response: [Response]) -> [String] in
                response.map { $0.tag_name }
            }
    }

    public struct PullRequest: Content {
        public struct Ref: Content {
            public let ref: String
        }

        public let head: Ref
        public let base: Ref
    }

    public func pullRequest(
        number: Int,
        in repo: Repository,
        on request: Request
    ) throws -> EventLoopFuture<PullRequest> {
        let url = URI(
            string: URL(
                string: "/repos/\(repo.fullName)/pulls/\(number)",
                relativeTo: baseURL
            )!.absoluteString
        )
        return try request.client.get(url, headers: headers)
            .catchError(.capture())
            .flatMapThrowing {
                try $0.content.decode(PullRequest.self)
            }
    }
}
