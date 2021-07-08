import Vapor

extension SlackService {
    public enum Error: Swift.Error, DebuggableError {
        case invalidToken
        case invalidChannel(String, allowed: Set<String>)
        case missingParameter(key: String)
        case invalidParameter(key: String, value: String, expected: String)

        public var identifier: String {
            "SlackService.Error"
        }

        public var reason: String {
            switch self {
            case .invalidToken:
                return "Invalid token"
            case let .invalidChannel(channel, allowed):
                return """
                    Invalid channel `\(channel)`. Command should be invoked from one of these channels:
                    \(allowed.map { "* `\($0)`" }.joined(separator: "\n"))
                    """
            case let .missingParameter(key):
                return "Missing parameter for `\(key)`"
            case let .invalidParameter(key, value, expected):
                return "Invalid parameter `\(value)` for `\(key)`. Expected \(expected)."
            }
        }
    }
}

protocol FailableService {
    associatedtype ServiceError: Error & Decodable & DebuggableError
}

extension FailableService {
    public func request<T: Decodable>(
        _ errorSource: ErrorSource,
        _ makeRequest: () throws -> EventLoopFuture<Response>
    ) throws -> EventLoopFuture<T> {
        try makeRequest()
            .flatMapThrowing { response -> T in
                do {
                    return try response.content
                        .decode(T.self)
                } catch {
                    throw try response.content
                        .decode(ServiceError.self)
                }
            }
    }

    public func request(
        _ errorSource: ErrorSource,
        _ makeRequest: () throws -> EventLoopFuture<Response>
    ) throws -> EventLoopFuture<Void> {
        try makeRequest()
            .flatMapThrowing { (response) in
                guard response.status == .noContent else {
                    throw try response.content
                        .decode(ServiceError.self)
                }
            }
            .catchError(.capture())
    }
}

extension CircleCIService: FailableService {
    struct ServiceError: Swift.Error, Decodable, DebuggableError {
        let message: String
        var identifier: String { "CircleCIService" }
        var reason: String { message }
    }
}

extension GitHubService: FailableService {
    struct ServiceError: Swift.Error, Decodable, DebuggableError {
        let message: String
        var identifier: String { "GitHubService" }
        var reason: String { message }
    }
}

extension JiraService: FailableService {
    public struct ServiceError: Swift.Error, Decodable, DebuggableError {
        // See https://developer.atlassian.com/cloud/jira/platform/rest/v3/#status-codes for schema
        public let errorMessages: [String]
        public let errors: [String: String]
        public var identifier: String { "JiraService" }

        public var reason: String {
            let allErrors = errorMessages + errors.sorted(by: <).map { "\($0): \($1)" }
            if allErrors.count > 1 {
                return allErrors
                    .enumerated()
                    .map { "[\($0.offset+1)] \($0.element)" }
                    .joined(separator: " ")
            } else {
                return allErrors.first ?? "Unknown error"
            }
        }
    }
}

public struct NilValueError: Error, DebuggableError {
    public let identifier = "nilValue"
    public let reason = "Unexpected nil value"
}

public struct ThrowError: Error, DebuggableError {
    public let error: Error
    public let identifier: String
    public let reason: String
    public let sourceLocation: ErrorSource?

    init(error: Error, sourceLocation: ErrorSource) {
        self.error = error

        let _sourceLocation: ErrorSource?
        if let throwError = error as? ThrowError {
            self.identifier = throwError.identifier
            self.reason = throwError.reason
            _sourceLocation = throwError.sourceLocation
        } else if let debuggable = error as? DebuggableError {
            self.identifier = "\(type(of: debuggable)).\(debuggable.identifier)"
            self.reason = debuggable.reason
            _sourceLocation = debuggable.source
        } else {
            self.identifier = "\(type(of: error))"
            self.reason = error.localizedDescription
            _sourceLocation = sourceLocation
        }

        #if DEBUG
        self.sourceLocation = _sourceLocation ?? sourceLocation
        #else
        self.sourceLocation = nil
        #endif
    }

    init(error: Error, file: String, line: UInt, column: UInt, function: String) {
        self.init(
            error: error,
            sourceLocation: ErrorSource(
                file: file,
                function: function,
                line: line,
                column: column,
                range: nil
            )
        )
    }
}

#if !DEBUG
extension SlackService.Error {
    public var errorDescription: String? {
        reason
    }
}

extension ThrowError: LocalizedError {
    public var errorDescription: String? {
        reason
    }
}
#endif

public func attempt<T>(
    file: StaticString = #file,
    line: UInt = #line,
    column: UInt = #column,
    function: StaticString = #function,
    expr: () throws -> T?
) throws -> T {
    do {
        guard let value = try expr() else {
            throw NilValueError()
        }
        return value
    } catch {
        throw ThrowError(error: error, file: "\(file)", line: line, column: column, function: "\(function)")
    }
}

public func attempt<T>(
    file: StaticString = #file,
    line: UInt = #line,
    column: UInt = #column,
    function: StaticString = #function,
    expr: () throws -> T?
) throws -> T? {
    do {
        return try expr()
    } catch {
        throw ThrowError(error: error, file: "\(file)", line: line, column: column, function: "\(function)")
    }
}

extension EventLoopFuture {
    public func catchError(_ errorSource: ErrorSource) throws -> EventLoopFuture<Value> {
        catchFlatMap { (error) -> EventLoopFuture<Value> in
            throw ThrowError(error: error, sourceLocation: errorSource)
        }
    }

    private func catchFlatMap(
        _ callback: @escaping (Error) throws -> (EventLoopFuture<Value>)
    ) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)

        _ = self.always { result in
            switch result {
            case let .success(e):
                promise.succeed(e)
            case let .failure(error):
                do {
                    try callback(error).cascade(to: promise)
                } catch {
                    promise.fail(error)
                }
            }
        }

        return promise.futureResult
    }
}

extension SlackService.Response {
    public init(error: Error, visibility: Visibility = .user) {
        #if DEBUG
        self.init(String(describing: error), visibility: visibility)
        #else
        self.init(error.localizedDescription, visibility: visibility)
        #endif
    }
}
