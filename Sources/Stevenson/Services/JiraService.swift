import Vapor

extension Application {
    public var jira: JiraService? {
        get {
            self.storage[JiraServiceKey.self]
        }
        set {
            self.storage[JiraServiceKey.self] = newValue
        }
    }
}

struct JiraServiceKey: StorageKey {
    typealias Value = JiraService
}

public struct JiraService {
    public let baseURL: URL
    private let headers: HTTPHeaders
    // Whitelist of Project Keys, and their corresponding ID, on which we're allowed to interact and create JIRA versions
    public let knownProjects: [String: Int]
    public let logger: Logger

    public init(baseURL: URL, username: String, password: String, knownProjects: [String: Int], logger: Logger) {
        self.baseURL = baseURL

        let base64Auth = Data("\(username):\(password)".utf8).base64EncodedString(options: [])
        self.headers = [
            "Authorization": "Basic \(base64Auth)",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        self.knownProjects = knownProjects
        self.logger = logger
    }
}

// MARK: Ticket ID

extension JiraService {
    /// Represents a reference to a JIRA ticket, in the form [XXX-123]
    public struct TicketID: CustomStringConvertible {
        /// The board code, e.g. `NRX`, `AV`, `CNSMR`...
        public let board: String
        /// The ticket number (just the part after the dash), e.g. `123`
        public let number: String

        /// The full ticket name (the field 'key' in JIRA API), e.g. `CNSMR-123`
        public var key: String {
            return "\(board)-\(number)"
        }

        public var description: String {
            return key
        }

        public init(board: String, number: String) {
            self.board = board.uppercased()
            self.number = number
        }

        /// Extract a Ticket reference from a commit message
        ///
        /// - Parameter message: The commit message to extract the ticket reference from
        public init?(from message: String) {
            let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
            let match = JiraService.TicketID.regex.firstMatch(in: message, options: [], range: fullRange)
            guard
                let board = JiraService.TicketID.text(for: match, at: 2, in: message),
                let number = JiraService.TicketID.text(for: match, at: 3, in: message)
                else { return nil }
            self.init(board: board, number: number)
        }

        public static let regex = try! NSRegularExpression(pattern: #"\[?\b(([A-Za-z]+)-([0-9]+))\b\]?"#, options: [])

        private static func text(for match: NSTextCheckingResult?, at index: Int, in text: String) -> String? {
            return match
                .map { $0.range(at: index) }
                .flatMap { Range($0, in: text) }
                .map { String(text[$0]) }
        }
    }
}

// MARK: Issue creation API

public protocol JiraIssueFields: Content {
    var project: JiraService.FieldType.ObjectID { get }
    var issueType: JiraService.FieldType.ObjectID { get }
    var summary: String { get }
}

extension JiraService {
    public struct Issue<Fields: JiraIssueFields>: Content {
        public let fields: Fields
        public init(fields: Fields) {
            self.fields = fields
        }
    }

    public struct CreatedIssue: Content {
        public let id: String
        public let key: String
        public let url: String
        enum CodingKeys: String, CodingKey {
            case id
            case key
            case url = "self"
        }
    }

    public func create<Fields>(
        issue: Issue<Fields>,
        on request: Request
    ) throws -> EventLoopFuture<CreatedIssue> {
        let fullURL = URI(
            string: URL(string: "/rest/api/3/issue", relativeTo: baseURL)!.absoluteString
        )

        let logMessage = "Creating a new issue <\(issue.fields.summary)> on board #\(issue.fields.project.id)"
        self.logInfo(logMessage)

        let response = try request.slowClient.post(
            fullURL,
            headers: self.headers,
            on: request.application
        ) { request in
            try request.content.encode(issue)
            self.logRequest(logMessage, request)
        }
        .catchError(.capture())

        response.whenSuccess { response in
            self.logResponse(logMessage, response)
        }

        return response
            .flatMapThrowing { try $0.content.decode(CreatedIssue.self) }
    }
}

// MARK: JIRA Versions creation API

extension JiraService {
    public struct Version: Content {
        public let id: String?
        public let projectId: Int
        public let description: String?
        public let name: String
        let released: Bool
        let startDate: CustomCodable<YMDDate>?

        public init(id: String? = nil, projectId: Int, name: String, description: String?, released: Bool = false, startDate: Date?) {
            self.id = id
            self.projectId = projectId
            self.name = name
            self.description = description
            self.released = released
            self.startDate = startDate.map(CustomCodable<YMDDate>.init(wrappedValue:))
        }
    }

    public func getVersions(
        project projectID: Int,
        on request: Request
    ) throws -> EventLoopFuture<[Version]> {
        let fullURL = URI(
            string: URL(
                string: "/rest/api/3/project/\(projectID)/versions",
                relativeTo: baseURL
            )!.absoluteString
        )

        let projectKey = self.knownProjects.first(where: { $0.value == projectID })?.key ?? "#\(projectID)"
        let logMessage = "Fetching JIRA versions for board <\(projectKey)>"
        self.logInfo(logMessage)

        let response = try request.slowClient.get(
            fullURL,
            headers: self.headers,
            on: request.application
        ) { request in
            self.logRequest(logMessage, request)
        }
        .catchError(.capture())

        response.whenSuccess { response in
            self.logResponse(logMessage, response)
        }

        return response
            .flatMapThrowing { try $0.content.decode([Version].self) }
    }

    public func createVersion(
        _ version: Version,
        on request: Request
    ) throws -> EventLoopFuture<Version> {
        let fullURL = URI(
            string: URL(string: "/rest/api/3/version", relativeTo: baseURL)!.absoluteString
        )

        let projectKey = self.knownProjects.first(where: { $0.value == version.projectId })?.key ?? "#\(version.projectId)"
        let logMessage = "Creating a new JIRA version <\(version.name)> on board <\(projectKey)>"
        self.logInfo(logMessage)

        let response = try request.slowClient.get(
            fullURL,
            headers: self.headers,
            on: request.application
        ) { request in
            try request.content.encode(version)
            self.logRequest(logMessage, request)
        }
        .catchError(.capture())

        response.whenSuccess { response in
            self.logResponse(logMessage, response)
        }

        return response
            .flatMapThrowing { try $0.content.decode(Version.self) }
    }
}

// MARK: FixVersion field update API
extension JiraService {
    public struct VersionAddUpdate: Content {
        let update: FixVersionUpdate

        struct FixVersionUpdate: Content {
            let fixVersions: [FieldUpdate<Version>]
        }

        struct FieldUpdate<T: Codable>: Content {
            let add: T
        }

        public init(version: Version) {
            self.update = FixVersionUpdate(fixVersions: [FieldUpdate(add: version)])
        }
    }

    public func setFixVersion(
        _ version: Version,
        for ticket: String,
        on request: Request
    ) throws -> EventLoopFuture<Void> {
        let fullURL = URI(
            string: URL(string: "/rest/api/3/issue/\(ticket)", relativeTo: baseURL)!.absoluteString
        )

        let logMessage = "Setting Fix Version field to <ID \(version.id ?? "nil")> (<\(version.name)>) for ticket <\(ticket)>"
        self.logInfo(logMessage)

        let response = try request.slowClient.put(
            fullURL,
            headers: self.headers,
            on: request.application
        ) { request in
            try request.content.encode(VersionAddUpdate(version: version))
            self.logRequest(logMessage, request)
        }
        .catchError(.capture())

        response.whenSuccess { response in
            self.logResponse(logMessage, response)
        }

        return response
            .map { _ in () }
    }
}

// MARK: Helpers

extension JiraService {
    fileprivate func logInfo(_ message: String) {
        self.logger.info("[JIRA] \(message)")
    }

    fileprivate func logRequest(_ message: String, _ request: Request) {
        self.logger.debug("[JIRA-API] Request for \(message):\n======>\n\(request)\n<======")
    }

    fileprivate func logResponse(_ message: String, _ response: Response) {
        self.logger.debug("[JIRA-API] response for \(message):\n======>\n\(response)\n<======")
    }
}

extension JiraService {
    public func browseURL(issue: CreatedIssue) -> String {
        self.browseURL(issue: issue.key)
    }
    public func browseURL(issue: String) -> String {
        "\(self.baseURL)/browse/\(issue)"
    }
}
