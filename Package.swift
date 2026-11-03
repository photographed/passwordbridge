// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PasswordBridge", platforms: [.macOS(.v14)], products: [.executable(name: "PasswordBridge", targets: ["PasswordBridge"])], targets: [.target(name: "BridgeCore"), .executableTarget(name: "PasswordBridge", dependencies: ["BridgeCore"]), .executableTarget(name: "BridgeChecks", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests")])
