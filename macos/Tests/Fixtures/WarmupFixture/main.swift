import Foundation
import Darwin
import SwitcherCore

let env = ProcessInfo.processInfo.environment
guard let homePath = env["WARMUP_FIXTURE_HOME"], let rootPath = env["WARMUP_FIXTURE_ROOT"],
      let physicalTemp = realpath(FileManager.default.temporaryDirectory.path, nil) else { exit(2) }
defer { free(physicalTemp) }
// Preserve the physical /private/var prefix supplied by the integration
// harness. standardizedFileURL can reintroduce macOS's /var symlink alias.
let temporary = URL(fileURLWithPath: String(cString: physicalTemp))
let home = URL(fileURLWithPath: homePath)
let root = URL(fileURLWithPath: rootPath)
let parent = home.deletingLastPathComponent()
guard parent == root.deletingLastPathComponent(), parent.deletingLastPathComponent() == temporary,
      parent.lastPathComponent.hasPrefix("astra-warmup-integration-"),
      home.lastPathComponent == "home", root.lastPathComponent == "vault",
      ProcessInfo.processInfo.arguments.count == 2 else { exit(2) }

switch ProcessInfo.processInfo.arguments[1] {
case "--configure":
    do {
        try AstraWarmup.setEnabled(true, home: home, root: root,
                                   executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
                                   consent: true)
    } catch { exit(1) }
case "--astra-warmup":
    let event = FileHandle.standardInput.readDataToEndOfFile()
    if let result = AstraWarmup.run(event: event, home: home, root: root) {
        FileHandle.standardOutput.write(result)
    }
default: exit(2)
}
