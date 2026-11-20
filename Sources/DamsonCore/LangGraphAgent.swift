import Foundation

/// Sends the command to the local LangGraph server (agents/server.py). If the server is not running,
/// falls back to the plain acknowledgement so the Company tab keeps working.
public struct LangGraphTeamAgent: TeamAgent {
    public var endpoint: URL
    public var timeout: TimeInterval

    public init(endpoint: URL = URL(string: "http://127.0.0.1:8765/run")!, timeout: TimeInterval = 90) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func handle(command: String, for person: Person) async -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["name": person.name, "role": person.role, "skills": person.skills.joined(separator: ", "), "command": command]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reply = json["reply"] as? String, !reply.isEmpty {
                return reply
            }
        } catch {}
        return StubTeamAgent.reply
    }
}
