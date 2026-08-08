import Foundation
import PackagePlugin

@main
struct InfoPlistDependencyPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlist = packageDirectory
            .appending(path: "Sources/betterMeet/Info.plist")
        let output = context.pluginWorkDirectoryURL
            .appending(path: "InfoPlistBuildDependency.swift")
        let script = """
        set -eu
        hash=$(/usr/bin/cksum "$1" | /usr/bin/awk '{print $1}')
        temporary="$2.tmp"
        /usr/bin/printf '%s\n' \
          '// Generated build dependency for the linker-embedded Info.plist.' \
          '@_cdecl("betterMeetInfoPlistContentHash")' \
          'func betterMeetInfoPlistContentHash() -> UInt64 {' \
          "    $hash" \
          '}' > "$temporary"
        if ! /usr/bin/cmp -s "$temporary" "$2"; then
          /bin/mv "$temporary" "$2"
        else
          /bin/rm "$temporary"
        fi
        """
        return [
            .prebuildCommand(
                displayName: "Tracking embedded Info.plist",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", script, "InfoPlistDependencyPlugin",
                    infoPlist.path, output.path,
                ],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            )
        ]
    }
}
