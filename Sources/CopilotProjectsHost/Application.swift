import Foundation
import CopilotProjectsCore
import Darwin

@MainActor
enum HostIntegrationRegistry {
    static var factory: (any SessionHost) -> (any HostIntegration)? = { _ in nil }
}

@MainActor
public enum CopilotProjectsApplication {
    public static func run(
        makeIntegration: @escaping @MainActor (any SessionHost) -> (any HostIntegration)? = { _ in nil },
        checkIntegrationAssets: @escaping (Bundle) -> Bool = { _ in true }
    ) {
        signal(SIGPIPE, SIG_IGN)
        let cliArgs = Array(CommandLine.arguments.dropFirst())
        if let first = cliArgs.first, CLIMain.isCommand(first) {
            exit(CLIMain.run(cliArgs, checkAssets: {
                let anchor = RunningExecutable.applicationBundle ?? .main
                return CopilotExtension.packagedAssetAvailable(anchor: anchor)
                    && checkIntegrationAssets(anchor)
            }))
        }
        if !cliArgs.isEmpty, !CLIMain.isCocoaLaunchArguments(cliArgs) {
            FileHandle.standardError.write(Data(
                "copilot-projects: unknown command: \(cliArgs[0]) (try `copilot-projects help`)\n".utf8
            ))
            exit(2)
        }

        // SwiftUI creates the zero-argument application delegate during main().
        HostIntegrationRegistry.factory = makeIntegration
        CopilotProjectsApp.main()
    }
}
