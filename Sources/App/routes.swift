import Vapor
import Stevenson

public func routes(
    _ app: Application,
    commands: [SlackCommand]
) throws {
    app.get { req in
        return "It works!"
    }

    app.post("github", "comment") { (request) -> EventLoopFuture<Response> in
        guard let github = app.github,
              let ci = app.ci else {
            fatalError("GitHub and CI are not set up")
        }
        return try github.issueComment(on: request, ci: ci)
    }

    app.post("api", "crp") { (request) -> EventLoopFuture<Response> in
        guard let github = app.github,
              let jira = app.jira,
              let slack = app.slack else {
            fatalError("GitHub, Jira, and Slack are not set up")
        }
        return try CRPProcess.apiRequest(
            request: request,
            github: github,
            jira: jira,
            slack: slack
        )
    }

    commands.forEach { command in
        app.post(PathComponent(stringLiteral: command.name)) { req -> EventLoopFuture<Response> in
            guard let slack = app.slack else {
                fatalError("Slack is not set up")
            }
            do {
                return try attempt {
                    try slack.handle(command: command, on: req)
                }
            } catch {
                return SlackService.Response(error: error).encodeResponse(for: req)
            }
        }
    }
}
