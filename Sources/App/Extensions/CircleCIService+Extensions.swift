import Vapor
import Stevenson

extension CircleCIService {
    func runPipeline(
        textComponents: [String.SubSequence],
        branch: String,
        project: String,
        on request: Request
    ) throws -> EventLoopFuture<PipelineResponse> {
        let pipeline = String(textComponents[0])
        let optionsKeysValues = textComponents.dropFirst()
            .compactMap { (component: String.SubSequence) -> (String, CircleCIService.PipelineRequest.Parameter)? in
                let components = component.split(separator: ":")
                if components.count == 1 {
                    return (String(components[0]), .bool(true))
                } else if components.count == 2 {
                    return (String(components[0]), .string(String(components[1])))
                } else {
                    return nil
                }
        }
        var parameters = Dictionary(optionsKeysValues, uniquingKeysWith: { $1 })
        parameters["push"] = .bool(false)
        parameters[pipeline] = .bool(true)
        // branch parameter is not needed in parameters and actually results in unexpected parameter error
        parameters["branch"] = nil

        return try self.pipeline(
            parameters: parameters,
            project: project,
            branch: branch,
            on: request
        )
    }

    func runLane(
        textComponents: [String.SubSequence],
        branch: String,
        project: String,
        on request: Request
    ) throws -> EventLoopFuture<PipelineResponse> {
        let lane = String(textComponents[0])
        let options = textComponents.dropFirst().joined(separator: " ")

        let parameters: [String: CircleCIService.PipelineRequest.Parameter] = [
            "push": .bool(false),
            "lane": .string(lane),
            "options": .string(options)
        ]
        return try self.pipeline(
            parameters: parameters,
            project: project,
            branch: branch,
            on: request
        )
    }
}
