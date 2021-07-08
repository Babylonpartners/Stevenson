import Vapor
import Stevenson

// Use https://babylonpartners.atlassian.net/rest/api/3/project/<ProjectKey> to get the corresponding ID
private let jiraProjects = [
    "ACP"   : 17420, // Assistant Chat Platform
    "AND"   : 13700, // Android Engineering
    "ANDRP" : 17264, // Android Platform
    "APPTS" : 16875, // Booking/Appointments
    "AV"    : 16942, // Onboarding and Navigation (ex Core Experience / Avalon)
    "AVC"   : 16852, // Audio Video Call (formerly Multimedia "MUL" project)
    "CE"    : 16937, // Consultation Experience
    "CNSMR" : 16968, // Consumer Apps (Native/Core)
    "COCO"  : 17344, // Continuous Compliance
    "COREUS": 17127, // Babylon US Core Product
    "COVIDBUGS": 17459, // COVID-19 hotfix bugs
    "CW"    : 16832, // Consumer Web
    "EXPCORE"   : 17372, // Experience Tribe - Core Apps
    "GAA"   : 17581,  // Global Aftercare & Actions
    "GW"    : 16949, // Triage UI
    "HC"    : 17251, // HealthCheck (next-gen)
    "HCS"   : 17373, // HealthCheck Backend Support (next-gen)
    "IDP"   : 17228, // Identity Access Management
    "IOSP"  : 17263, // iOS Native Apps Platform
    "LANG"  : 17168, // Language Services
    "MC"    : 17006, // Member Communications (next-gen)
    "MERC"  : 17568, // Mercury Team
    "MP"    : 17494, // Monitor Product
    "MS"    : 17233, // Monitor
    "MON"   : 10103, // HealthCheck
    "NRX"   : 16911, // GP@Hand Registrations (ex Enrolment and Integrity)
    "PAR"   : 17098, // Partnerships
    "PAYE"  : 17510, // Payments & Eligibility
    "PDT"   : 17501, // Partner Development
    "PRO"   : 16980, // Professional Services
    "PRSCR" : 16840, // Prescriptions
    "REFER" : 17244, // Referrals (next-gen)
    "RM"    : 17403,  // Real-Time Matching
    "SA"    : 17439, // SaaS App
    "SDK"   : 16975, // SDK
    "SDKS"  : 17288, // SDK UI (next-gen)
    "TASS"  : 17331, // The Assistant
    "TC"    : 17353, // Triage Comprehension (next-gen)
    "TCN"   : 17431, // Triage comprehension (new)
    "TEL"   : 16857, // Telus
    "TK"    : 17299, // Test Kits
    "TM"    : 17343, // Triage Metrics (next-gen)
    "UNDANDINF"   : 17335, // Understand and Inform (next-gen)
    "USD"   : 17512, // US Agile Delivery
    "WH"    : 17112, // Women's Health
]

/// Called before your application initializes.
public func configure(_ app: Application) throws {
    app.slack = .init(
        verificationToken: try attempt { Environment.slackToken },
        oauthToken: try attempt { Environment.slackOAuthToken }
    )

    app.ci = .init(token: try attempt { Environment.circleciToken })

    app.jira = .init(
        baseURL: try attempt { Environment.jiraBaseURL.flatMap(URL.init(string:)) },
        username: try attempt { Environment.jiraUsername },
        password: try attempt { Environment.jiraToken },
        knownProjects: jiraProjects,
        logger: app.logger
    )

    app.github = .init(
        username: try attempt { Environment.githubUsername },
        token: try attempt { Environment.githubToken }
    )

    guard app.slack != nil,
          let ci = app.ci,
          let jira = app.jira,
          let github = app.github else {
        fatalError("Services are not set up")
    }

    try routes(
        app,
        commands: [
            .stevenson(ci, jira, github),
            .fastlane(ci),
            .appcenter(ci),
            .testflight(ci),
            .crp(jira, github)
        ]
    )
}

extension Environment {
    /// Verification Token (see SlackBot App settings)
    static let slackToken       = Environment.get("SLACK_TOKEN")
    /// Bot User OAuth Access Token (see SlackBot App settings)
    static let slackOAuthToken  = Environment.get("SLACK_OAUTH_TOKEN")
    /// GitHub Bot Username
    static let githubUsername   = Environment.get("GITHUB_USERNAME")
    /// GitHub Bot Access Token
    static let githubToken      = Environment.get("GITHUB_TOKEN")
    /// CircleCI Access Token
    static let circleciToken    = Environment.get("CIRCLECI_TOKEN")
    /// JIRA Base URL, e.g. "https://yourorg.atlassian.net"
    static let jiraBaseURL      = Environment.get("JIRA_BASEURL")
    /// JIRA Bot Username
    static let jiraUsername     = Environment.get("JIRA_USERNAME")
    /// JIRA Bot Access Token
    static let jiraToken        = Environment.get("JIRA_TOKEN")
}
