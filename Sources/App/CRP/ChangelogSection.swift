import Foundation
import Stevenson

struct ChangelogSection {
    let board: String?
    let commits: [(message: String, ticket: JiraService.TicketID?)]

    /// Filters the CHANGELOG entries then orders and formats the CHANGELOG text
    ///
    /// - Parameters:
    ///   - commits: The list of commits gathered between last release and current one
    ///   - release: The release for which to build the CHANGELOG text for
    /// - Returns: The text containing the filtered and formatted CHANGELOG, grouped and ordered by jira board
    static func makeSections(from commits: [String], for release: GitHubService.Release) -> [ChangelogSection] {
        // Only keep SDK commits if release is for SDK
        let filteredMessages = release.isSDK ? commits.filter(hasSDKChanges) : commits
        let parsedMessages = filteredMessages.map { (message: $0, ticket: JiraService.TicketID(from: $0)) }

        // Group then sort the changes by JIRA boards (unclassified last)
        return Dictionary(grouping: parsedMessages) { $0.ticket?.board }
            .sorted { e1, e2 in e1.key ?? "ZZZ" < e2.key ?? "ZZZ" }
            .map(ChangelogSection.init)
    }

    private static func hasSDKChanges(message: String) -> Bool {
        message.contains("#SDK") || message.range(of: #"\bSDKS?-[0-9]+\b"#, options: .regularExpression) != nil
    }

    func tickets() -> (String, [String])? {
        guard let board = self.board else { return nil }
        let ticketKeys = commits.compactMap { $0.ticket?.key }
        return (board, ticketKeys)
    }
}
