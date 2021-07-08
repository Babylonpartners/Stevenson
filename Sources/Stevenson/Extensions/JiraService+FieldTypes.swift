import Vapor

// MARK: Jira Common Field Types

extension JiraService {
    public enum FieldType {
        public enum TextArea {
            // See spec at: https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/

            public struct Document: Content {
                let type = "doc"
                let content: [DocContent]
                let version = 1
                public init(content: [DocContent]) {
                    self.content = content
                }
                public init(text: String) {
                    self.content = [DocContent.paragraph([.text(text)])]
                }
            }

            public struct DocContent: Content {
                let type: String
                let attrs: [String: AnyCodable]?
                let content: [DocContent]?
                let text: String?

                fileprivate init(type: String, attrs: [String: Any]? = nil, content: [DocContent]? = nil, text: String? = nil) {
                    self.type = type
                    self.attrs = attrs.map { $0.mapValues { AnyCodable($0) } }
                    self.content = content
                    self.text = text
                }

                public static func heading(level: Int, title: String) -> DocContent {
                    return DocContent(type: "heading", attrs: ["level": level], content: [.text(title)])
                }

                public static func bulletList(items: [ListItem]) -> DocContent {
                    return DocContent(type: "bulletList", content: items.map { $0.content })
                }

                public static func paragraph(_ content: [DocContent]) -> DocContent {
                    return DocContent(type: "paragraph", content: content)
                }

                public static func inlineCard(baseURL: URL, ticketKey: String) -> DocContent {
                    let url = "\(baseURL)/browse/\(ticketKey)#icft=\(ticketKey)"
                    return DocContent(type: "inlineCard", attrs: ["url": url], content: nil)
                }

                public static func text(_ text: String) -> DocContent {
                    return DocContent(type: "text", text: text)
                }

                public static func hardbreak() -> DocContent {
                    return DocContent(type: "hardBreak")
                }
            }

            public struct ListItem {
                let content: DocContent
                public init(content: [DocContent]) {
                    self.content = DocContent(
                        type: "listItem",
                        content: [DocContent.paragraph(content)]
                    )
                }
            }
        }

        public struct ObjectID: Content {
            let id: String
            public init(id: String) {
                self.id = id
            }
        }

        public struct User: Content {
            let accountId: String
            public init(accountId: String) {
                self.accountId = accountId
            }
        }
    }
}
