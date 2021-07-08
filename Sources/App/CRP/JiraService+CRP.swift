import Vapor
import Stevenson

/**
 For detailed documentation of this part of the code, see: [Implementation Details documentation in private repo](https://github.com/babylonhealth/babylon-ios/blob/develop/Documentation/Process/Release%20process/CRP-Bot-ImplementationDetails.md#executing-the-crp-process)
*/

// MARK: Constants

// [CNSMR-1319] TODO: Use a config file to parametrise those
extension JiraService.FieldType.User  {
      // To find the accountId to use here, open https://babylonpartners.atlassian.net/rest/api/3/user?username=<name> in your browser
      // or just type their name with `@` (mention) anywhere in JIRA ticket for editor to autocomplete it and replace with user id
      static let DejiOgunkoya = JiraService.FieldType.User(accountId: "557058:b1825fd3-4819-4150-9cfd-ea5292b21bb3")
      static let MarkBates = JiraService.FieldType.User(accountId: "5d77d4701e81950d2d821307")
}

extension JiraService {
    /// Official CRP Board
    static let crpProjectID = FieldType.ObjectID(id: "13402")

    static func accountablePerson(release: GitHubService.Release) -> FieldType.User {
        let isTelus = release.appName.caseInsensitiveCompare("Telus") == .orderedSame
        let isUS = release.appName.caseInsensitiveCompare("BabylonUS") == .orderedSame
        return isTelus ? .DejiOgunkoya : isUS ? .MarkBates : .MarkBates
    }

    /// Estimate time between when the CRP ticket is created and the app is released to the AppStore
    static let releaseEstimateDuration = DateComponents(day: 7)
}

// MARK: - CRP Ticket Dance

extension JiraService {
    static func makeCRPIssue(
        jiraBaseURL: URL,
        crpProjectID: JiraService.FieldType.ObjectID,
        crpConfig: RepoMapping.CRP,
        release: GitHubService.Release,
        changelog: FieldType.TextArea.Document,
        targetDate: Date? = nil // will use `guessTargetDate()` if nil
    ) -> CRPIssue {
        let accountablePerson = JiraService.accountablePerson(release: release)
        let changelog = changelog
        let fields = CRPIssueFields(
            jiraBaseURL: jiraBaseURL,
            crpProjectID: crpProjectID,
            summary: crpConfig.jiraSummary(release),
            environments: crpConfig.environment,
            release: release,
            releaseType: .init(version: release.version),
            targetDate: targetDate ?? guessTargetDate(),
            changelog: changelog,
            accountablePerson: accountablePerson
        )
        return CRPIssue(fields: fields)
    }

    private static func guessTargetDate() -> Date {
        let now = Date()
        let estimateOffset = JiraService.releaseEstimateDuration
        return Calendar(identifier: .gregorian).date(byAdding: estimateOffset, to: now) ?? now
    }
}

extension JiraService {
    /// Do the CRP ticket dance, which consists of:
    ///  - creating the CRP ticket from list of commits,
    ///  - then create all the JIRA versions on each boards,
    ///  - then for each board, set the Fix Version field for each ticket concerned by the CRP for that board's JIRA version
    internal func executeCRPTicketProcess(
        commitMessages: [String],
        release: GitHubService.Release,
        repoMapping: RepoMapping,
        crpProjectID: JiraService.FieldType.ObjectID,
        request: Request
    ) throws -> EventLoopFuture<(JiraService.CreatedIssue, JiraService.FixVersionReport)> {
        let jiraVersionName = repoMapping.crp.jiraVersionName(release)
        let changelogSections = ChangelogSection.makeSections(from: commitMessages, for: release)

        // Create CRP Issue
        let crpIssue = JiraService.makeCRPIssue(
            jiraBaseURL: self.baseURL,
            crpProjectID: crpProjectID,
            crpConfig: repoMapping.crp,
            release: release,
            changelog: self.document(from: changelogSections)
        )

        return try self.create(issue: crpIssue, on: request)
            .catchError(.capture())
            .flatMap { (crpIssue: JiraService.CreatedIssue) -> EventLoopFuture<(JiraService.CreatedIssue, JiraService.FixVersionReport)> in
                // Create JIRA versions on each board then set Fixed Versions to that new version on each board's ticket included in Changelog
                do {
                    return try self.createAndSetFixVersions(
                        changelogSections: changelogSections,
                        versionName: jiraVersionName,
                        on: request
                    ).map { (crpIssue, $0) }
                } catch {
                    return request.eventLoop.makeFailedFuture(error)
                }
            }
    }
}

// MARK: - Define the CRP Issue type

extension JiraService {

    /// A CRPIssue is a Jira issue specific to our CRP Board (aka Releases Plan Board)
    /// CRP means "Change Request Process" and is part of our SSDLC to track upcoming releases
    typealias CRPIssue = Issue<CRPIssueFields>

    struct CRPIssueFields: JiraIssueFields {

        // MARK: Custom Field Types specific to CRP board

        struct Environment: Content {
            let id: String
            static let playStore = Environment(id: "12394")
            static let appStore = Environment(id: "12395")
            static let notApplicable = Environment(id: "12396")
        }

        struct ReleaseType: Content {
            let id: String
            static let major = ReleaseType(id: "12651")
            static let minor = ReleaseType(id: "12652")
            static let patch = ReleaseType(id: "12653")
        }

        struct InfoSecStatus: Content {
            let id: String
            static let yes = InfoSecStatus(id: "11942")
            static let no = InfoSecStatus(id: "11941")
        }

        struct ClinicalApprovalType: Content {
            let id: String
            static let approved = ClinicalApprovalType(id: "12568")
            static let unapproved = ClinicalApprovalType(id: "12566")
            static let notRequired = ClinicalApprovalType(id: "12567")
        }

        struct RegulatoryApprovalType: Content {
            let id: String
            static let approved = RegulatoryApprovalType(id: "12571")
            static let unapproved = RegulatoryApprovalType(id: "12569")
            static let notRequired = RegulatoryApprovalType(id: "12570")
        }

        struct MaintenanceWindowRequirment: Content {
            let id: String
            static let notRequired = MaintenanceWindowRequirment(id: "14050")
            static let required = MaintenanceWindowRequirment(id: "14051")
        }

        struct AccountableDept: Content {
            let id: String
            static let mobileChapter = AccountableDept(id: "13998")
        }

        // MARK: Fields

        var project: FieldType.ObjectID
        var issueType = FieldType.ObjectID(id: "11439") // "CRP: Code Change Request"
        var summary: String
        var changelog: FieldType.TextArea.Document
        var environments: [Environment]
        var releaseType: ReleaseType
        @CustomCodable<YMDDate>
        var targetDate: Date
        var changeScope: FieldType.TextArea.Document
        let jiraReleaseURL: String
        let githubReleaseURL: String
        var testing: FieldType.TextArea.Document
        var accountablePerson: FieldType.User
        var infoSecChecked: InfoSecStatus
        var serviceChanges: FieldType.TextArea.Document
        var clinicalApproval: ClinicalApprovalType
        var regulatoryApproval: RegulatoryApprovalType
        let rollbackPlan = FieldType.TextArea.Document(text: rollbackMessage)
        let maintenanceWindow = MaintenanceWindowRequirment.notRequired
        let accountableDept = AccountableDept.mobileChapter

        // MARK: Content keys

        enum CodingKeys: String, CodingKey {
            case project = "project"                      // required
            case issueType = "issuetype"                  // required
            case summary = "summary"                      // required
            case changelog = "customfield_12537"          // required
            case environments = "customfield_12592"       // required
            case releaseType = "customfield_12794"        // required
            case targetDate = "customfield_11514"         // required
            case changeScope = "customfield_12538"        // required
            case jiraReleaseURL = "customfield_12540"     // optional
            case githubReleaseURL = "customfield_12541"   // optional
            case testing = "customfield_11512"            // required
            case accountablePerson = "customfield_11505"  // required
            case infoSecChecked = "customfield_12527"     // required
            case serviceChanges = "customfield_13350"     // required
            case clinicalApproval = "customfield_12762"   // required
            case regulatoryApproval = "customfield_12763" // required
            case rollbackPlan = "customfield_13434"       // required
            case maintenanceWindow = "customfield_13435"  // required
            case accountableDept = "customfield_13428"    // required
        }

        // MARK: Inits

        init(
            jiraBaseURL: URL,
            crpProjectID: FieldType.ObjectID,
            summary: String,
            environments: [Environment],
            release: GitHubService.Release,
            releaseType: ReleaseType,
            targetDate: Date,
            changelog: FieldType.TextArea.Document,
            accountablePerson: FieldType.User
        ) {
            self.project = crpProjectID
            self.summary = summary
            self.changelog = changelog
            self.environments = environments
            self.releaseType = releaseType
            self.targetDate = targetDate
            self.changeScope = FieldType.TextArea.Document(text: "The headlines for the release are: \r\nThere are a number of tickets from the Changelog that are yet to be moved to a completed status or resolution in their respective workflow. Each of these have been reviewed and commented on with why they do not impact the release, yet are in the codebase. These tickets are:")
            self.jiraReleaseURL = "\(jiraBaseURL)/secure/Dashboard.jspa?selectPageId=15452"
            self.githubReleaseURL = "https://github.com/\(release.repository.fullName)/releases/tag/\(release.appName)/\(release.version)"

            let testingContent = "Android & iOS native mobile apps PED Test Plan - https://docs.google.com/document/d/1GlvBD7DL0B24WOdky_sCJp3bewmwuHHkYfYcrPWDQEI/edit#heading=h.1jdzrbj14q2r \r\nTestRail milestone (automated & manual test runs) -\r\nCI branch pipeline (automated unit tests and build) - \r\nInternal release notes/QA sign-off -"
            self.testing = FieldType.TextArea.Document(text: testingContent)
            self.accountablePerson = accountablePerson
            self.infoSecChecked = .no
            self.serviceChanges = FieldType.TextArea.Document(text: "Product Changes:")
            self.clinicalApproval = .unapproved
            self.regulatoryApproval = .unapproved
        }
    }
}

extension JiraService.CRPIssueFields.ReleaseType {
    init(version: String) {
        // Ensure we're only considering x.y.z version formats (ignoring potential suffix "-rc" or similar)
        let endIndex = version.firstIndex { !"0123456789.".contains($0) } ?? version.endIndex
        let comps = version[..<endIndex].split(separator: ".")
        let minor = comps.count > 1 ? comps[1] : "0"
        let patch = comps.count > 2 ? comps[2] : "0"
        if comps.count > 3 {
            // if we have more than 3 digits, assume it's always a patch release
            self = .patch
        } else if minor == "0" && patch == "0" {
            self = .major
        } else if patch == "0" {
            self = .minor
        } else {
            self = .patch
        }
    }
}

// MARK: Create JIRA Documents

extension JiraService {
    func document(from changelog: [ChangelogSection]) -> FieldType.TextArea.Document {
        return JiraService.document(from: changelog, jiraBaseURL: self.baseURL)
    }

    /// Transform a list of ChangelogSection into a 'Document' field for the JIRA API
    ///
    /// - Parameter changelog: The list of sections to format
    /// - Returns: The Jira Document structure ready to be inserted in a JIRA TextArea field
    static func document(from changelog: [ChangelogSection], jiraBaseURL: URL) -> FieldType.TextArea.Document {
        // Transform CHANGELOG entries into JIRA Document field
        typealias DocContent = FieldType.TextArea.DocContent

        let content = changelog
            .flatMap { (section: ChangelogSection) -> [DocContent] in
                let header = section.board.map { "\($0) tickets" } ?? "Other"
                let listItems = section.commits.map {
                    formatMessageLine($0.message, jiraBaseURL: jiraBaseURL)
                }

                return [
                    DocContent.heading(level: 3, title: header),
                    DocContent.bulletList(items: listItems)
                ]
        }
        return FieldType.TextArea.Document(content: content)
    }

    /// Extract tickets from a commit message to create a mix of `.text` and `.inlineCard` content
    ///
    /// - Parameter string: The commit message / string to extract tickets from
    /// - Returns: An array of `.text` and `.inlineCard` elements corresponding to the parsed string
    static func formatMessageLine(_ string: String, jiraBaseURL: URL) -> FieldType.TextArea.ListItem {
        let fullRange = NSRange(string.startIndex..<string.endIndex, in: string)
        let matches = TicketID.regex.matches(in: string, options: [], range: fullRange)

        var result: [FieldType.TextArea.DocContent] = []
        var lastIndex = string.startIndex
        for match in matches {
            guard
                let matchRange = Range(match.range(at: 0), in: string),
                let ticketRange = Range(match.range(at: 1), in: string)
                else { continue }

            let beforeText = String(string[lastIndex..<matchRange.lowerBound])
            if !beforeText.isEmpty {
                result.append(.text(beforeText))
            }
            let ticketText = String(string[ticketRange])
            result.append(.inlineCard(baseURL: jiraBaseURL, ticketKey: ticketText))
            lastIndex = matchRange.upperBound
        }
        let endText = String(string[lastIndex..<string.endIndex])
        if !endText.isEmpty {
            result.append(.text(endText))
        }
        return .init(content: result)
    }
}

// MARK: Support for "Fixed Version"

extension JiraService {
    /// Used to report non-fatal errors without failing the Future chain
    struct FixVersionReport: CustomStringConvertible {
        enum Error: Swift.Error {
            case notInWhitelist(project: String)
            case releaseCreationFailed(project: String, error: Swift.Error)
            case updateFixVersionFailed(ticket: String, url: String, error: Swift.Error)
        }
        let errors: [FixVersionReport.Error]

        init(_ error: FixVersionReport.Error) {
            self.errors = [error]
        }
        init(reports: [FixVersionReport] = []) {
            self.errors = reports.flatMap { $0.errors }
        }

        var description: String {
            errors
                .map { " • \($0.description)" }
                .joined(separator: "\n")
        }
    }

    func createAndSetFixVersions(
        changelogSections: [ChangelogSection],
        versionName: String,
        on request: Request
    ) throws -> EventLoopFuture<FixVersionReport> {
        try changelogSections
            .compactMap { $0.tickets() }
            .compactMap { (key: String, tickets: [String]) -> EventLoopFuture<FixVersionReport> in
                guard let projectID = self.knownProjects[key] else {
                    return request.eventLoop.future(
                        FixVersionReport(.notInWhitelist(project: key))
                    )
                }

                return try self.getVersions(project: projectID, on: request)
                    .flatMap { allVersions -> EventLoopFuture<Version> in
                        if let existingVersion = allVersions.first(where: { $0.name == versionName }) {
                            return request.eventLoop.future(existingVersion)
                        } else {
                            let version = JiraService.Version(
                                projectId: projectID,
                                name: versionName,
                                description: versionName,
                                startDate: Date()
                            )
                            do {
                                return try self.createVersion(version, on: request)
                            } catch {
                                return request.eventLoop.makeFailedFuture(error)
                            }
                        }
                    }
                    .flatMap { version in
                        self.batchSetFixVersions(version, tickets: tickets, on: request)
                    }.recover { error in
                        FixVersionReport(.releaseCreationFailed(project: key, error: error))
                    }
            }
            .flatten(on: request.eventLoop)
            .map(FixVersionReport.init(reports:)) // collect an array of reports into a single one
    }

    func batchSetFixVersions(
        _ version: JiraService.Version,
        tickets: [String],
        on request: Request
    ) -> EventLoopFuture<FixVersionReport> {
        tickets
            .map { (ticket: String) -> EventLoopFuture<FixVersionReport> in
                do {
                    return try self.setFixVersion(version, for: ticket, on: request)
                        .map { _ in FixVersionReport() }
                } catch {
                    let url = self.browseURL(issue: ticket)
                    let failure = FixVersionReport(.updateFixVersionFailed(ticket: ticket, url: url, error: error))
                    return request.eventLoop.makeSucceededFuture(failure)
                }
            }
            .flatten(on: request.eventLoop)
            .map(FixVersionReport.init(reports:)) // collect an array of reports into a single one
    }
}

// MARK: Nice report descriptions

extension JiraService.FixVersionReport {
    func statusText(releaseName: String) -> String {
        if errors.isEmpty {
            return """
                ✅ Successfully added "\(releaseName)" in the "Fix Version" field of all tickets
                """
        } else {
            return """
                ❌ Some errors occurred when trying to add "\(releaseName)" in the "Fix Version" field of some tickets.
                Please double-check those tickets; you might need to update some of them manually.
                """
        }
    }
}

extension JiraService.FixVersionReport.Error: CustomStringConvertible {
    var description: String {
        switch self {
        case let .notInWhitelist(project):
            return "Project `\(project)` is not part of our whitelist for creating JIRA versions"
        case let .releaseCreationFailed(project, error):
            return "Error creating JIRA release in board `\(project)` – \(error.betterLocalizedDescription)"
        case let .updateFixVersionFailed(ticket, url, error):
            return "Error setting Fix Version field for <\(url)|\(ticket)> – \(error.betterLocalizedDescription)"
        }
    }
}

extension Error {
    /// Just a nicer translation for some common URLErrors instead of the generic "The operation could not be completed. (NSURLErrorDomain error N.)"
    var betterLocalizedDescription: String {
        guard let error = self as? URLError else { return self.localizedDescription }
        let message: String? = {
            switch error.code {
            case .timedOut: return "Request timed out"
            case .cannotFindHost: return "Cannot find host"
            case .cannotConnectToHost: return "Cannot connect to host"
            case .networkConnectionLost: return "Network connection lost"
            case .notConnectedToInternet: return "Not connected to internet"
            default: return nil
            }
        }()
        return message.map({ "\($0) (\(error.code.rawValue))" }) ?? error.localizedDescription
    }
}


fileprivate let rollbackMessage = """
None.
This is not an option with respect to mobile app releases, the mobile OS does not allow downgrades to previous versions/revert updates. Due to this we have to fix-forward by means of hotfix.
"""
