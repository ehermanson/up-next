import Foundation

// Compile alongside the production service; no app target or live credential required.
final class MockJev: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var count = 0
    static var sizes: [Int] = []
    static var names: [String] = []
    static var fail = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    body.append(contentsOf: buffer.prefix(n))
                }
            }
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let state = payload["state"] as! [String: Any]
            let candidates = state["candidates"] as! [[String: Any]]
            let questions = payload["questions"] as! [String: Any]
            Self.lock.lock()
            Self.count += 1
            Self.sizes.append(candidates.count)
            Self.names.append(state["collection_name"] as! String)
            let fail = Self.fail
            Self.lock.unlock()
            var answers: [String: Any] = [:]
            for key in questions.keys {
                let maxScore = key.hasPrefix("fit_") ? 3 : 2
                let id = Int(key.split(separator: "_").last!)!
                let score = id == 2 ? maxScore : 0
                answers[key] = ["type": "score", "score": score, "confidence": 1,
                                "probabilities": Dictionary(uniqueKeysWithValues:
                                    (0...maxScore).map { (String($0), $0 == score ? 1 : 0) })]
            }
            if fail { answers.removeAll() }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": JevRecommendationService.model, "answers": answers
            ])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    static func snapshot() -> (Int, [Int], [String]) {
        lock.lock(); defer { lock.unlock() }
        return (count, sizes, names)
    }
    static func setFailure() { lock.lock(); fail = true; lock.unlock() }
}

@main struct RuntimeChecks {
    static func title(_ id: Int) -> JevTitle {
        JevTitle(id: id, title: "Title \(id)", year: "2004", overview: "Comedy",
                 genres: ["Comedy"], mediaType: "movie")
    }
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockJev.self]
        let session = URLSession(configuration: config)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let empty = JevRecommendationService(apiKey: "", session: session, cacheURL: nil)
        let missing = await empty.rank(name: "Xmas", members: [], candidates: [title(1)])
        precondition(missing == nil && MockJev.snapshot().0 == 0, "Missing key must skip HTTP")
        let service = JevRecommendationService(apiKey: "test-key", session: session, cacheURL: cache)
        let candidates = (1...13).map(title)
        let name = "  Stupid comedies & Xmas!?  "
        async let first = service.rank(name: name, members: [title(99)], candidates: candidates)
        async let second = service.rank(name: name, members: [title(99)], candidates: candidates)
        let (a, b) = await (first, second)
        precondition(a == [2, 1] + Array(3...13) && a == b, "Score ordering and stable ties")
        precondition(MockJev.snapshot().0 == 3, "Concurrent calls must share requests")
        precondition(MockJev.snapshot().1.sorted() == [1, 6, 6], "Bounded batches")
        precondition(MockJev.snapshot().2.allSatisfy { $0 == name }, "Names must remain verbatim")
        let restored = JevRecommendationService(apiKey: "test-key", session: session, cacheURL: cache)
        let cached = await restored.rank(name: name, members: [title(99)], candidates: candidates)
        precondition(cached == a && MockJev.snapshot().0 == 3, "Disk cache must avoid new requests")
        let stored = try String(contentsOf: cache, encoding: .utf8)
        precondition(!stored.contains(name) && !stored.contains("test-key"), "Cache holds hashes and scores only")
        let noMembers = await service.rank(name: "Empty", members: [], candidates: [title(1), title(2)])
        precondition(noMembers == [2, 1], "Empty collections score fit without tone")
        MockJev.setFailure()
        let bad = await service.rank(name: "Malformed", members: [title(99)], candidates: candidates)
        precondition(bad == nil, "Incomplete answers must trigger full fallback")
        let before = MockJev.snapshot().0
        let cooldown = await service.rank(name: "Different", members: [], candidates: [title(1)])
        precondition(cooldown == nil && MockJev.snapshot().0 == before, "Outage cooldown")
        let request = JevRecommendationService.request(name: name, members: [title(99)], candidates: [title(2)])
        precondition(request.questions["fit_2"]!.instructions.contains("`candidates[0]`"))
        let response = JevRecommendationService.Response(model: "wrong-model", answers: [:])
        do {
            _ = try JevRecommendationService.judgments(from: response, candidates: [title(2)], hasMembers: true)
            preconditionFailure("Wrong model must fail")
        } catch {}
        print("Runtime checks passed: ranking, batches, verbatim names, deduplication, disk cache, missing key, malformed responses, cooldown, empty collections, model validation.")
    }
}
