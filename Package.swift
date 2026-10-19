// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LumaTrace", platforms: [.macOS(.v14)], products: [.executable(name: "LumaTrace", targets: ["LumaTrace"])], targets: [.target(name: "SystemLock", publicHeadersPath: "include"), .executableTarget(name: "LumaTrace", dependencies: ["SystemLock"]), .testTarget(name: "LumaTraceTests", dependencies: ["LumaTrace"])])
