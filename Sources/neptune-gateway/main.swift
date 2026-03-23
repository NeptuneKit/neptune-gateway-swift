import Foundation
import NeptuneGatewaySwift

let hostname = ProcessInfo.processInfo.environment["NEPTUNE_HOST"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["NEPTUNE_PORT"] ?? "18765") ?? 18765
let app = try NeptuneGatewaySwift.makeApplication(hostname: hostname, port: port)
try app.run()
