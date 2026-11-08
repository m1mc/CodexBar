import AppKit
import CodexBarCore
import Foundation

enum CodexLoginRunner {
    static func run(
        homePath: String? = nil,
        timeout: TimeInterval = 120,
        outputDrainTimeout: TimeInterval = 3,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) async -> CLILoginRunner.Result
    {
        var env = environment
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)
        env = CodexHomeScope.scopedEnvironment(base: env, codexHome: homePath)

        return await CLILoginRunner.run(
            executable: BinaryLocator.resolveCodexBinary(env: env, loginPATH: loginPATH),
            environment: env,
            timeout: timeout,
            outputDrainTimeout: outputDrainTimeout,
            onProgress: { output in
                guard let url = CLILoginRunner.authorizationURL(in: output) else { return }
                Task { @MainActor in
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { app, _ in
                            app?.activate(options: .activateAllWindows)
                        }
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }
            })
    }
}
