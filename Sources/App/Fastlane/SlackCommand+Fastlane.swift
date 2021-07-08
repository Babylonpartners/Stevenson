import Foundation
import Vapor
import Stevenson

extension SlackCommand {
    static let fastlane = { (ci: CircleCIService) in
        SlackCommand(
            name: "fastlane",
            help: """
            Invokes specified lane on specified branch.
            Provide options the same way as when invoking lane locally.

            Parameters:
            - name of the lane to run
            - list of lane options in the fastlane format (e.g. `device:iPhone5s`)
            - `branch`: name of the branch to run the lane on. Default is `\(RepoMapping.ios.repository.baseBranch)`

            Example:
            `/fastlane test_babylon \(Option.branch.value):develop`
            """,
            allowedChannels: ["ios-build"],
            run: { metadata, request in
                try runLane(
                    metadata: metadata,
                    ci: ci,
                    on: request
                )
        })
    }

    static let testflight = { (ci: CircleCIService) in
        SlackCommand(
            name: "testflight",
            help: """
            Makes a new release candidate for Testflight. Shorthand for `/fastlane testflight`.

            Parameters:
            - name of the target (as in the project)
            - `version`: version of the app
            - `branch`: release branch name. Default is `release/<name.lowercase()>/<version>`

            Example:
            `/testflight Babylon \(Option.version.value):3.13.0`
            """,
            allowedChannels: ["ios-build"],
            run: { metadata, request in
                try runLane(
                    metadata: SlackCommandMetadata(
                        token: metadata.token,
                        channelName: metadata.channelName,
                        command: "/fastlane",
                        text: "testflight target:\(metadata.text)",
                        responseURL: metadata.responseURL
                    ),
                    branch: releaseBranchName(from: metadata),
                    ci: ci,
                    on: request
                )
        })
    }

    static let appcenter = { (ci: CircleCIService) in
        SlackCommand(
            name: "appcenter",
            help: """
            Makes a new beta build for AppCenter. Shorthand for `/fastlane appcenter`.

            Parameters:
            - name of the target (as in the project)
            - `branch`: name of the branch to run the lane on. Default is `\(RepoMapping.ios.repository.baseBranch)`

            Example:
            `/appcenter Babylon \(Option.branch.value):develop`
            """,
            allowedChannels: ["ios-build"],
            run: { metadata, request in
                try runLane(
                    metadata: SlackCommandMetadata(
                        token: metadata.token,
                        channelName: metadata.channelName,
                        command: "/fastlane",
                        text: "appcenter target:\(metadata.text)",
                        responseURL: metadata.responseURL
                    ),
                    ci: ci,
                    on: request
                )
        })
    }

    static func runPipeline(
        metadata: SlackCommandMetadata,
        branch: String? = nil,
        ci: CircleCIService,
        on request: Request
    ) throws -> EventLoopFuture<SlackService.Response> {
        let branch = branch
            ?? metadata.value(forOption: .branch)
            ?? RepoMapping.ios.repository.baseBranch

        let pipeline = try ci.runPipeline(
            textComponents: metadata.textComponents,
            branch: branch,
            project: RepoMapping.ios.repository.fullName,
            on: request
        )

        return respond(
            to: pipeline,
            metadata: metadata,
            on: request
        )
    }

    static func runLane(
        metadata: SlackCommandMetadata,
        branch: String? = nil,
        ci: CircleCIService,
        on request: Request
    ) throws -> EventLoopFuture<SlackService.Response> {
        let branch = branch
            ?? metadata.value(forOption: .branch)
            ?? RepoMapping.ios.repository.baseBranch

        let pipeline = try ci.runLane(
            textComponents: metadata.textComponents,
            branch: branch,
            project: RepoMapping.ios.repository.fullName,
            on: request
        )
        return respond(
            to: pipeline,
            metadata: metadata,
            on: request
        )
    }

    private static func respond(
        to pipeline: EventLoopFuture<CircleCIService.PipelineResponse>,
        metadata: SlackCommandMetadata,
        on request: Request
    ) -> EventLoopFuture<SlackService.Response> {
        pipeline
            .map {
                SlackService.Response("""
                    You asked me: `\(metadata.command) \(metadata.text)`.
                    🚀 Triggered `\(metadata.textComponents[0])` on the `\($0.branch)` branch.
                    \($0.buildURL)
                    """,
                    visibility: .channel
                )
            }
            .replyLater(
                withImmediateResponse: SlackService.Response(
                    "👍 (If you don't receive response with the link to the triggered CI job in a few seconds please check CI logs before repeating a command)",
                    visibility: .channel
                ),
                responseURL: metadata.responseURL,
                on: request
        )
    }

}

extension SlackCommand {
    private static func releaseBranchName(from metadata: SlackCommandMetadata) -> String? {
        if let branchOption = metadata.value(forOption: .branch) {
            return branchOption
        } else if let app = metadata.textComponents.first, let version = metadata.value(forOption: .version) {
            return  "release/\(app.lowercased())/\(version)"
        } else {
            return nil
        }
    }
}
