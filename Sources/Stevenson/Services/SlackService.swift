import Vapor

public struct SlackCommand {
    /// Command name
    public let name: String

    /// Command usage instructions
    public let help: String

    /// Channels from which this command is allowed to be triggered.
    /// If empty the command will be allowed in all channels
    public let allowedChannels: Set<String>

    /// Closure that performs the actual action of the command.
    /// If subCommands are provided, it will first try to select the appropriate sub-command
    /// by the first word in the command text, and if it finds one then this command will be executed,
    /// otherwise this closure is called
    public let run: (SlackCommandMetadata, Request) throws -> EventLoopFuture<SlackService.Response>

    public init(
        name: String,
        help: String,
        allowedChannels: Set<String>,
        subCommands: [SlackCommand] = [],
        run: @escaping (SlackCommandMetadata, Request) throws -> EventLoopFuture<SlackService.Response>
    ) {
        self.name = name
        self.allowedChannels = allowedChannels
        if subCommands.isEmpty {
            self.help = help
        } else {
            self.help = help +
            """
            Sub-commands:
            \(subCommands.map({ "- \($0.name)" }).joined(separator: "\n"))
            
            Run `/\(name) <sub-command> help` for help on a sub-command.
            """
        }
        self.run = { (metadata, request) throws -> EventLoopFuture<SlackService.Response> in
            guard let subCommand = subCommands.first(where: { metadata.text.hasPrefix($0.name) }) else {
                return try run(metadata, request)
            }

            if metadata.textComponents[1] == "help" {
                return request.eventLoop.future(SlackService.Response(subCommand.help))
            } else {
                let metadata = SlackCommandMetadata(
                    token: metadata.token,
                    channelName: metadata.channelName,
                    command: metadata.command,
                    text: metadata.textComponents.dropFirst().joined(separator: " "),
                    responseURL: metadata.responseURL
                )
                return try subCommand.run(metadata, request)
            }
        }
    }
}

public struct SlackCommandMetadata: Content {
    public let token: String
    public let channelName: String
    public let command: String
    public let text: String
    public let textComponents: [String.SubSequence]
    public let responseURL: String?

    public init(
        token: String,
        channelName: String,
        command: String,
        text: String,
        responseURL: String?
    ) {
        self.token = token
        self.channelName = channelName
        self.command = command
        self.text = text
        self.textComponents = text.split(separator: " ")
        self.responseURL = responseURL
    }

    enum CodingKeys: String, CodingKey {
        case token
        case channelName = "channel_name"
        case command
        case text
        case responseURL = "response_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try SlackCommandMetadata(
            token:          container.decode(String.self, forKey: .token),
            channelName:    container.decode(String.self, forKey: .channelName),
            command:        container.decode(String.self, forKey: .command),
            text:           container.decode(String.self, forKey: .text),
            responseURL:    container.decodeIfPresent(String.self, forKey: .responseURL)
        )
    }
}


// MARK: Service

extension Application {
    public var slack: SlackService? {
        get {
            self.storage[SlackServiceKey.self]
        }
        set {
            self.storage[SlackServiceKey.self] = newValue
        }
    }
}

struct SlackServiceKey: StorageKey {
    typealias Value = SlackService
}

public struct SlackService {
    /// Verification Token (see SlackBot App settings)
    let verificationToken: String
    /// Bot User OAuth Access Token (see SlackBot App settings)
    let oauthToken: String

    public init(verificationToken: String, oauthToken: String) {
        self.verificationToken = verificationToken
        self.oauthToken = oauthToken
    }

    public func handle(
        command: SlackCommand,
        on request: Request
    ) throws -> EventLoopFuture<Vapor.Response> {
        let metadata = try request.content
            .decode(SlackCommandMetadata.self)

        guard metadata.token == verificationToken else {
            throw ThrowError(
                error: Error.invalidToken,
                sourceLocation: .capture()
            )
        }

        guard command.allowedChannels.isEmpty || command.allowedChannels.contains(metadata.channelName) else {
            throw ThrowError(
                error: Error.invalidChannel(metadata.channelName, allowed: command.allowedChannels),
                sourceLocation: .capture()
            )
        }

        if metadata.text == "help" {
            return try request.eventLoop
                .future(SlackService.Response(command.help))
                .catchError(.capture())
                .recover { SlackService.Response(error: $0) }
                .encodeResponse(for: request)
        } else {
            return try command.run(metadata, request)
                .catchError(.capture())
                .recover { SlackService.Response(error: $0) }
                .encodeResponse(for: request)
        }
    }

    public func post(
        message: Message,
        on request: Request
    ) throws -> EventLoopFuture<Vapor.Response> {
        let fullURL = URI(string: "https://slack.com/api/chat.postMessage")
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(self.oauthToken)"
        ]

        return try request.client
            .post(fullURL, headers: headers) {
                try $0.content.encode(message)
            }
            .catchError(.capture())
            .encodeResponse(for: request)
    }
}

extension EventLoopFuture where Value == SlackService.Response {
    public func replyLater(
        withImmediateResponse now: SlackService.Response,
        responseURL: String?,
        on request: Request
    ) -> EventLoopFuture<SlackService.Response> {
        guard let responseURL = responseURL else {
            return request.eventLoop.future(now)
        }

        _ = self
            .recover { SlackService.Response(error: $0) }
            .flatMapThrowing { response in
                try request.client
                    .post(URI(string: responseURL)) {
                        try $0.content.encode(response)
                    }
                    .catchError(.capture())
        }

        return request.eventLoop.future(now)
    }
}

extension SlackService {
    public struct Response: Content {
        public let text: String
        public let attachments: [Attachment]?
        public let visibility: Visibility

        public enum Visibility: String, Content {
            /// Response message visible only to the user who triggered the command
            case user = "ephemeral"
            /// Response message visible to all members of the channel where the command was triggered
            case channel = "in_channel"
        }

        enum CodingKeys: String, CodingKey {
            case text
            case attachments
            case visibility = "response_type"
        }

        public init(_ text: String, attachments: [Attachment]? = nil, visibility: Visibility = .user) {
            self.text = text
            self.attachments = attachments
            self.visibility = visibility
        }
    }

    public struct Message: Content {
        public let channelID: String
        public let text: String
        public let attachments: [Attachment]?

        enum CodingKeys: String, CodingKey {
            case channelID = "channel"
            case text
            case attachments
        }

        public init(channelID: String, text: String, attachments: [Attachment]? = nil) {
            self.channelID = channelID
            self.text = text
            self.attachments = attachments
        }
    }

    public struct Attachment: Content {
        let text: String
        let color: String
        public init(text: String, color: String) {
            self.text = text
            self.color = color
        }
        public static func success(_ text: String) -> Attachment {
            .init(text: text, color: "36a64f")
        }
        public static func warning(_ text: String) -> Attachment {
            .init(text: text, color: "fff000")
        }
        public static func error(_ text: String) -> Attachment {
            .init(text: text, color: "ff0000")
        }
    }
}
