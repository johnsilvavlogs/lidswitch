import Foundation
import LidSwitchCore

// Generated from release/identity.json by scripts/render-release-identity.mjs.
// Daemon and one-shot argv are derived from one canonical base array.
enum LaunchDaemonContract {
    static let ownerUIDPlaceholder = "__LIDSWITCH_OWNER_UID__"
    static let programArgumentCount = 13
    static let provisionArgumentCount = 15
    static let recoveryArgumentCount = 17

    static func programArguments(
        ownerUID: UInt32,
        executable: String = ReleaseIdentity.rootHelperPath
    ) -> [String] {
        ReleaseIdentity.programArguments(ownerUID: ownerUID, executable: executable)
    }

    static func provisionArguments(ownerUID: UInt32, executable: String) -> [String] {
        programArguments(ownerUID: ownerUID, executable: executable)
            + ["--mode", "provision-root-state-lock"]
    }

    static func recoveryArguments(
        ownerUID: UInt32,
        executable: String,
        intent: RecoveryIntent
    ) -> [String] {
        programArguments(ownerUID: ownerUID, executable: executable)
            + ["--mode", "recover-once", "--intent", intent.rawValue]
    }

    static func render(ownerUID: UInt32) -> String {
        let renderedArguments = programArguments(ownerUID: ownerUID)
            .map { "    <string>\(xmlEscaped($0))</string>" }
            .joined(separator: "\n")
        return template.replacingOccurrences(
            of: programArgumentsPlaceholder,
            with: renderedArguments
        ) + "\n"
    }

    private static let programArgumentsPlaceholder = "__LIDSWITCH_PROGRAM_ARGUMENTS__"
    private static let template = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.johnsilva.lidswitch.helper</string>
      <key>ProgramArguments</key>
      <array>
    __LIDSWITCH_PROGRAM_ARGUMENTS__
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>MachServices</key>
      <dict>
        <key>com.johnsilva.lidswitch.helper.control</key>
        <true/>
      </dict>
      <key>ProcessType</key>
      <string>Background</string>
      <key>ThrottleInterval</key>
      <integer>10</integer>
    </dict>
    </plist>
    """

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
