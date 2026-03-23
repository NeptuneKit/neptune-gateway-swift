@_exported import Vapor

public enum NeptuneGatewaySwift {
    public static func makeApplication(
        environment: Environment = .development,
        hostname: String = "127.0.0.1",
        port: Int = 18765,
        storageURL: URL? = nil,
        storeConfiguration: GatewayStoreConfiguration = .default
    ) throws -> Application {
        try NeptuneGatewaySwiftApp.makeApplication(
            environment: environment,
            hostname: hostname,
            port: port,
            storageURL: storageURL,
            storeConfiguration: storeConfiguration
        )
    }
}
