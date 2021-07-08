import Vapor
import Stevenson

extension SlackCommand {
    static let crp = { (jira: JiraService, github: GitHubService) in
        SlackCommand(
            name: "crp",
            help: """
            Creates a ticket on the CRP board from specified release branch.

            Parameters:
            - project identifier (e.g: `ios`, `android`)
            - `branch`: release branch name (typically `release/<app>/<version>`, e.g. `release/babylon/4.1.0`)

            Example:
            `/crp ios \(Option.branch.value):release/babylon/4.1.0`
            """,
            allowedChannels: ["ios-launchpad"],
            run: { metadata, request in
                guard let repo = metadata.textComponents.first else {
                    throw SlackService.Error.missingParameter(key: Option.repo.value)
                }

                guard let repoMapping = RepoMapping.all[repo.lowercased()] else {
                    throw SlackService.Error.invalidParameter(
                        key: Option.repo.value,
                        value: String(repo),
                        expected: RepoMapping.all.keys.joined(separator: "|")
                    )
                }

                guard let branch = metadata.value(forOption: .branch) else {
                    throw SlackService.Error.missingParameter(key: Option.branch.value)
                }

                let release = try GitHubService.Release(
                    repo: repoMapping.repository,
                    branch: branch
                )

                return try github.changelog(for: release, on: request)
                    .catchError(.capture())
                    .flatMap { (commitMessages: [String]) -> EventLoopFuture<(JiraService.CreatedIssue, JiraService.FixVersionReport)> in
                        do {
                            return try jira.executeCRPTicketProcess(
                                commitMessages: commitMessages,
                                release: release,
                                repoMapping: repoMapping,
                                crpProjectID: JiraService.crpProjectID,
                                request: request
                            )
                        } catch {
                            return request.eventLoop.makeFailedFuture(error)
                        }
                    }
                    .catchError(.capture())
                    .map { (crpIssue, report) -> SlackService.Response in
                        let status = report.statusText(releaseName: repoMapping.crp.jiraVersionName(release))

                        return SlackService.Response("""
                            ✅ CRP Ticket \(crpIssue.key) created.
                            \(jira.baseURL)/browse/\(crpIssue.key)
                            \(status)
                            """,
                            attachments: report.asSlackAttachments(),
                            visibility: .channel
                        )
                    }
                    .replyLater(
                        withImmediateResponse: SlackService.Response("🎫 Creating ticket...", visibility: .channel),
                        responseURL: metadata.responseURL,
                        on: request
                    )
            }
        )
    }
}
