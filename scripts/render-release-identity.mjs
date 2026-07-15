import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const identityPath = join(root, 'release/identity.json');
const arguments_ = process.argv.slice(2);
const mode = arguments_[0] ?? '--check';
if (!['--check', '--write'].includes(mode) || arguments_.length > 1) {
  throw new Error('usage: node scripts/render-release-identity.mjs [--check|--write]');
}

const expectedKeys = [
  'schemaVersion', 'appVersion', 'appBuild', 'helperVersion',
  'xpcProtocolVersion', 'enrollmentPolicyProtocolVersion', 'releaseTag',
  'appBundleIdentifier', 'helperLabel', 'machService',
  'qualifiedSystemBuild', 'channel'
];
const rawIdentity = readFileSync(identityPath, 'utf8');
const identity = JSON.parse(rawIdentity);
const canonicalIdentity = `${JSON.stringify(identity, null, 2)}\n`;

if (rawIdentity !== canonicalIdentity
  || Object.keys(identity).length !== expectedKeys.length
  || Object.keys(identity).some((key, index) => key !== expectedKeys[index])) {
  throw new Error('release/identity.json must be canonical JSON with exactly one ordered instance of every identity field');
}

const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0 && value <= 1_000_000;
const safeIdentifier = (value) => typeof value === 'string'
  && value.length <= 128
  && /^[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*$/.test(value);
if (identity.schemaVersion !== 1
  || typeof identity.appVersion !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(identity.appVersion)
  || !positiveInteger(identity.appBuild)
  || !positiveInteger(identity.helperVersion)
  || !positiveInteger(identity.xpcProtocolVersion)
  || !positiveInteger(identity.enrollmentPolicyProtocolVersion)
  || identity.xpcProtocolVersion === identity.enrollmentPolicyProtocolVersion
  || identity.releaseTag !== `v${identity.appVersion}`
  || !safeIdentifier(identity.appBundleIdentifier)
  || !safeIdentifier(identity.helperLabel) || identity.helperLabel !== identity.helperLabel.toLowerCase()
  || !safeIdentifier(identity.machService) || identity.machService !== `${identity.helperLabel}.control`
  || typeof identity.qualifiedSystemBuild !== 'string' || !/^\d{2}[A-Z]\d{1,3}$/.test(identity.qualifiedSystemBuild)
  || identity.channel !== 'manual-ad-hoc') {
  throw new Error('release/identity.json has invalid types, normalization, protocol separation, or unsafe identifiers');
}

const rootSupportDirectory = '/Library/Application Support/LidSwitch';
const rootHelperPath = `${rootSupportDirectory}/Current/LidSwitchHelper`;
const rootAppliedStatePath = `${rootSupportDirectory}/applied-state`;
const rootStatusPath = `${rootSupportDirectory}/helper-status`;
const rootEnrollmentPolicyPath = `${rootSupportDirectory}/Current/enrollment-policy`;
const ownerUIDPlaceholder = '__LIDSWITCH_OWNER_UID__';
const programArguments = [
  rootHelperPath,
  '--owner-uid',
  ownerUIDPlaceholder,
  '--qualified-build',
  identity.qualifiedSystemBuild,
  '--support-directory',
  rootSupportDirectory,
  '--applied-state',
  rootAppliedStatePath,
  '--status-path',
  rootStatusPath,
  '--policy-path',
  rootEnrollmentPolicyPath
];
if (programArguments.length !== 13) throw new Error('launchd contract must have exactly 13 ProgramArguments');
const provisionArguments = [...programArguments, '--mode', 'provision-root-state-lock'];
const recoveryArguments = [...programArguments, '--mode', 'recover-once', '--intent', 'install'];
if (provisionArguments.length !== 15 || recoveryArguments.length !== 17) {
  throw new Error('one-shot contracts must have exactly 15 and 17 ProgramArguments');
}

const plistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${identity.helperLabel}</string>
  <key>ProgramArguments</key>
  <array>
${programArguments.map((argument) => `    <string>${argument}</string>`).join('\n')}
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
    <key>${identity.machService}</key>
    <true/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
`;
if (plistTemplate.includes('<key>UserName</key>') || plistTemplate.includes('WatchPaths') || plistTemplate.includes('StartInterval')) {
  throw new Error('launchd template contains a forbidden authority or polling key');
}

const swiftTemplate = plistTemplate.split('\n').slice(0, -1).map((line) => `    ${line}`).join('\n');
const generatedSwift = `import Foundation

// Generated from release/identity.json by scripts/render-release-identity.mjs.
// Do not edit this tracked mirror; the renderer's --check mode rejects drift.
public enum ReleaseIdentity {
    public static let appVersion = "${identity.appVersion}"
    public static let appBuild = "${identity.appBuild}"
    public static let helperVersion = "${identity.helperVersion}"
    public static let xpcProtocolVersion: UInt32 = ${identity.xpcProtocolVersion}
    public static let enrollmentPolicyProtocolVersion: UInt32 = ${identity.enrollmentPolicyProtocolVersion}
    public static let releaseTag = "${identity.releaseTag}"
    public static let appBundleIdentifier = "${identity.appBundleIdentifier}"
    public static let helperLabel = "${identity.helperLabel}"
    public static let machService = "${identity.machService}"
    public static let qualifiedSystemBuild = "${identity.qualifiedSystemBuild}"
    public static let channel = "${identity.channel}"
    public static let rootSupportDirectory = "${rootSupportDirectory}"
    public static let rootHelperPath = "${rootHelperPath}"
    public static let rootAppliedStatePath = "${rootAppliedStatePath}"
    public static let rootStatusPath = "${rootStatusPath}"
    public static let rootEnrollmentPolicyPath = "${rootEnrollmentPolicyPath}"

    public static func programArguments(ownerUID: UInt32, executable: String = rootHelperPath) -> [String] {
        [
            executable,
            "--owner-uid", String(ownerUID),
            "--qualified-build", qualifiedSystemBuild,
            "--support-directory", rootSupportDirectory,
            "--applied-state", rootAppliedStatePath,
            "--status-path", rootStatusPath,
            "--policy-path", rootEnrollmentPolicyPath,
        ]
    }
}
`;
const generatedHeader = `#ifndef LIDSWITCH_RELEASE_IDENTITY_GENERATED_H
#define LIDSWITCH_RELEASE_IDENTITY_GENERATED_H

/* Generated from release/identity.json by scripts/render-release-identity.mjs. */
#define LS_RELEASE_APP_VERSION "${identity.appVersion}"
#define LS_RELEASE_APP_BUILD ${identity.appBuild}u
#define LS_RELEASE_HELPER_VERSION ${identity.helperVersion}u
#define LS_XPC_PROTOCOL_VERSION ${identity.xpcProtocolVersion}u
#define LS_ENROLLMENT_POLICY_PROTOCOL_VERSION ${identity.enrollmentPolicyProtocolVersion}u
#define LS_RELEASE_TAG "${identity.releaseTag}"
#define LS_RELEASE_APP_BUNDLE_IDENTIFIER "${identity.appBundleIdentifier}"
#define LS_RELEASE_HELPER_LABEL "${identity.helperLabel}"
#define LS_RELEASE_MACH_SERVICE "${identity.machService}"
#define LS_RELEASE_QUALIFIED_SYSTEM_BUILD "${identity.qualifiedSystemBuild}"
#define LS_RELEASE_CHANNEL "${identity.channel}"

#endif
`;
const generatedAnchorTemplate = `import Foundation

// Private release-candidate input template. The candidate builder replaces
// every __LIDSWITCH_*__ token from final measured artifacts, writes the result
// to Sources/LidSwitch/GeneratedReleaseHelperTrustAnchor.generated.swift, and
// sets LIDSWITCH_RELEASE_CANDIDATE=1 for that one build only.
//
// Bytes are canonical base64 without whitespace. No app CDHash is permitted:
// the app's final signature must never authenticate a value embedded in itself.
#if LIDSWITCH_RELEASE_CANDIDATE
enum GeneratedReleaseHelperTrustAnchor {
    static let value = ReleaseHelperTrustAnchor.Value(
        channel: "${identity.channel}",
        helperSHA256: Data(base64Encoded: "__LIDSWITCH_HELPER_SHA256_BASE64__")!,
        helperSize: __LIDSWITCH_HELPER_SIZE__,
        helperIdentifier: "__LIDSWITCH_HELPER_IDENTIFIER__",
        helperCDHash: Data(base64Encoded: "__LIDSWITCH_HELPER_CDHASH_BASE64__")!,
        releaseIdentityResourceName: "LidSwitchReleaseIdentity.json",
        releaseIdentityVersion: "${identity.appVersion}",
        releaseIdentitySHA256: Data(base64Encoded: "__LIDSWITCH_RELEASE_IDENTITY_SHA256_BASE64__")!
    )
}
#endif
`;
const generatedContract = `import Foundation
import LidSwitchCore

// Generated from release/identity.json by scripts/render-release-identity.mjs.
// Daemon and one-shot argv are derived from one canonical base array.
enum LaunchDaemonContract {
    static let ownerUIDPlaceholder = "${ownerUIDPlaceholder}"
    static let programArgumentCount = ${programArguments.length}
    static let provisionArgumentCount = ${provisionArguments.length}
    static let recoveryArgumentCount = ${recoveryArguments.length}

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
            .map { "    <string>\\(xmlEscaped($0))</string>" }
            .joined(separator: "\\n")
        return template.replacingOccurrences(
            of: programArgumentsPlaceholder,
            with: renderedArguments
        ) + "\\n"
    }

    private static let programArgumentsPlaceholder = "__LIDSWITCH_PROGRAM_ARGUMENTS__"
    private static let template = """
${swiftTemplate.replace(programArguments.map((argument) => `        <string>${argument}</string>`).join('\n'), '    __LIDSWITCH_PROGRAM_ARGUMENTS__')}
    """

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
`;
const releaseEnv = `LIDSWITCH_APP_VERSION="${identity.appVersion}"
LIDSWITCH_APP_BUILD="${identity.appBuild}"
LIDSWITCH_HELPER_VERSION="${identity.helperVersion}"
LIDSWITCH_XPC_PROTOCOL_VERSION="${identity.xpcProtocolVersion}"
LIDSWITCH_ENROLLMENT_POLICY_PROTOCOL_VERSION="${identity.enrollmentPolicyProtocolVersion}"
LIDSWITCH_RELEASE_TAG="${identity.releaseTag}"
LIDSWITCH_APP_BUNDLE_IDENTIFIER="${identity.appBundleIdentifier}"
LIDSWITCH_HELPER_LABEL="${identity.helperLabel}"
LIDSWITCH_MACH_SERVICE="${identity.machService}"
LIDSWITCH_QUALIFIED_SYSTEM_BUILD="${identity.qualifiedSystemBuild}"
LIDSWITCH_RELEASE_CHANNEL="${identity.channel}"
LIDSWITCH_ROOT_SUPPORT_DIRECTORY="${rootSupportDirectory}"
LIDSWITCH_ROOT_HELPER_PATH="${rootHelperPath}"
LIDSWITCH_ROOT_APPLIED_STATE_PATH="${rootAppliedStatePath}"
LIDSWITCH_ROOT_STATUS_PATH="${rootStatusPath}"
LIDSWITCH_ROOT_ENROLLMENT_POLICY_PATH="${rootEnrollmentPolicyPath}"
`;
const tagReceiptSchema = `${JSON.stringify({
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  title: 'LidSwitch release-tag collision gate receipt',
  type: 'object',
  additionalProperties: false,
  required: ['releaseTag', 'repository', 'collisionFree', 'checkedAt'],
  properties: {
    releaseTag: { const: identity.releaseTag },
    repository: { const: 'johnsilvavlogs/lidswitch' },
    collisionFree: { const: true },
    checkedAt: { type: 'string', format: 'date-time' }
  }
}, null, 2)}\n`;
const outputs = new Map([
  ['Sources/LidSwitchCore/ReleaseIdentity.generated.swift', generatedSwift],
  ['Sources/LidSwitchXPCBridge/include/LidSwitchReleaseIdentity.generated.h', generatedHeader],
  ['Sources/LidSwitch/Support/LaunchDaemonContract.generated.swift', generatedContract],
  ['script/release.env', releaseEnv],
  ['release/LidSwitchLaunchDaemon.plist.template', plistTemplate],
  ['Resources/LidSwitchReleaseIdentity.json', canonicalIdentity],
  ['release/GeneratedReleaseHelperTrustAnchor.template.swift', generatedAnchorTemplate],
  ['release/tag-collision-receipt.schema.json', tagReceiptSchema]
]);

function identityMirrorFiles(directory, displayDirectory = directory) {
  return readdirSync(join(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    const displayPath = join(displayDirectory, entry.name);
    if (entry.isDirectory()) return identityMirrorFiles(path, displayPath);
    return entry.isFile() && /release.?identity|(?:lidswitch)?launchdaemon(?:contract)?/i.test(entry.name)
      ? [displayPath]
      : [];
  });
}

if (mode === '--write') {
  for (const [path, content] of outputs) writeFileSync(join(root, path), content);
} else {
  for (const [path, content] of outputs) {
    if (readFileSync(join(root, path), 'utf8') !== content) throw new Error(`${path} drifts from release/identity.json`);
  }
  const expectedMirrors = [...outputs.keys()].filter((path) => /release.?identity|(?:lidswitch)?launchdaemon(?:contract)?/i.test(path)).sort();
  const actualMirrors = ['Sources', 'release', 'Resources']
    .flatMap((directory) => identityMirrorFiles(directory))
    .sort();
  if (JSON.stringify(actualMirrors) !== JSON.stringify(expectedMirrors)) throw new Error('obsolete or untracked release identity mirror detected');
  const packageJSON = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const packageLock = JSON.parse(readFileSync(join(root, 'package-lock.json'), 'utf8'));
  if (packageJSON.version !== identity.appVersion || packageLock.version !== identity.appVersion
    || packageLock.packages?.['']?.version !== identity.appVersion) {
    throw new Error('package version drifts from release identity');
  }
  for (const path of ['site/index.html', 'site/download/index.html']) {
    const content = readFileSync(join(root, path), 'utf8');
    if (!content.includes(`macOS 26.5.2 build ${identity.qualifiedSystemBuild}`)) throw new Error(`${path} drifts from qualified build identity`);
    if (content.includes(identity.appVersion)) throw new Error(`${path} must not carry a drift-prone release version`);
  }
  const retiredAssets = ['site/assets/lidswitch-panel.png', 'screenshots/lidswitch-working.png'];
  if (retiredAssets.some((path) => existsSync(join(root, path)))) {
    throw new Error('retired screenshot asset returned');
  }
  const siteSources = ['site/index.html', 'site/download/index.html', 'site/styles.css'];
  if (siteSources.some((path) => {
    const content = readFileSync(join(root, path), 'utf8');
    return retiredAssets.some((asset) => content.includes(asset.split('/').at(-1)));
  })) {
    throw new Error('site still references a retired screenshot');
  }
}

console.log(`release identity ${mode === '--write' ? 'rendered' : 'validated'}: ${identity.releaseTag}`);
