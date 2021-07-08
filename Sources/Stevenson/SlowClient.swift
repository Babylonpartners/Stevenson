/// Service to create a Slow / Rate-Limiting-Aware Client, especially useful for 3rd-party APIs that have quotas or can't handle too many requests in parallel
/// Borrowed from: https://gist.github.com/vzsg/3287030a9c9bdfc4aa726a5b0556e09e

// SlowMode
import Dispatch
import NIO
// SlowClient
import Vapor

private final class SlowMode<T, U> {
    private typealias Task = (T, EventLoopPromise<U>)
    private let work: (T) -> EventLoopFuture<U>
    private let verify: (U) -> (success: Bool, delay: Date?)
    private let queue = DispatchQueue(label: "SlowMode [\(T.self) -> \(U.self)]")
    private var deferredTasks: [Task] = []
    private var currentTask: Task?
    private var delayUntil: Date?

    init(work: @escaping (T) -> EventLoopFuture<U>, verify: @escaping (U) -> (Bool, Date?) = { _ in (true, nil) }) {
        self.work = work
        self.verify = verify
    }

    func process(_ input: T, on eventLoop: EventLoop) -> EventLoopFuture<U> {
        let promise = eventLoop.makePromise(of: U.self)
        queue.async { self.dispatch((input, promise)) }
        return promise.futureResult
    }

    private func dispatch(_ task: Task) {
        let currentDate = Date()

        if currentTask != nil {
            // busy with another task -> enqueue
            deferredTasks.insert(task, at: 0)
            return
        }

        if let delayUntil = self.delayUntil, delayUntil > currentDate {
            // previous task requested delay which has not expired yet -> wait until expiration
            currentTask = task
            queue.asyncAfter(deadline: .now() + delayUntil.timeIntervalSince(currentDate)) {
                self.start(task)
            }

            return
        }

        // no running task, nor delay -> start request immediately
        currentTask = task
        start(task)
    }

    private func start(_ task: Task) {
        let (input, promise) = task

        let result = work(input)

        result.whenSuccess { result in
            let (success, delayUntil) = self.verify(result)

            self.queue.async {
                if success {
                    self.delayUntil = delayUntil
                    promise.succeed(result)
                } else {
                    // try again
                    self.deferredTasks.append(task)
                }

                self.dispatchNext()
            }
        }

        result.whenFailure { error in
            promise.fail(error)

            self.queue.async {
                self.dispatchNext()
            }
        }
    }

    private func dispatchNext() {
        currentTask = nil

        if let nextTask = deferredTasks.popLast() {
            dispatch(nextTask)
        }
    }
}

// MARK: SlowClient

extension Request {
    // Some services (like JIRA) might need a slower client which handles rate-limiting APIs and quotas
    var slowClient: SlowClient {
        .init(client: self.client)
    }
}

public final class SlowClient {
    private let slowMode: SlowMode<Request, Response>
    let client: Client

    public init(client: Client) {
        self.client = client
        self.slowMode = SlowMode(
            work: { (req: Request) -> EventLoopFuture<Response> in
                let clientRequest = ClientRequest(
                    method: req.method,
                    url: req.url,
                    headers: req.headers,
                    body: req.body.data
                )

                return client
                    .send(clientRequest)
                    .encodeResponse(for: req)
            },
            verify: { (response: Response) -> (Bool, Date?) in
                guard response.status.code == 429 else {
                    return (true, nil)
                }

                let delayUntil: Date

                if let resetHeader = response.headers["X-RateLimit-Reset"].first,
                   let resetTime = TimeInterval(resetHeader) {
                    delayUntil = Date(timeIntervalSince1970: resetTime)
                } else {
                    delayUntil = Date(timeIntervalSinceNow: 1)
                }

                return (false, delayUntil)
            }
        )
    }

    func send(_ request: Request) -> EventLoopFuture<Response> {
        slowMode.process(request, on: request.eventLoop)
    }
}

extension SlowClient {
    func get(_ url: URI, headers: HTTPHeaders = [:], on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        send(.GET, headers: headers, to: url, on: application, beforeSend: beforeSend)
    }

    func post(_ url: URI, headers: HTTPHeaders = [:], on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        send(.POST, headers: headers, to: url, on: application, beforeSend: beforeSend)
    }

    func patch(_ url: URI, headers: HTTPHeaders = [:], on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        send(.PATCH, headers: headers, to: url, on: application, beforeSend: beforeSend)
    }

    func put(_ url: URI, headers: HTTPHeaders = [:], on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        send(.PUT, headers: headers, to: url, on: application, beforeSend: beforeSend)
    }

    func delete(_ url: URI, headers: HTTPHeaders = [:], on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        send(.DELETE, headers: headers, to: url, on: application, beforeSend: beforeSend)
    }

    func send(_ method: HTTPMethod, headers: HTTPHeaders = [:], to url: URI, on application: Application, beforeSend: (Request) throws -> () = { _ in }) -> EventLoopFuture<Response> {
        do {
            let req = Request(
                application: application,
                method: method,
                url: url,
                on: application.client.eventLoop
            )
            try beforeSend(req)
            return send(req)
        } catch {
            return application.client.eventLoop.makeFailedFuture(error)
        }
    }
}
