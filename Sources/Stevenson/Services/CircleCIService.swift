import Vapor

extension Application {
    public var ci: CircleCIService? {
        get {
            self.storage[CircleCIServiceKey.self]
        }
        set {
            self.storage[CircleCIServiceKey.self] = newValue
        }
    }
}

struct CircleCIServiceKey: StorageKey {
    typealias Value = CircleCIService
}

public struct CircleCIService {
    private let baseURL = URL(string: "https://circleci.com")!
    private let headers: HTTPHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json"
    ]

    public let token: String

    public init(token: String) {
        self.token = token
    }

}

// MARK: - Job
extension CircleCIService {
    struct BuildRequest: Content {
        let buildParameters: [String: String]

        enum CodingKeys: String, CodingKey {
            case buildParameters = "build_parameters"
        }
    }

    public struct BuildResponse: Content {
        public let branch: String
        public let buildURL: String

        enum CodingKeys: String, CodingKey {
            case branch
            case buildURL = "build_url"
        }
    }

    private func buildURL(project: String, branch: String) -> URL {
        return URL(
            string: "/api/v1.1/project/github/\(project)/tree/\(branch)?circle-token=\(token)",
            relativeTo: baseURL
        )!
    }

    public func job(
        parameters: [String: String],
        project: String,
        branch: String,
        on request: Request
    ) throws -> EventLoopFuture<BuildResponse> {
        let url = URI(string: buildURL(project: project, branch: branch).absoluteString)
        return try request.client.post(url, headers: headers) {
            try $0.content.encode(BuildRequest(buildParameters: parameters))
        }.flatMapThrowing {
            try $0.content.decode(BuildResponse.self)
        }.catchError(.capture())
    }

}


// MARK: - Pipeline
extension CircleCIService {
    public struct PipelineRequest: Encodable {
        let branch: String
        let parameters: [String: Parameter]

        public enum Parameter: Encodable {
            case bool(Bool)
            case string(String)

            public func encode(to encoder: Encoder) throws {
                var values = encoder.singleValueContainer()
                switch self {
                case let .bool(value):
                    try values.encode(value)
                case let .string(value):
                    try values.encode(value)
                }
            }
        }
    }

    public struct PipelineResponse: Content {
        public let branch: String
        public let buildURL: URL
    }

    struct PipelineID: Content {
        let id: String
    }

    struct Pipeline: Content {
        let vcs: VCS

        struct VCS: Content {
            let branch: String
        }
    }

    struct PipelineWorkflows: Content {
        let items: [Workflow]

        struct Workflow: Content {
            let id: String
        }
    }

    private func pipelineURL(project: String) -> URL {
        URL(
            string: "/api/v2/project/github/\(project)/pipeline?circle-token=\(token)",
            relativeTo: baseURL
        )!
    }

    private func pipelineURL(pipelineID: String) -> URL {
        URL(
            string: "/api/v2/pipeline/\(pipelineID)?circle-token=\(token)",
            relativeTo: baseURL
        )!
    }

    private func pipelineWorkflowsURL(pipelineID: String) -> URL {
        URL(
            string: "/api/v2/pipeline/\(pipelineID)/workflow?circle-token=\(token)",
            relativeTo: baseURL
        )!
    }

    private func workflowURL(workflowID: String) -> URL {
        URL(
            string: "/workflow-run/\(workflowID)",
            relativeTo: baseURL
        )!
    }

    public func pipeline(
        parameters: [String: PipelineRequest.Parameter],
        project: String,
        branch: String,
        on request: Request
    ) throws -> EventLoopFuture<PipelineResponse> {
        let url = URI(string: pipelineURL(project: project).absoluteString)

        return try request.client.post(url, headers: headers) {
            try $0.content.encode(
                PipelineRequest(branch: branch, parameters: parameters),
                using: JSONEncoder()
            )
        }
        .catchError(.capture())
        .flatMapThrowing {
            try $0.content.decode(PipelineID.self)
        }.flatMapThrowing { (pipelineID: PipelineID) -> EventLoopFuture<(Pipeline, PipelineWorkflows)> in
            // workflows are not created immediately so we wait a bit
            // hoping that when we request pipeline the workflow id will be there
            sleep(5)
            return try request.client.get(
                URI(string: self.pipelineURL(pipelineID: pipelineID.id).absoluteString),
                headers: self.headers
            )
            .catchError(.capture())
            .and(
                try request.client.get(
                    URI(string: self.pipelineWorkflowsURL(pipelineID: pipelineID.id).absoluteString),
                    headers: self.headers
                )
                .catchError(.capture())
            ).flatMapThrowing { (pipelineResponse, pipelineWorkflowsResponse) in
                (try pipelineResponse.content.decode(Pipeline.self),
                 try pipelineWorkflowsResponse.content.decode(PipelineWorkflows.self))
            }
        }.flatMap { future in
            future.map { (pipeline, workflows) -> PipelineResponse in
                PipelineResponse(
                    branch: pipeline.vcs.branch,
                    buildURL: workflows.items.first.map {
                        self.workflowURL(workflowID: $0.id).absoluteURL
                    } ?? self.baseURL
                )
            }
        }
    }
}
