import ArgumentParser
import Foundation
import Yams

public enum ClientOutputFormat: String, CaseIterable, Sendable {
    case text
    case json
    case yaml
}

extension ClientOutputFormat: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "text":
            self = .text
        case "json":
            self = .json
        case "yaml", "yml":
            self = .yaml
        default:
            return nil
        }
    }

    public static var allValueStrings: [String] {
        ["text", "json", "yaml", "yml"]
    }
}

enum GatewayClientsCLIError: Error, CustomStringConvertible {
    case invalidGatewayURL(String)
    case invalidResponse
    case badStatusCode(Int)

    var description: String {
        switch self {
        case .invalidGatewayURL(let value):
            return "Invalid gateway URL: \(value)"
        case .invalidResponse:
            return "Gateway returned a non-HTTP response."
        case .badStatusCode(let code):
            return "Gateway returned unexpected HTTP status: \(code)"
        }
    }
}

struct GatewayClientsFetcher {
    let gatewayBaseURL: String

    func listClients() throws -> ClientListResponse {
        let requestURL = try clientsURL()
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        var responseData = Data()
        var responseError: Error?
        var statusCode = -1
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data ?? Data()
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let responseError {
            throw responseError
        }
        guard statusCode != -1 else {
            throw GatewayClientsCLIError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw GatewayClientsCLIError.badStatusCode(statusCode)
        }
        return try JSONDecoder().decode(ClientListResponse.self, from: responseData)
    }

    func clientsURL() throws -> URL {
        guard var components = URLComponents(string: gatewayBaseURL) else {
            throw GatewayClientsCLIError.invalidGatewayURL(gatewayBaseURL)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "v2", "clients"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw GatewayClientsCLIError.invalidGatewayURL(gatewayBaseURL)
        }
        return url
    }
}

enum ClientListRenderer {
    static func renderText(_ items: [ClientSnapshot]) -> String {
        guard !items.isEmpty else {
            return "No online clients.\n"
        }

        var lines: [String] = []
        lines.reserveCapacity(items.count)
        for client in items {
            lines.append("- [\(client.platform)-\(client.appId)] \(client.deviceId)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderJSON(_ response: ClientListResponse) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func renderYAML(_ response: ClientListResponse) throws -> String {
        let grouped = Dictionary(grouping: response.items, by: \.deviceId)
        let encoder = YAMLEncoder()
        let rendered = try encoder.encode(grouped)
        return rendered.hasSuffix("\n") ? rendered : rendered + "\n"
    }
}
