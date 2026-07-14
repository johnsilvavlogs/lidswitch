#!/bin/bash
[[ "${LIDSWITCH_HELD_ENTRY:-}" == v1 && "${BASH_SOURCE[0]}" == /dev/fd/31 && "${LIDSWITCH_HELD_WRAPPER_LOADED:-}" == 1 ]] || return 64
readonly LIDSWITCH_HELD_COMMON_LOADED=1
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
readonly LIDSWITCH_SWIFT_CLT_ROOT=/Library/Developer/CommandLineTools
readonly LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
readonly LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
readonly LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
readonly LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS=/Applications/Xcode.app/Contents/SharedFrameworks
readonly LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Frameworks"
readonly LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/PrivateFrameworks"
readonly LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/lib"
readonly LIDSWITCH_SWIFT_XCODE_LIBXCRUN="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/usr/lib/libxcrun.dylib"
readonly LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/bin/swift-plugin-server"

# Repository Python helpers are data until this fixed system-Python bootstrap
# descriptor-opens, bounds, re-fstats and hashes their frozen bytes.  The
# caller supplies a clean environment before `--`; helper argv after `--` is
# preserved exactly.  This does not make the shell wrapper source authoritative
# (that separate limitation is documented), but it removes direct helper-path
# execution from every common/envelope call site.
readonly SWIFT_SANDBOX_VERIFIED_HELPER_BOOTSTRAP='import os,sys,stat,hashlib
fd=int(sys.argv[1]); expected,size_text=sys.argv[2:4]; p="<held-lidswitch-helper-fd>"
try:
 if len(expected)!=64 or any(c not in "0123456789abcdef" for c in expected) or not size_text.isdigit() or not 0<int(size_text)<=8388608: raise SystemExit(74)
 before=os.fstat(fd); identity=(before.st_dev,before.st_ino,before.st_uid,before.st_gid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_size); os.lseek(fd,0,os.SEEK_SET)
 if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() or before.st_gid!=os.getgid() or stat.S_IMODE(before.st_mode)!=0o644 or before.st_nlink!=1 or before.st_size!=int(size_text): raise SystemExit(74)
 data=bytearray()
 while len(data)<before.st_size:
  try: chunk=os.read(fd,min(131072,before.st_size-len(data)))
  except InterruptedError: continue
  if not chunk: raise SystemExit(74)
  data.extend(chunk)
 while True:
  try: extra=os.read(fd,1); break
  except InterruptedError: continue
 after=os.fstat(fd); data=bytes(data)
 if extra or (after.st_dev,after.st_ino,after.st_uid,after.st_gid,stat.S_IMODE(after.st_mode),after.st_nlink,after.st_size)!=identity or hashlib.sha256(data).hexdigest()!=expected: raise SystemExit(74)
 code=compile(data,"<verified-lidswitch-helper>","exec")
except BaseException:
 if isinstance(sys.exc_info()[1],SystemExit): raise
 raise SystemExit(74)
sys.argv=[p]+sys.argv[4:]; exec(code,{"__name__":"__main__","__file__":p})'

swift_sandbox_verified_python() {
  local helper="$1" expected size fd
  shift
  case "$helper" in
    safe-file)
      fd=34
      expected="cc9da60f429aefdbbb7f9a672d314dfb644fe000cbdd82529083f7bb7f3893cb"
      size=117148
      ;;
    supervisor)
      fd=35
      expected="b098e1c6b49f65ab28b33e629381c4e6bf3443358d032d3f2c13a444ceb1a291"
      size=63684
      ;;
    *) return 74 ;;
  esac
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ ]] || return 74
  local -a clean_environment=()
  while [[ "${1:-}" != "--" ]]; do
    [[ $# -gt 0 && "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 74
    clean_environment+=("$1")
    shift
  done
  shift
  /usr/bin/env -i "${clean_environment[@]}" /usr/bin/python3 -I -S -B -c "$SWIFT_SANDBOX_VERIFIED_HELPER_BOOTSTRAP" \
    "$fd" "$expected" "$size" "$@"
}

# Shared fail-closed setup for Swift build/test wrappers. The wrapper control
# root is a separate descriptor-pinned capability. Only the execution root is
# writable by the sandboxed compiler/test process.

swift_sandbox_reject_inherited_paths() {
  local name
  for name in \
    LIDSWITCH_SCRATCH_PATH LIDSWITCH_BENCHMARK_SCRATCH_PATH \
    LIDSWITCH_SWIFT_SANDBOX_ROOT LIDSWITCH_SWIFT_EXEC_ROOT \
    LIDSWITCH_SWIFT_CONTROL_ROOT LIDSWITCH_SWIFT_CONTROL_ID \
    LIDSWITCH_SWIFT_EXEC_ID LIDSWITCH_SWIFT_SCRATCH_PATH \
    LIDSWITCH_SWIFT_SANDBOX_PROFILE LIDSWITCH_SWIFT_ENVELOPE_NONCE \
    LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL LIDSWITCH_SWIFT_SOURCE_ROOT LIDSWITCH_SWIFT_SOURCE_SEAL \
    LIDSWITCH_SWIFT_SOURCE_NAME LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL \
    LIDSWITCH_SWIFT_APP_SOURCE_ROOT LIDSWITCH_SWIFT_APP_SOURCE_SEAL LIDSWITCH_SWIFT_RELEASE_OUTPUT_ROOT \
    LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH LIDSWITCH_SWIFT_APP_SCRATCH_PATH LIDSWITCH_SWIFT_SETUP_MODE \
    LIDSWITCH_SWIFT_CAPTURE_AUTH_KEY \
    LIDSWITCH_SWIFT_PREFLIGHT LIDSWITCH_SWIFT_POSTFLIGHT \
    LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT LIDSWITCH_SWIFT_BENCHMARK_DEST_ID LIDSWITCH_TEST_FIXTURE_ROOT \
    SWIFTPM_BUILD_DIR SWIFTPM_MODULECACHE_OVERRIDE SWIFTPM_TESTS_MODULECACHE \
    SWIFTPM_TESTS_PACKAGECACHE SWIFTPM_CACHE_PATH SWIFTPM_CONFIG_PATH \
    SWIFTPM_SECURITY_PATH SWIFTPM_PLATFORM_PATH_macosx SWIFT_TESTING_ENABLED \
    CLANG_MODULE_CACHE_PATH SWIFT_MODULECACHE_PATH \
    CFFIXED_USER_HOME XDG_CACHE_HOME XDG_CONFIG_HOME SDKROOT TOOLCHAINS \
    DEVELOPER_DIR LIDSWITCH_RELEASE_CANDIDATE SWIFT_EXEC CC CXX LD DYLD_LIBRARY_PATH \
    DYLD_FRAMEWORK_PATH DYLD_INSERT_LIBRARIES BASH_ENV ENV BASH_XTRACEFD; do
    [[ -z "${!name:-}" ]] || { echo "inherited SwiftPM or shell override is not permitted: $name" >&2; return 64; }
  done
}

swift_sandbox_reject_inherited_fds() {
  local path fd
  for path in /dev/fd/*; do
    fd="${path##*/}"
    [[ "$fd" =~ ^[0-9]+$ ]] || continue
    [[ -e "$path" ]] || continue
    case "$fd" in
      0|1|2|30|31|32|33|34|35|36|37|38|39|40|41|255) ;;
      *) echo "nonstandard inherited file descriptor is not permitted: $fd" >&2; return 64 ;;
    esac
  done
}

swift_sandbox_root_identity() {
  local path="$1"
  [[ "$path" == /private/tmp/* && "$(/usr/bin/dirname "$path")" == "/private/tmp" && -d "$path" && ! -L "$path" ]] || return 64
  /usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l' "$path" | /usr/bin/awk -F: -v uid="$(/usr/bin/id -u)" -v gid="$(/usr/bin/id -g)" '
    NF == 6 && $1 ~ /^[0-9]+$/ && $1 > 0 && $2 ~ /^[0-9]+$/ && $2 > 0 && $3 == uid && $4 == gid && $5 == 700 && $6 ~ /^[0-9]+$/ && $6 >= 2 { print; ok=1 }
    END { if (!ok) exit 65 }
  '
}

swift_sandbox_clt_identity() {
  local path="$1" kind="$2" metadata mode
  [[ ( "$path" == /Library || "$path" == /Library/Developer || "$path" == "$LIDSWITCH_SWIFT_CLT_ROOT" || "$path" == "$LIDSWITCH_SWIFT_CLT_ROOT"/* ) && ! -L "$path" ]] || return 64
  if [[ "$kind" == directory ]]; then [[ -d "$path" ]] || return 64; else [[ -f "$path" ]] || return 64; fi
  metadata="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l' "$path")" || return 64
  [[ "$metadata" =~ ^[0-9]+:[0-9]+:0:0:[0-7]{3,6}:[1-9][0-9]*$ ]] || return 64
  mode="${metadata#*:*:*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 )) || return 64
  printf '%s\n' "$metadata"
}

swift_sandbox_clt_driver_identity() {
  local path="$1" metadata mode target
  [[ "$path" == "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/swift" && -L "$path" ]] || return 64
  target="$(/usr/bin/readlink "$path")" || return 64
  [[ "$target" == swift-frontend ]] || return 64
  metadata="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l:%z' "$path")" || return 64
  [[ "$metadata" =~ ^[0-9]+:[0-9]+:0:0:[0-7]{3,6}:1:14$ ]] || return 64
  mode="${metadata#*:*:*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 )) || return 64
  printf '%s:%s\n' "$metadata" "$target"
}

swift_sandbox_resolve_clt_path() {
  local candidate="$1" expected_kind="$2" target canonical rounds=0
  [[ "$expected_kind" == file || "$expected_kind" == directory ]] || return 64
  while [[ -L "$candidate" && "$rounds" -lt 8 ]]; do
    target="$(/usr/bin/readlink "$candidate")" || return 64
    if [[ "$target" == /* ]]; then candidate="$target"; else candidate="$(/usr/bin/dirname "$candidate")/$target"; fi
    ((rounds += 1))
  done
  canonical="$(cd "$(/usr/bin/dirname "$candidate")" && /bin/pwd -P)/$(/usr/bin/basename "$candidate")" || return 64
  candidate="$canonical"
  [[ "$rounds" -lt 8 && "$candidate" == "$LIDSWITCH_SWIFT_CLT_ROOT"/* ]] || return 64
  swift_sandbox_clt_identity "$candidate" "$expected_kind" >/dev/null || return 64
  printf '%s\n' "$candidate"
}

swift_sandbox_capture_developer_toolchain() {
  local component identity tool resolved variable sdk driver
  [[ -d "$LIDSWITCH_SWIFT_CLT_ROOT" && ! -L "$LIDSWITCH_SWIFT_CLT_ROOT" ]] || return 64
  LIDSWITCH_SWIFT_DEVELOPER_DIR="$LIDSWITCH_SWIFT_CLT_ROOT"
  LIDSWITCH_SWIFT_DEVELOPER_SEAL=""
  for component in /Library /Library/Developer "$LIDSWITCH_SWIFT_CLT_ROOT" "$LIDSWITCH_SWIFT_CLT_ROOT/usr" "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin" "$LIDSWITCH_SWIFT_CLT_ROOT/SDKs"; do
    identity="$(swift_sandbox_clt_identity "$component" directory)" || return 64
    LIDSWITCH_SWIFT_DEVELOPER_SEAL+="$component#$identity;"
  done
  driver="$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/swift"
  LIDSWITCH_SWIFT_DRIVER_SEAL="$(swift_sandbox_clt_driver_identity "$driver")" || return 64
  [[ "$(swift_sandbox_resolve_clt_path "$driver" file)" == "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/swift-frontend" ]] || return 64
  LIDSWITCH_SWIFT_TOOL_swift="$driver"
  for tool in swiftc swift-frontend clang clang++ ld dsymutil; do
    resolved="$(swift_sandbox_resolve_clt_path "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/$tool" file)" || return 64
    [[ "$(/usr/bin/dirname "$resolved")" == "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin" ]] || return 64
    identity="$(swift_sandbox_clt_identity "$resolved" file)" || return 64
    case "$tool" in swift-frontend) variable=swift_frontend ;; clang++) variable=clangxx ;; *) variable="$tool" ;; esac
    printf -v "LIDSWITCH_SWIFT_TOOL_$variable" '%s' "$resolved"
    LIDSWITCH_SWIFT_DEVELOPER_SEAL+="$resolved#$identity;"
  done
  sdk="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C DEVELOPER_DIR="$LIDSWITCH_SWIFT_CLT_ROOT" /usr/bin/xcrun --sdk macosx --show-sdk-path)" || return 64
  sdk="$(swift_sandbox_resolve_clt_path "$sdk" directory)" || return 64
  [[ "$(/usr/bin/dirname "$sdk")" == "$LIDSWITCH_SWIFT_CLT_ROOT/SDKs" && "$sdk" == *.sdk ]] || return 64
  identity="$(swift_sandbox_clt_identity "$sdk" directory)" || return 64
  LIDSWITCH_SWIFT_SDKROOT="$sdk"
  LIDSWITCH_SWIFT_DEVELOPER_SEAL+="$sdk#$identity;"
  export LIDSWITCH_SWIFT_DEVELOPER_DIR LIDSWITCH_SWIFT_SDKROOT LIDSWITCH_SWIFT_DEVELOPER_SEAL LIDSWITCH_SWIFT_DRIVER_SEAL
  export LIDSWITCH_SWIFT_TOOL_swift LIDSWITCH_SWIFT_TOOL_swiftc LIDSWITCH_SWIFT_TOOL_swift_frontend
  export LIDSWITCH_SWIFT_TOOL_clang LIDSWITCH_SWIFT_TOOL_clangxx LIDSWITCH_SWIFT_TOOL_ld LIDSWITCH_SWIFT_TOOL_dsymutil
}

swift_sandbox_assert_developer_toolchain() {
  local entry path expected observed entries driver_observed
  [[ -n "${LIDSWITCH_SWIFT_DEVELOPER_SEAL:-}" && -n "${LIDSWITCH_SWIFT_DRIVER_SEAL:-}" && "$LIDSWITCH_SWIFT_TOOL_swift" == "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/swift" && "$LIDSWITCH_SWIFT_DEVELOPER_DIR" == "$LIDSWITCH_SWIFT_CLT_ROOT" && "$LIDSWITCH_SWIFT_SDKROOT" == "$LIDSWITCH_SWIFT_CLT_ROOT"/SDKs/*.sdk ]] || return 74
  driver_observed="$(swift_sandbox_clt_driver_identity "$LIDSWITCH_SWIFT_TOOL_swift")" || return 74
  [[ "$driver_observed" == "$LIDSWITCH_SWIFT_DRIVER_SEAL" ]] || return 74
  IFS=';' read -r -a entries <<< "$LIDSWITCH_SWIFT_DEVELOPER_SEAL"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    path="${entry%%#*}"; expected="${entry#*#}"
    if [[ -d "$path" ]]; then observed="$(swift_sandbox_clt_identity "$path" directory)"; else observed="$(swift_sandbox_clt_identity "$path" file)"; fi
    [[ "$observed" == "$expected" ]] || return 74
  done
}

swift_sandbox_bind_release_profile_placeholders() {
  # Release builds never probe or select Xcode. The shared deny-default profile
  # still has test-only placeholders, so bind those inertly to the already
  # sealed Command Line Tools capability.
  LIDSWITCH_SWIFT_XCODE_SDKROOT="$LIDSWITCH_SWIFT_SDKROOT"
  LIDSWITCH_SWIFT_XCODE_TOOL_swift="$LIDSWITCH_SWIFT_TOOL_swift"
  LIDSWITCH_SWIFT_XCODE_TOOL_swiftc="$LIDSWITCH_SWIFT_TOOL_swiftc"
  LIDSWITCH_SWIFT_XCODE_TOOL_swift_frontend="$LIDSWITCH_SWIFT_TOOL_swift_frontend"
  LIDSWITCH_SWIFT_XCODE_TOOL_clang="$LIDSWITCH_SWIFT_TOOL_clang"
  LIDSWITCH_SWIFT_XCODE_TOOL_clangxx="$LIDSWITCH_SWIFT_TOOL_clangxx"
  LIDSWITCH_SWIFT_XCODE_TOOL_ld="$LIDSWITCH_SWIFT_TOOL_ld"
  LIDSWITCH_SWIFT_XCODE_TOOL_dsymutil="$LIDSWITCH_SWIFT_TOOL_dsymutil"
  LIDSWITCH_SWIFT_XCODE_TOOL_libtool="$LIDSWITCH_SWIFT_TOOL_ld"
  LIDSWITCH_SWIFT_XCODE_TOOL_xctest="$LIDSWITCH_SWIFT_TOOL_swift"
  LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK="$LIDSWITCH_SWIFT_SDKROOT"
  LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE="$LIDSWITCH_SWIFT_SDKROOT"
  LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT="$LIDSWITCH_SWIFT_TOOL_swift"
  export LIDSWITCH_SWIFT_XCODE_SDKROOT LIDSWITCH_SWIFT_XCODE_TOOL_swift LIDSWITCH_SWIFT_XCODE_TOOL_swiftc
  export LIDSWITCH_SWIFT_XCODE_TOOL_swift_frontend LIDSWITCH_SWIFT_XCODE_TOOL_clang LIDSWITCH_SWIFT_XCODE_TOOL_clangxx
  export LIDSWITCH_SWIFT_XCODE_TOOL_ld LIDSWITCH_SWIFT_XCODE_TOOL_dsymutil LIDSWITCH_SWIFT_XCODE_TOOL_libtool LIDSWITCH_SWIFT_XCODE_TOOL_xctest
  export LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT
}

# XCTest is absent from Command Line Tools.  Test execution therefore uses the
# locally installed Xcode toolchain, but only this fixed macOS platform slice;
# release-helper and release-app builds continue to use the CLT capture above.
swift_sandbox_xcode_identity() {
  local path="$1" kind="$2" metadata mode
  case "$path" in
    /Applications|/Applications/Xcode.app|/Applications/Xcode.app/Contents|"$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"|"$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"/*|"$LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS"|"$LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS"/*) ;;
    *) return 64 ;;
  esac
  [[ ! -L "$path" ]] || return 64
  if [[ "$kind" == directory ]]; then [[ -d "$path" ]] || return 64; else [[ -f "$path" ]] || return 64; fi
  metadata="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l' "$path")" || return 64
  if [[ "$path" == /Applications ]]; then
    [[ "$kind" == directory && "$metadata" =~ ^[0-9]+:[0-9]+:0:80:775:[1-9][0-9]*$ ]] || return 64
    printf '%s\n' "$metadata"
    return 0
  fi
  [[ "$metadata" =~ ^[0-9]+:[0-9]+:0:0:[0-7]{3,6}:[1-9][0-9]*$ ]] || return 64
  mode="${metadata#*:*:*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 )) || return 64
  printf '%s\n' "$metadata"
}

swift_sandbox_xcode_driver_identity() {
  local path="$1" metadata mode target
  [[ "$path" == "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/swift" && -L "$path" ]] || return 64
  target="$(/usr/bin/readlink "$path")" || return 64
  [[ "$target" == swift-frontend ]] || return 64
  metadata="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l:%z' "$path")" || return 64
  [[ "$metadata" =~ ^[0-9]+:[0-9]+:0:0:[0-7]{3,6}:1:14$ ]] || return 64
  mode="${metadata#*:*:*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 )) || return 64
  printf '%s:%s\n' "$metadata" "$target"
}

swift_sandbox_resolve_xcode_path() {
  local candidate="$1" expected_kind="$2" target canonical rounds=0
  [[ "$expected_kind" == file || "$expected_kind" == directory ]] || return 64
  while [[ -L "$candidate" && "$rounds" -lt 8 ]]; do
    target="$(/usr/bin/readlink "$candidate")" || return 64
    if [[ "$target" == /* ]]; then candidate="$target"; else candidate="$(/usr/bin/dirname "$candidate")/$target"; fi
    ((rounds += 1))
  done
  canonical="$(cd "$(/usr/bin/dirname "$candidate")" && /bin/pwd -P)/$(/usr/bin/basename "$candidate")" || return 64
  candidate="$canonical"
  [[ "$rounds" -lt 8 && "$candidate" == "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"/* ]] || return 64
  swift_sandbox_xcode_identity "$candidate" "$expected_kind" >/dev/null || return 64
  printf '%s\n' "$candidate"
}

swift_sandbox_capture_xcode_test_toolchain() {
  local component identity tool resolved variable sdk driver framework module support xctest
  [[ -d "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" && ! -L "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" ]] || return 64
  LIDSWITCH_SWIFT_XCODE_TEST_SEAL=""
  for component in /Applications /Applications/Xcode.app /Applications/Xcode.app/Contents "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Toolchains" "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT" "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr" "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin" "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Platforms" "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/SDKs" "$LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB"; do
    identity="$(swift_sandbox_xcode_identity "$component" directory)" || return 64
    LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$component#$identity;"
  done
  driver="$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/swift"
  LIDSWITCH_SWIFT_XCODE_DRIVER_SEAL="$(swift_sandbox_xcode_driver_identity "$driver")" || return 64
  [[ "$(swift_sandbox_resolve_xcode_path "$driver" file)" == "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/swift-frontend" ]] || return 64
  LIDSWITCH_SWIFT_XCODE_TOOL_swift="$driver"
  for tool in swiftc swift-frontend clang clang++ ld dsymutil libtool; do
    resolved="$(swift_sandbox_resolve_xcode_path "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/$tool" file)" || return 64
    [[ "$(/usr/bin/dirname "$resolved")" == "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin" ]] || return 64
    identity="$(swift_sandbox_xcode_identity "$resolved" file)" || return 64
    case "$tool" in swift-frontend) variable=swift_frontend ;; clang++) variable=clangxx ;; *) variable="$tool" ;; esac
    printf -v "LIDSWITCH_SWIFT_XCODE_TOOL_$variable" '%s' "$resolved"
    LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$resolved#$identity;"
  done
  for tool in swift-test swift-build swift-package swift-driver; do
    resolved="$(swift_sandbox_resolve_xcode_path "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/$tool" file)" || return 64
    [[ "$(/usr/bin/dirname "$resolved")" == "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin" ]] || return 64
    identity="$(swift_sandbox_xcode_identity "$resolved" file)" || return 64
    LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$resolved#$identity;"
  done
  sdk="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C DEVELOPER_DIR="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)" || return 64
  sdk="$(swift_sandbox_resolve_xcode_path "$sdk" directory)" || return 64
  [[ "$(/usr/bin/dirname "$sdk")" == "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/SDKs" && "$sdk" == *.sdk ]] || return 64
  identity="$(swift_sandbox_xcode_identity "$sdk" directory)" || return 64
  LIDSWITCH_SWIFT_XCODE_SDKROOT="$sdk"
  LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$sdk#$identity;"
  framework="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Frameworks/XCTest.framework"
  module="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/lib/XCTest.swiftmodule"
  support="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/lib/libXCTestSwiftSupport.dylib"
  xctest="$(swift_sandbox_resolve_xcode_path "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/usr/bin/xctest" file)" || return 64
  [[ "$xctest" == "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Xcode/Agents/xctest" ]] || return 64
  for component in "$framework" "$module"; do
    identity="$(swift_sandbox_xcode_identity "$component" directory)" || return 64
    LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$component#$identity;"
  done
  for component in "$support" "$xctest" "$LIDSWITCH_SWIFT_XCODE_LIBXCRUN" "$LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER"; do
    identity="$(swift_sandbox_xcode_identity "$component" file)" || return 64
    LIDSWITCH_SWIFT_XCODE_TEST_SEAL+="$component#$identity;"
  done
  LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK="$framework"
  LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE="$module"
  LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT="$support"
  LIDSWITCH_SWIFT_XCODE_TOOL_xctest="$xctest"
  export LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS
  export LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB
  export LIDSWITCH_SWIFT_XCODE_TEST_SEAL LIDSWITCH_SWIFT_XCODE_DRIVER_SEAL LIDSWITCH_SWIFT_XCODE_SDKROOT
  export LIDSWITCH_SWIFT_XCODE_TOOL_swift LIDSWITCH_SWIFT_XCODE_TOOL_swiftc LIDSWITCH_SWIFT_XCODE_TOOL_swift_frontend
  export LIDSWITCH_SWIFT_XCODE_TOOL_clang LIDSWITCH_SWIFT_XCODE_TOOL_clangxx LIDSWITCH_SWIFT_XCODE_TOOL_ld LIDSWITCH_SWIFT_XCODE_TOOL_dsymutil LIDSWITCH_SWIFT_XCODE_TOOL_libtool LIDSWITCH_SWIFT_XCODE_TOOL_xctest
  export LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT
  export LIDSWITCH_SWIFT_XCODE_LIBXCRUN LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER
}

swift_sandbox_assert_xcode_test_toolchain() {
  local entry path expected observed entries driver_observed
  [[ -n "${LIDSWITCH_SWIFT_XCODE_TEST_SEAL:-}" && -n "${LIDSWITCH_SWIFT_XCODE_DRIVER_SEAL:-}" && "$LIDSWITCH_SWIFT_XCODE_TOOL_swift" == "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin/swift" && "$LIDSWITCH_SWIFT_XCODE_SDKROOT" == "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER"/SDKs/*.sdk && "$LIDSWITCH_SWIFT_XCODE_TOOL_xctest" == "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Xcode/Agents/xctest" ]] || return 74
  driver_observed="$(swift_sandbox_xcode_driver_identity "$LIDSWITCH_SWIFT_XCODE_TOOL_swift")" || return 74
  [[ "$driver_observed" == "$LIDSWITCH_SWIFT_XCODE_DRIVER_SEAL" ]] || return 74
  IFS=';' read -r -a entries <<< "$LIDSWITCH_SWIFT_XCODE_TEST_SEAL"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    path="${entry%%#*}"; expected="${entry#*#}"
    if [[ -d "$path" ]]; then observed="$(swift_sandbox_xcode_identity "$path" directory)"; else observed="$(swift_sandbox_xcode_identity "$path" file)"; fi
    [[ "$observed" == "$expected" ]] || return 74
  done
}

# A control pathname is never trusted after creation. These seals bind device,
# inode, uid, gid, mode, link count, size and content before each sensitive use.
swift_sandbox_file_identity() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || return 74
  /usr/bin/stat -f '%d:%i:%u:%g:%Lp:%l:%z' "$path" | /usr/bin/awk -F: -v uid="$(/usr/bin/id -u)" -v gid="$(/usr/bin/id -g)" '
    NF == 7 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 == uid && $4 == gid && $5 == 600 && $6 == 1 && $7 ~ /^[0-9]+$/ { print; ok=1 }
    END { if (!ok) exit 74 }'
}
swift_sandbox_seal_control_file() {
  local path="$1" key="$2" identity hash
  identity="$(swift_sandbox_file_identity "$path")" || return 74
  hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $1; ok=1} END {if (!ok) exit 74}')" || return 74
  printf -v "$key" '%s|%s' "$identity" "$hash"; export "$key"
}
swift_sandbox_assert_sealed_control_file() {
  local path="$1" expected="$2" identity hash
  identity="$(swift_sandbox_file_identity "$path")" || return 74
  hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $1; ok=1} END {if (!ok) exit 74}')" || return 74
  [[ "$identity|$hash" == "$expected" ]]
}

swift_sandbox_assert_control_root() {
  local observed observed_prefix expected_prefix observed_nlink sealed_nlink
  observed="$(swift_sandbox_root_identity "$LIDSWITCH_SWIFT_CONTROL_ROOT")" || { echo "wrapper control root is unsafe" >&2; return 74; }
  observed_prefix="${observed%:*}"
  expected_prefix="${LIDSWITCH_SWIFT_CONTROL_ID%:*}"
  observed_nlink="${observed##*:}"
  sealed_nlink="${LIDSWITCH_SWIFT_CONTROL_ID##*:}"
  # APFS increases a directory's reported link count as fixed control leaves
  # are created. The stable capability is its exact device/inode/owner/group/
  # mode; nlink may only grow from the sealed empty-root baseline.
  [[ "$observed_prefix" == "$expected_prefix" && "$observed_nlink" -ge "$sealed_nlink" ]] || {
    echo "wrapper control root identity changed" >&2; return 74
  }
}

swift_sandbox_assert_exec_root() {
  local observed
  observed="$(swift_sandbox_root_identity "$LIDSWITCH_SWIFT_EXEC_ROOT")" || { echo "sandbox execution root is unsafe" >&2; return 74; }
  [[ "$observed" == "$LIDSWITCH_SWIFT_EXEC_ID" ]] || { echo "sandbox execution root identity changed" >&2; return 74; }
}

swift_sandbox_capture_benchmark_contract() {
  local root_dir="$1" output="${LIDSWITCH_BENCHMARK_OUTPUT:-}" samples="${LIDSWITCH_BENCHMARK_WARM_SAMPLES:-}" app="${LIDSWITCH_BENCHMARK_APP_BUNDLE:-}"
  local parent name parent_name canonical_parent app_parent app_name app_root_name protected
  if [[ -z "$output" && -z "$samples" && -z "$app" ]]; then
    LIDSWITCH_SWIFT_BENCHMARK_ENABLED=0
    LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT="none"
    LIDSWITCH_SWIFT_BENCHMARK_DEST_ID="none"
    LIDSWITCH_SWIFT_BENCHMARK_OUTPUT="$LIDSWITCH_SWIFT_EXEC_ROOT/benchmark/results.jsonl"
    LIDSWITCH_SWIFT_BENCHMARK_APP="$LIDSWITCH_SWIFT_EXEC_ROOT/benchmark-disabled.app"
    LIDSWITCH_SWIFT_BENCHMARK_HELPER="$LIDSWITCH_SWIFT_EXEC_ROOT/benchmark-disabled-helper"
    export LIDSWITCH_SWIFT_BENCHMARK_ENABLED LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT LIDSWITCH_SWIFT_BENCHMARK_DEST_ID
    export LIDSWITCH_SWIFT_BENCHMARK_OUTPUT LIDSWITCH_SWIFT_BENCHMARK_APP LIDSWITCH_SWIFT_BENCHMARK_HELPER
    return 0
  fi

  [[ -n "$output" && -n "$samples" && -n "$app" ]] || { echo "partial benchmark environment is forbidden" >&2; return 64; }
  [[ "$output" == /private/tmp/* && "$output" != /tmp/* && "$samples" =~ ^[0-9]+$ && "$samples" -ge 5 && "$samples" -le 100 ]] || return 64
  parent="$(/usr/bin/dirname "$output")" || return 64
  name="$(/usr/bin/basename "$output")" || return 64
  parent_name="$(/usr/bin/basename "$parent")" || return 64
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ && "$parent_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ && "$parent" != "/private/tmp" && "$parent" == "/private/tmp/$parent_name" && "$(/usr/bin/dirname "$parent")" == "/private/tmp" && "$output" == "$parent/$name" ]] || return 64
  [[ -d "$parent" && ! -L "$parent" ]] || return 64
  canonical_parent="$(cd "$parent" && /bin/pwd -P)" || return 64
  [[ "$canonical_parent" == "$parent" && "$(/usr/bin/stat -f '%u:%g:%p' "$parent")" == "$(/usr/bin/id -u):$(/usr/bin/id -g):40700" ]] || return 64
  LIDSWITCH_SWIFT_BENCHMARK_DEST_ID="$(swift_sandbox_root_identity "$parent")" || return 64
  [[ ! -e "$output" && ! -L "$output" && "$app" == /private/tmp/* && "$app" != /tmp/* ]] || return 64
  app_parent="$(cd "$(/usr/bin/dirname "$app")" && /bin/pwd -P)" || return 64
  app_name="$(/usr/bin/basename "$app")" || return 64
  app_root_name="$(/usr/bin/basename "$app_parent")" || return 64
  [[ "$app_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,91}\.app$ && "$app_root_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || return 64
  [[ "$app_parent" != "/private/tmp" && "$(/usr/bin/dirname "$app_parent")" == "/private/tmp" && "$app" == "$app_parent/$app_name" ]] || return 64
  [[ -d "$app_parent" && ! -L "$app_parent" && "$app_parent" == "/private/tmp/$app_root_name" && "$(/usr/bin/stat -f '%u:%g:%p' "$app_parent")" == "$(/usr/bin/id -u):$(/usr/bin/id -g):40700" ]] || return 64
  [[ -d "$app" && ! -L "$app" ]] || return 64

  for protected in \
    "$root_dir" "$LIDSWITCH_SWIFT_CONTROL_ROOT" "$LIDSWITCH_SWIFT_EXEC_ROOT" \
    "$LIDSWITCH_REAL_HOME/Library/Application Support/LidSwitch" \
    "/Library/Application Support/LidSwitch" "/Applications/LidSwitch.app"; do
    [[ "$output" != "$protected" && "$output" != "$protected"/* ]] || return 64
    [[ "$app" != "$protected" && "$app" != "$protected"/* ]] || return 64
    [[ "$app_parent" != "$protected" && "$app_parent" != "$protected"/* ]] || return 64
  done

  LIDSWITCH_SWIFT_BENCHMARK_ENABLED=1
  LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT="$output"
  LIDSWITCH_SWIFT_BENCHMARK_OUTPUT="$LIDSWITCH_SWIFT_EXEC_ROOT/benchmark/results.jsonl"
  LIDSWITCH_SWIFT_BENCHMARK_APP="$app"
  LIDSWITCH_SWIFT_BENCHMARK_HELPER="/Library/Application Support/LidSwitch/Current/LidSwitchHelper"
  export LIDSWITCH_SWIFT_BENCHMARK_ENABLED LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT LIDSWITCH_SWIFT_BENCHMARK_DEST_ID
  export LIDSWITCH_SWIFT_BENCHMARK_OUTPUT LIDSWITCH_SWIFT_BENCHMARK_APP LIDSWITCH_SWIFT_BENCHMARK_HELPER
}

swift_sandbox_real_home() {
  local uid user record home
  uid="$(/usr/bin/id -u)" || return 64
  [[ "$uid" != "0" ]] || return 64
  user="$(/usr/bin/id -un)" || return 64
  record="$(/usr/bin/id -P "$user")" || return 64
  home="$(printf '%s\n' "$record" | /usr/bin/awk -F: -v uid="$uid" 'NF == 10 && $3 == uid && $9 ~ /^\// { print $9; ok=1 } END { if (!ok) exit 65 }')" || return 64
  [[ "$home" =~ ^/[A-Za-z0-9._/\ -]+$ && "$home" != "/" ]] || return 64
  printf '%s\n' "$home"
}

swift_sandbox_create_source_snapshot() {
  local root_dir="$1" snapshot_name="${2:-source}" seal
  [[ "$snapshot_name" == source || "$snapshot_name" == helper-source ]] || return 64
  seal="$(swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- snapshot-copy \
      --repo-fd 37 --manifest-fd 36 --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" \
      --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" --snapshot-name "$snapshot_name")" || return 64
  [[ "$seal" =~ ^[0-9a-f]{64}$ ]] || return 64
  if [[ "$snapshot_name" == helper-source ]]; then
    LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/helper-source"
    LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL="$seal"
    export LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL
  else
    LIDSWITCH_SWIFT_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/source"
    LIDSWITCH_SWIFT_SOURCE_SEAL="$seal"
    LIDSWITCH_SWIFT_SOURCE_NAME=source
    export LIDSWITCH_SWIFT_SOURCE_ROOT LIDSWITCH_SWIFT_SOURCE_SEAL LIDSWITCH_SWIFT_SOURCE_NAME
  fi
}

swift_sandbox_assert_named_source_snapshot() {
  local snapshot_name="$1" snapshot_seal="$2"
  [[ "$snapshot_name" == source || "$snapshot_name" == helper-source || "$snapshot_name" == app-source ]] || return 74
  [[ "$snapshot_seal" =~ ^[0-9a-f]{64}$ ]] || return 74
  swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- snapshot-verify \
      --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" \
      --snapshot-name "$snapshot_name" --expected-sha256 "$snapshot_seal"
}

swift_sandbox_select_source_snapshot() {
  local snapshot_name="$1" snapshot_seal="$2"
  swift_sandbox_assert_named_source_snapshot "$snapshot_name" "$snapshot_seal" || return 74
  LIDSWITCH_SWIFT_SOURCE_NAME="$snapshot_name"
  LIDSWITCH_SWIFT_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/$snapshot_name"
  LIDSWITCH_SWIFT_SOURCE_SEAL="$snapshot_seal"
  export LIDSWITCH_SWIFT_SOURCE_NAME LIDSWITCH_SWIFT_SOURCE_ROOT LIDSWITCH_SWIFT_SOURCE_SEAL
}

swift_sandbox_assert_source_snapshot() {
  swift_sandbox_assert_named_source_snapshot "$LIDSWITCH_SWIFT_SOURCE_NAME" "$LIDSWITCH_SWIFT_SOURCE_SEAL"
}

swift_sandbox_assert_runtime_integrity() {
  local toolchain="${1:-${LIDSWITCH_SWIFT_ACTIVE_TOOLCHAIN:-}}"
  [[ "$toolchain" == build || "$toolchain" == test ]] || return 74
  swift_sandbox_assert_control_root || return 74
  swift_sandbox_assert_exec_root || return 74
  swift_sandbox_assert_source_snapshot || return 74
  if [[ "$toolchain" == build ]]; then
    swift_sandbox_assert_developer_toolchain || return 74
  else
    swift_sandbox_assert_xcode_test_toolchain || return 74
  fi
  swift_sandbox_assert_sealed_control_file "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" "$LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL" || return 74
}

swift_sandbox_create_capture_authentication_key() {
  local key
  key="$(/usr/bin/openssl rand -hex 32)" || return 74
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 74
  # Deliberately not exported: the only transfers are short-lived parent pipes
  # to the supervisor/verifier; sandboxed Swift receives neither key nor FD.
  LIDSWITCH_SWIFT_CAPTURE_AUTH_KEY="$key"
}

swift_sandbox_capture_key_pipe() {
  [[ "${LIDSWITCH_SWIFT_CAPTURE_AUTH_KEY:-}" =~ ^[0-9a-f]{64}$ ]] || return 74
  /usr/bin/printf '%s\n' "$LIDSWITCH_SWIFT_CAPTURE_AUTH_KEY"
}

swift_sandbox_render_profile() {
  local root_dir="$1" value
  [[ -x /usr/bin/sandbox-exec && ! -L /usr/bin/sandbox-exec ]] || { echo "sandbox-exec is required for safe Swift execution" >&2; return 64; }
  for value in "$root_dir" "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_CONTROL_ROOT" "$LIDSWITCH_SWIFT_SOURCE_ROOT" "$LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT" "$LIDSWITCH_SWIFT_APP_SOURCE_ROOT" "$LIDSWITCH_REAL_HOME" "$LIDSWITCH_SWIFT_BENCHMARK_APP" "$LIDSWITCH_SWIFT_BENCHMARK_HELPER" "$LIDSWITCH_SWIFT_DEVELOPER_DIR" "$LIDSWITCH_SWIFT_SDKROOT" "$LIDSWITCH_SWIFT_TOOL_swift" "$LIDSWITCH_SWIFT_TOOL_swiftc" "$LIDSWITCH_SWIFT_TOOL_swift_frontend" "$LIDSWITCH_SWIFT_TOOL_clang" "$LIDSWITCH_SWIFT_TOOL_clangxx" "$LIDSWITCH_SWIFT_TOOL_ld" "$LIDSWITCH_SWIFT_TOOL_dsymutil" "$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" "$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER" "$LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS" "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB" "$LIDSWITCH_SWIFT_XCODE_LIBXCRUN" "$LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER" "$LIDSWITCH_SWIFT_XCODE_SDKROOT" "$LIDSWITCH_SWIFT_XCODE_TOOL_swift" "$LIDSWITCH_SWIFT_XCODE_TOOL_swiftc" "$LIDSWITCH_SWIFT_XCODE_TOOL_swift_frontend" "$LIDSWITCH_SWIFT_XCODE_TOOL_clang" "$LIDSWITCH_SWIFT_XCODE_TOOL_clangxx" "$LIDSWITCH_SWIFT_XCODE_TOOL_ld" "$LIDSWITCH_SWIFT_XCODE_TOOL_dsymutil" "$LIDSWITCH_SWIFT_XCODE_TOOL_libtool" "$LIDSWITCH_SWIFT_XCODE_TOOL_xctest" "$LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK" "$LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE" "$LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT"; do
    [[ "$value" =~ ^/[A-Za-z0-9._/\ -]+$ && "$value" != *"@"* && "$value" != *"|"* ]] || { echo "sandbox profile path contains unsupported characters" >&2; return 64; }
  done
  swift_sandbox_assert_control_root || return 64
  [[ ! -e "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" && ! -L "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" ]] || return 64
  /usr/bin/sed \
    -e "s|@EXEC_ROOT@|$LIDSWITCH_SWIFT_EXEC_ROOT|g" \
    -e "s|@CONTROL_ROOT@|$LIDSWITCH_SWIFT_CONTROL_ROOT|g" \
    -e "s|@REPO_ROOT@|$root_dir|g" \
    -e "s|@SOURCE_ROOT@|$LIDSWITCH_SWIFT_SOURCE_ROOT|g" \
    -e "s|@HELPER_SOURCE_ROOT@|$LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT|g" \
    -e "s|@APP_SOURCE_ROOT@|$LIDSWITCH_SWIFT_APP_SOURCE_ROOT|g" \
    -e "s|@REAL_HOME@|$LIDSWITCH_REAL_HOME|g" \
    -e "s|@BENCHMARK_APP@|$LIDSWITCH_SWIFT_BENCHMARK_APP|g" \
    -e "s|@BENCHMARK_HELPER@|$LIDSWITCH_SWIFT_BENCHMARK_HELPER|g" \
    -e "s|@CLT_ROOT@|$LIDSWITCH_SWIFT_DEVELOPER_DIR|g" \
    -e "s|@SDKROOT@|$LIDSWITCH_SWIFT_SDKROOT|g" \
    -e "s|@SWIFT_TOOL@|$LIDSWITCH_SWIFT_TOOL_swift|g" \
    -e "s|@SWIFTC_TOOL@|$LIDSWITCH_SWIFT_TOOL_swiftc|g" \
    -e "s|@SWIFT_FRONTEND_TOOL@|$LIDSWITCH_SWIFT_TOOL_swift_frontend|g" \
    -e "s|@CLANG_TOOL@|$LIDSWITCH_SWIFT_TOOL_clang|g" \
    -e "s|@CLANGXX_TOOL@|$LIDSWITCH_SWIFT_TOOL_clangxx|g" \
    -e "s|@LD_TOOL@|$LIDSWITCH_SWIFT_TOOL_ld|g" \
    -e "s|@DSYMUTIL_TOOL@|$LIDSWITCH_SWIFT_TOOL_dsymutil|g" \
    -e "s|@XCODE_DEVELOPER@|$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR|g" \
    -e "s|@XCODE_TOOLCHAIN@|$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT|g" \
    -e "s|@XCODE_PLATFORM_DEVELOPER@|$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER|g" \
    -e "s|@XCODE_SHARED_FRAMEWORKS@|$LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS|g" \
    -e "s|@XCODE_PLATFORM_FRAMEWORKS@|$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS|g" \
    -e "s|@XCODE_PLATFORM_PRIVATE_FRAMEWORKS@|$LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS|g" \
    -e "s|@XCODE_PLATFORM_USR_LIB@|$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB|g" \
    -e "s|@XCODE_LIBXCRUN@|$LIDSWITCH_SWIFT_XCODE_LIBXCRUN|g" \
    -e "s|@XCODE_SWIFT_PLUGIN_SERVER@|$LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER|g" \
    -e "s|@XCODE_SDKROOT@|$LIDSWITCH_SWIFT_XCODE_SDKROOT|g" \
    -e "s|@XCODE_SWIFT_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_swift|g" \
    -e "s|@XCODE_SWIFTC_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_swiftc|g" \
    -e "s|@XCODE_SWIFT_FRONTEND_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_swift_frontend|g" \
    -e "s|@XCODE_CLANG_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_clang|g" \
    -e "s|@XCODE_CLANGXX_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_clangxx|g" \
    -e "s|@XCODE_LD_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_ld|g" \
    -e "s|@XCODE_DSYMUTIL_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_dsymutil|g" \
    -e "s|@XCODE_LIBTOOL_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_libtool|g" \
    -e "s|@XCODE_XCTEST_TOOL@|$LIDSWITCH_SWIFT_XCODE_TOOL_xctest|g" \
    -e "s|@XCODE_XCTEST_FRAMEWORK@|$LIDSWITCH_SWIFT_XCODE_XCTEST_FRAMEWORK|g" \
    -e "s|@XCODE_XCTEST_MODULE@|$LIDSWITCH_SWIFT_XCODE_XCTEST_MODULE|g" \
    -e "s|@XCODE_XCTEST_SUPPORT@|$LIDSWITCH_SWIFT_XCODE_XCTEST_SUPPORT|g" \
    <&33 > "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
  [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$LIDSWITCH_SWIFT_SANDBOX_PROFILE")" == "$(/usr/bin/id -u):600:1" ]] || { echo "generated sandbox profile metadata is unsafe" >&2; return 64; }
  /usr/bin/grep -Fq "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
  /usr/bin/grep -Fq "$LIDSWITCH_SWIFT_CONTROL_ROOT" "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
  /usr/bin/grep -Fq "$root_dir" "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
  /usr/bin/grep -Fq "$LIDSWITCH_REAL_HOME" "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
  ! /usr/bin/grep -Eq '@(EXEC_ROOT|CONTROL_ROOT|REPO_ROOT|SOURCE_ROOT|HELPER_SOURCE_ROOT|APP_SOURCE_ROOT|REAL_HOME|BENCHMARK_APP|BENCHMARK_HELPER|CLT_ROOT|SDKROOT|SWIFT_TOOL|SWIFTC_TOOL|SWIFT_FRONTEND_TOOL|CLANG_TOOL|CLANGXX_TOOL|LD_TOOL|DSYMUTIL_TOOL|XCODE_[A-Z_]+)@' "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" || return 64
}

swift_sandbox_setup() {
  local root_dir="$1" mode="${2:-test}" leaf candidate protected helper metadata expected_helper_metadata
  local -a execution_leaves
  [[ "$mode" == test || "$mode" == release ]] || return 64
  LIDSWITCH_SWIFT_SETUP_MODE="$mode"
  export LIDSWITCH_SWIFT_SETUP_MODE
  LIDSWITCH_REAL_HOME="$(swift_sandbox_real_home)" || { echo "could not resolve the real account home" >&2; return 64; }
  local user_support="$LIDSWITCH_REAL_HOME/Library/Application Support/LidSwitch"
  local root_support="/Library/Application Support/LidSwitch"
  [[ ! -L /private/tmp && -d /private/tmp ]] || { echo "literal /private/tmp is unsafe" >&2; return 64; }
  [[ "$(/usr/bin/stat -f '%u:%g:%p' /private/tmp)" == "0:0:41777" ]] || { echo "literal /private/tmp is not root-owned/root-group sticky 1777" >&2; return 64; }
  umask 077
  if [[ "${LIDSWITCH_HELD_CONTROL_ROOT:-}" == /private/tmp/lidswitch-envelope.* && "${LIDSWITCH_HELD_EXECUTION_ROOT:-}" == /private/tmp/lidswitch-swift.* ]]; then
    LIDSWITCH_SWIFT_CONTROL_ROOT="$LIDSWITCH_HELD_CONTROL_ROOT"
    LIDSWITCH_SWIFT_EXEC_ROOT="$LIDSWITCH_HELD_EXECUTION_ROOT"
    [[ -d "$LIDSWITCH_SWIFT_CONTROL_ROOT" && -d "$LIDSWITCH_SWIFT_EXEC_ROOT" && ! -L "$LIDSWITCH_SWIFT_CONTROL_ROOT" && ! -L "$LIDSWITCH_SWIFT_EXEC_ROOT" ]] || return 64
  else
    return 64
  fi
  LIDSWITCH_SWIFT_SANDBOX_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT"

  execution_leaves=(tmp home module-cache swift-cache swift-config swift-security fixtures benchmark logs)
  if [[ "$mode" == release ]]; then
    execution_leaves+=(helper-scratch app-scratch helper-source app-source release-output)
  else
    execution_leaves+=(swift-scratch source)
  fi
  for leaf in "${execution_leaves[@]}"; do
    /bin/mkdir -m 700 "$LIDSWITCH_SWIFT_EXEC_ROOT/$leaf" || return 64
    [[ ! -L "$LIDSWITCH_SWIFT_EXEC_ROOT/$leaf" && -d "$LIDSWITCH_SWIFT_EXEC_ROOT/$leaf" && "$(/usr/bin/stat -f '%u:%p' "$LIDSWITCH_SWIFT_EXEC_ROOT/$leaf")" == "$(/usr/bin/id -u):40700" ]] || {
      echo "unsafe execution-root child" >&2; return 64
    }
  done
  for candidate in "$LIDSWITCH_SWIFT_CONTROL_ROOT" "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_EXEC_ROOT/tmp" "$LIDSWITCH_SWIFT_EXEC_ROOT/home" "$LIDSWITCH_SWIFT_EXEC_ROOT/module-cache" "$LIDSWITCH_SWIFT_EXEC_ROOT/swift-scratch" "$LIDSWITCH_SWIFT_EXEC_ROOT/helper-scratch" "$LIDSWITCH_SWIFT_EXEC_ROOT/app-scratch" "$LIDSWITCH_SWIFT_EXEC_ROOT/helper-source" "$LIDSWITCH_SWIFT_EXEC_ROOT/app-source" "$LIDSWITCH_SWIFT_EXEC_ROOT/release-output"; do
    [[ -e "$candidate" ]] || continue
    for protected in "$root_dir" "$user_support" "$root_support" "/Applications/LidSwitch.app"; do
      [[ "$candidate" != "$protected" && "$candidate" != "$protected"/* ]] || { echo "safe wrapper path overlaps a protected root" >&2; return 64; }
    done
  done
  expected_helper_metadata="$(/usr/bin/id -u):$(/usr/bin/id -g):644:1"
  for helper in "$root_dir/script/safe_file_capability.py" "$root_dir/script/safe_process_supervisor.py"; do
    [[ -f "$helper" && ! -L "$helper" ]] || { echo "safe wrapper helper is missing or unsafe" >&2; return 64; }
    metadata="$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$helper")" || return 64
    [[ "$metadata" == "$expected_helper_metadata" ]] || { echo "safe wrapper helper metadata is unsafe" >&2; return 64; }
  done

  LIDSWITCH_SWIFT_ENVELOPE_NONCE="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')" || return 64
  [[ "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || return 64
  export LIDSWITCH_SWIFT_SANDBOX_ROOT LIDSWITCH_SWIFT_EXEC_ROOT LIDSWITCH_SWIFT_CONTROL_ROOT
  export LIDSWITCH_REAL_HOME LIDSWITCH_SWIFT_ENVELOPE_NONCE
  export HOME="$LIDSWITCH_SWIFT_EXEC_ROOT/home"
  export CFFIXED_USER_HOME="$HOME"
  export TMPDIR="$LIDSWITCH_SWIFT_EXEC_ROOT/tmp"
  export XDG_CACHE_HOME="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-cache"
  export XDG_CONFIG_HOME="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-config"
  export CLANG_MODULE_CACHE_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/module-cache"
  export SWIFT_MODULECACHE_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/module-cache"
  if [[ "$mode" == release ]]; then
    export LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/helper-scratch"
    export LIDSWITCH_SWIFT_APP_SCRATCH_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/app-scratch"
    export LIDSWITCH_SWIFT_SCRATCH_PATH="$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH"
    export LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/helper-source"
    export LIDSWITCH_SWIFT_APP_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/app-source"
    export LIDSWITCH_SWIFT_RELEASE_OUTPUT_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/release-output"
  else
    export LIDSWITCH_SWIFT_SCRATCH_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-scratch"
    export LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/source"
    export LIDSWITCH_SWIFT_APP_SOURCE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/source"
    export LIDSWITCH_SWIFT_RELEASE_OUTPUT_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/source"
  fi
  export LIDSWITCH_SWIFTPM_CACHE_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-cache"
  export LIDSWITCH_SWIFTPM_CONFIG_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-config"
  export LIDSWITCH_SWIFTPM_SECURITY_PATH="$LIDSWITCH_SWIFT_EXEC_ROOT/swift-security"
  export LIDSWITCH_SWIFT_SANDBOX_PROFILE="$LIDSWITCH_SWIFT_CONTROL_ROOT/swift-test.sb"
  export LIDSWITCH_SWIFT_PREFLIGHT="$LIDSWITCH_SWIFT_CONTROL_ROOT/live-preflight.kv"
  export LIDSWITCH_SWIFT_POSTFLIGHT="$LIDSWITCH_SWIFT_CONTROL_ROOT/live-postflight.kv"
  export LIDSWITCH_TEST_FIXTURE_ROOT="$LIDSWITCH_SWIFT_EXEC_ROOT/fixtures"
  # Seal roots only after their complete host-created topology exists; the
  # identity includes gid and directory link count and is then immutable.
  LIDSWITCH_SWIFT_CONTROL_ID="$(swift_sandbox_root_identity "$LIDSWITCH_SWIFT_CONTROL_ROOT")" || return 64
  LIDSWITCH_SWIFT_EXEC_ID="$(swift_sandbox_root_identity "$LIDSWITCH_SWIFT_EXEC_ROOT")" || return 64
  export LIDSWITCH_SWIFT_CONTROL_ID LIDSWITCH_SWIFT_EXEC_ID
  swift_sandbox_create_capture_authentication_key || return 74
  swift_sandbox_capture_developer_toolchain || return 64
  if [[ "$mode" == release ]]; then
    swift_sandbox_create_source_snapshot "$root_dir" helper-source || return 64
    swift_sandbox_select_source_snapshot helper-source "$LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL" || return 64
    swift_sandbox_bind_release_profile_placeholders || return 64
  else
    swift_sandbox_create_source_snapshot "$root_dir" source || return 64
    swift_sandbox_capture_xcode_test_toolchain || return 64
  fi
  swift_sandbox_capture_benchmark_contract "$root_dir" || return 64
  swift_sandbox_render_profile "$root_dir" || return 64
  swift_sandbox_seal_control_file "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL || return 64
}

swift_sandbox_capture_source_value() {
  local capture_name="$1" field="$2" key
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ && ( "$field" == NAME || "$field" == SEAL ) ]] || return 74
  key="LIDSWITCH_SWIFT_CAPTURE_SOURCE_${field}_${capture_name//-/_}"
  [[ -n "${!key:-}" ]] || return 74
  printf '%s\n' "${!key}"
}

swift_sandbox_register_capture_source() {
  local capture_name="$1" name_key seal_key
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 74
  [[ "$LIDSWITCH_SWIFT_SOURCE_NAME" == source || "$LIDSWITCH_SWIFT_SOURCE_NAME" == helper-source || "$LIDSWITCH_SWIFT_SOURCE_NAME" == app-source ]] || return 74
  [[ "$LIDSWITCH_SWIFT_SOURCE_SEAL" =~ ^[0-9a-f]{64}$ ]] || return 74
  name_key="LIDSWITCH_SWIFT_CAPTURE_SOURCE_NAME_${capture_name//-/_}"
  seal_key="LIDSWITCH_SWIFT_CAPTURE_SOURCE_SEAL_${capture_name//-/_}"
  printf -v "$name_key" '%s' "$LIDSWITCH_SWIFT_SOURCE_NAME"
  printf -v "$seal_key" '%s' "$LIDSWITCH_SWIFT_SOURCE_SEAL"
  export "$name_key" "$seal_key"
}

swift_sandbox_supervise() {
  local capture_name="$1" toolchain="$2" supervisor_status=0; shift 2
  local -a environment=()
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ && ( "$toolchain" == build || "$toolchain" == test ) ]] || return 64
  while [[ "${1:-}" != -- ]]; do
    [[ $# -gt 0 && "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 64
    environment+=("$1")
    shift
  done
  shift
  [[ $# -ge 3 && "$1" == /usr/bin/arch && "$2" == -arm64 ]] || return 64
  LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED=false
  LIDSWITCH_SWIFT_CHILD_EXIT=256
  LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME=unavailable
  LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL=false
  LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED=false
  export LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED LIDSWITCH_SWIFT_CHILD_EXIT LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED
  swift_sandbox_assert_runtime_integrity "$toolchain" || return 74
  swift_sandbox_capture_key_pipe | swift_sandbox_verified_python supervisor "${environment[@]}" -- \
      --profile "$LIDSWITCH_SWIFT_SANDBOX_PROFILE" \
      --stdout "$LIDSWITCH_SWIFT_EXEC_ROOT/logs/$capture_name.stdout" --stderr "$LIDSWITCH_SWIFT_EXEC_ROOT/logs/$capture_name.stderr" \
      --seal "$LIDSWITCH_SWIFT_CONTROL_ROOT/capture-$capture_name.seal" \
      --result "$LIDSWITCH_SWIFT_CONTROL_ROOT/supervisor-$capture_name.result" \
      --capture "$capture_name" --control-identity "$LIDSWITCH_SWIFT_CONTROL_ID" --execution-identity "$LIDSWITCH_SWIFT_EXEC_ID" \
      --nonce "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" --profile-seal "$LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL" --source-seal "$LIDSWITCH_SWIFT_SOURCE_SEAL" \
      --cleanup-source-root "$LIDSWITCH_SWIFT_SOURCE_ROOT" \
      "$@" || supervisor_status=$?
  swift_sandbox_register_capture_source "$capture_name" || return 74
  swift_sandbox_read_supervisor_result "$capture_name" || return 74
  [[ "$supervisor_status" == 0 && "$LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED" == true && "$LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME" == completed && "$LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED" == true && "$LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL" == true && "$LIDSWITCH_SWIFT_CHILD_EXIT" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] || return 74
}

swift_sandbox_run() {
  local capture_name="$1" swift_subcommand="$2" execution_mode="$3" selected_path selected_developer selected_sdk selected_swift toolchain package_root; shift 3
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 64
  [[ "$swift_subcommand" == build ]] || return 64
  [[ "$execution_mode" == test-build || "$execution_mode" == release-helper || "$execution_mode" == release-app ]] || return 64
  if [[ "$execution_mode" == test-build ]]; then
    selected_path="$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    selected_developer="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"
    selected_sdk="$LIDSWITCH_SWIFT_XCODE_SDKROOT"
    selected_swift="$LIDSWITCH_SWIFT_XCODE_TOOL_swift"
    toolchain=test
    package_root="$LIDSWITCH_SWIFT_SOURCE_ROOT"
  else
    selected_path="$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    selected_developer="$LIDSWITCH_SWIFT_DEVELOPER_DIR"
    selected_sdk="$LIDSWITCH_SWIFT_SDKROOT"
    selected_swift="$LIDSWITCH_SWIFT_TOOL_swift"
    toolchain=build
    if [[ "$execution_mode" == release-helper ]]; then
      swift_sandbox_select_source_snapshot helper-source "$LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL" || return 74
      package_root="$LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT"
    else
      swift_sandbox_select_source_snapshot app-source "$LIDSWITCH_SWIFT_APP_SOURCE_SEAL" || return 74
      package_root="$LIDSWITCH_SWIFT_APP_SOURCE_ROOT"
    fi
  fi
  LIDSWITCH_SWIFT_ACTIVE_TOOLCHAIN="$toolchain"
  local environment=(
    PATH="$selected_path" LC_ALL=C
    HOME="$HOME" CFFIXED_USER_HOME="$CFFIXED_USER_HOME" TMPDIR="$TMPDIR"
    XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
    CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH"
    SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH"
    DEVELOPER_DIR="$selected_developer"
    SDKROOT="$selected_sdk"
    LIDSWITCH_TEST_FIXTURE_ROOT="$LIDSWITCH_TEST_FIXTURE_ROOT"
  )
  if [[ "$execution_mode" == test-build ]]; then
    # Bind SwiftPM's platform lookup to the exact macOS platform already sealed
    # above; no sandboxed tool-discovery subprocess is needed.
    environment+=(SWIFTPM_PLATFORM_PATH_macosx="${LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER%/Developer}")
  fi
  if [[ "$execution_mode" == release-app ]]; then
    environment+=(LIDSWITCH_RELEASE_CANDIDATE=1)
  fi
  if [[ "$LIDSWITCH_SWIFT_BENCHMARK_ENABLED" == "1" ]]; then
    environment+=(
      LIDSWITCH_BENCHMARK_OUTPUT="$LIDSWITCH_SWIFT_BENCHMARK_OUTPUT"
      LIDSWITCH_BENCHMARK_WARM_SAMPLES="${LIDSWITCH_BENCHMARK_WARM_SAMPLES}"
      LIDSWITCH_BENCHMARK_APP_BUNDLE="$LIDSWITCH_SWIFT_BENCHMARK_APP"
    )
  fi
  swift_sandbox_supervise "$capture_name" "$toolchain" "${environment[@]}" -- \
      /usr/bin/arch -arm64 "$selected_swift" "$swift_subcommand" --disable-sandbox --package-path "$package_root" "$@"
}

swift_sandbox_assert_xctest_bundle() {
  local bundle="$LIDSWITCH_SWIFT_SCRATCH_PATH/arm64-apple-macosx/debug/LidSwitchPackageTests.xctest"
  local executable="$bundle/Contents/MacOS/LidSwitchPackageTests" canonical metadata mode
  [[ -d "$bundle" && ! -L "$bundle" && -f "$executable" && ! -L "$executable" && -x "$executable" ]] || return 74
  canonical="$(cd "$bundle" && /bin/pwd -P)" || return 74
  [[ "$canonical" == "$bundle" ]] || return 74
  canonical="$(cd "$(/usr/bin/dirname "$executable")" && /bin/pwd -P)/$(/usr/bin/basename "$executable")" || return 74
  [[ "$canonical" == "$executable" ]] || return 74
  metadata="$(/usr/bin/stat -f '%u:%g:%Lp:%l:%z' "$executable")" || return 74
  [[ "$metadata" =~ ^$(/usr/bin/id -u):$(/usr/bin/id -g):[0-7]{3,6}:1:[1-9][0-9]*$ ]] || return 74
  mode="${metadata#*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 )) || return 74
  printf '%s\n' "$bundle"
}

swift_sandbox_run_xctest() {
  local capture_name="$1" selector="${2:-}" bundle selected_path
  local -a command
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 64
  [[ -z "$selector" || "$selector" =~ ^LidSwitchTests\.[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
  LIDSWITCH_SWIFT_ACTIVE_TOOLCHAIN=test
  swift_sandbox_assert_runtime_integrity test || return 74
  bundle="$(swift_sandbox_assert_xctest_bundle)" || return 74
  selected_path="$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  command=(/usr/bin/arch -arm64 "$LIDSWITCH_SWIFT_XCODE_TOOL_xctest")
  [[ -z "$selector" ]] || command+=(-XCTest "$selector")
  command+=("$bundle")
  swift_sandbox_supervise "$capture_name" test \
      PATH="$selected_path" LC_ALL=C \
      HOME="$HOME" CFFIXED_USER_HOME="$CFFIXED_USER_HOME" TMPDIR="$TMPDIR" \
      XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
      CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" \
      DEVELOPER_DIR="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" SDKROOT="$LIDSWITCH_SWIFT_XCODE_SDKROOT" \
      SWIFTPM_PLATFORM_PATH_macosx="${LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER%/Developer}" \
      DYLD_FRAMEWORK_PATH="$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS:$LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS" \
      DYLD_LIBRARY_PATH="$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB" SWIFT_TESTING_ENABLED=0 \
      LIDSWITCH_TEST_FIXTURE_ROOT="$LIDSWITCH_TEST_FIXTURE_ROOT" \
      LIDSWITCH_SWIFT_EXEC_ID="$LIDSWITCH_SWIFT_EXEC_ID" -- "${command[@]}"
}

swift_sandbox_supervisor_action() {
  local capture_name="$1" source_seal
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 74
  source_seal="$(swift_sandbox_capture_source_value "$capture_name" SEAL)" || return 74
  swift_sandbox_capture_key_pipe | swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- supervisor-result \
      --control-root "$LIDSWITCH_SWIFT_CONTROL_ROOT" --control-identity "$LIDSWITCH_SWIFT_CONTROL_ID" \
      --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" \
      --capture "$capture_name" --nonce "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" \
      --profile-seal "$LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL" --source-seal "$source_seal"
}

swift_sandbox_read_supervisor_result() {
  local capture_name="$1" output lines
  output="$(swift_sandbox_supervisor_action "$capture_name")" || return 74
  lines=()
  while IFS= read -r line; do lines+=("$line"); done <<< "$output"
  [[ "${#lines[@]}" == 6 && "${lines[0]}" =~ ^launched=(true|false)$ && "${lines[1]}" =~ ^leader_exit=(none|[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ && "${lines[2]}" =~ ^outcome=(completed|setup-failed|launch-failed|containment-failed|capture-seal-failed|interrupted)$ && "${lines[3]}" =~ ^capture_seal=(true|false)$ && "${lines[4]}" =~ ^child_command_exit=([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-6])$ && "${lines[5]}" =~ ^completed=(true|false)$ ]] || return 74
  LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED="${lines[0]#launched=}"
  LIDSWITCH_SWIFT_CHILD_EXIT="${lines[4]#child_command_exit=}"
  LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME="${lines[2]#outcome=}"
  LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL="${lines[3]#capture_seal=}"
  LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED="${lines[5]#completed=}"
  export LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED LIDSWITCH_SWIFT_CHILD_EXIT LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED
}

swift_sandbox_assert_supervisor_result() {
  swift_sandbox_read_supervisor_result "$1" || return 74
  [[ "$LIDSWITCH_SWIFT_SUPERVISOR_LAUNCHED" == true && "$LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED" == true && "$LIDSWITCH_SWIFT_SUPERVISOR_OUTCOME" == completed && "$LIDSWITCH_SWIFT_SUPERVISOR_CAPTURE_SEAL" == true && "$LIDSWITCH_SWIFT_CHILD_EXIT" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
}

swift_sandbox_authenticated_child_exit_or_untrusted() {
  [[ "$LIDSWITCH_SWIFT_CHILD_EXIT" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-6])$ ]] && printf '%s\n' "$LIDSWITCH_SWIFT_CHILD_EXIT" || printf '256\n'
}

swift_sandbox_capture_action() {
  local action="$1" capture_name="$2" stream="$3" source_seal
  [[ "$action" == capture-verify || "$action" == capture-read || "$action" == capture-identifier ]] || return 74
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ && ( "$stream" == stdout || "$stream" == stderr ) ]] || return 74
  source_seal="$(swift_sandbox_capture_source_value "$capture_name" SEAL)" || return 74
  swift_sandbox_capture_key_pipe | swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- "$action" \
      --control-root "$LIDSWITCH_SWIFT_CONTROL_ROOT" --control-identity "$LIDSWITCH_SWIFT_CONTROL_ID" \
      --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" \
      --capture "$capture_name" --stream "$stream" --nonce "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" \
      --profile-seal "$LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL" --source-seal "$source_seal"
}

swift_sandbox_capture_identifier() {
  local capture_name="$1" identifier
  identifier="$(swift_sandbox_capture_action capture-identifier "$capture_name" stdout)" || return 74
  [[ "$identifier" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] || return 74
  printf '%s\n' "$identifier"
}

swift_sandbox_assert_capture_seal() {
  local capture_name="$1" source_name source_seal
  source_name="$(swift_sandbox_capture_source_value "$capture_name" NAME)" || return 74
  source_seal="$(swift_sandbox_capture_source_value "$capture_name" SEAL)" || return 74
  swift_sandbox_assert_runtime_integrity || return 74
  swift_sandbox_assert_named_source_snapshot "$source_name" "$source_seal" || return 74
  swift_sandbox_capture_action capture-verify "$capture_name" stdout || return 74
  swift_sandbox_capture_action capture-verify "$capture_name" stderr || return 74
}

swift_sandbox_reassert_before_sensitive_host_action() {
  local capture_name
  swift_sandbox_assert_runtime_integrity || return 74
  for capture_name in "$@"; do
    swift_sandbox_assert_supervisor_result "$capture_name" || return 74
    swift_sandbox_assert_capture_seal "$capture_name" || return 74
  done
}

swift_sandbox_emit_captured_output() {
  local capture_name="$1"
  swift_sandbox_reassert_before_sensitive_host_action "$capture_name" || return 74
  swift_sandbox_capture_action capture-read "$capture_name" stdout
  swift_sandbox_capture_action capture-read "$capture_name" stderr >&2
}

swift_sandbox_emit_captured_stderr() {
  swift_sandbox_reassert_before_sensitive_host_action "$1" || return 74
  swift_sandbox_capture_action capture-read "$1" stderr >&2
}

swift_sandbox_read_bin_path() {
  local capture_name="${1:-bin-path}" scratch_root="${2:-$LIDSWITCH_SWIFT_SCRATCH_PATH}" value
  [[ "$capture_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 74
  [[ "$scratch_root" == "$LIDSWITCH_SWIFT_EXEC_ROOT"/* && "$scratch_root" != *"/../"* ]] || return 74
  swift_sandbox_reassert_before_sensitive_host_action "$capture_name" || return 74
  value="$(swift_sandbox_capture_action capture-read "$capture_name" stdout | /usr/bin/awk 'NR == 1 { value=$0 } END { if (NR != 1 || value !~ /^\/private\/tmp\/lidswitch-swift\.[A-Za-z0-9_]{6,32}\/[A-Za-z0-9._\/-]+$/) exit 74; print value }')" || return 74
  [[ "$value" == "$scratch_root"/* ]] || return 74
  [[ "$value" != *"//"* && "$value" != *"/./"* && "$value" != *"/../"* && "$value" != */. && "$value" != */.. ]] || return 74
  printf '%s\n' "$value"
}

swift_sandbox_assert_release_binary_path() {
  local kind="$1" path="$2" expected_prefix canonical metadata mode
  case "$kind" in
    helper) expected_prefix="$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH" ;;
    app) expected_prefix="$LIDSWITCH_SWIFT_APP_SCRATCH_PATH" ;;
    *) return 74 ;;
  esac
  [[ "$path" == "$expected_prefix"/* && -f "$path" && ! -L "$path" && -x "$path" ]] || return 74
  canonical="$(cd "$(/usr/bin/dirname "$path")" && /bin/pwd -P)/$(/usr/bin/basename "$path")" || return 74
  [[ "$canonical" == "$path" ]] || return 74
  metadata="$(/usr/bin/stat -f '%u:%g:%Lp:%l:%z' "$path")" || return 74
  [[ "$metadata" =~ ^$(/usr/bin/id -u):$(/usr/bin/id -g):[0-7]{3,6}:1:[1-9][0-9]*$ ]] || return 74
  mode="${metadata#*:*:}"; mode="${mode%%:*}"
  (( (8#$mode & 8#022) == 0 && (8#$mode & 8#111) != 0 ))
}

swift_sandbox_sign_release_helper() {
  local capture_name="$1" helper_path="$2"
  swift_sandbox_assert_release_binary_path helper "$helper_path" || return 74
  swift_sandbox_supervise "$capture_name" build PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- \
      /usr/bin/arch -arm64 /usr/bin/codesign --force --sign - \
      --identifier com.johnsilva.lidswitch.helper --timestamp=none "$helper_path"
}

swift_sandbox_verify_release_helper() {
  local capture_name="$1" helper_path="$2"
  swift_sandbox_assert_release_binary_path helper "$helper_path" || return 74
  swift_sandbox_supervise "$capture_name" build PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- \
      /usr/bin/arch -arm64 /usr/bin/codesign --verify --strict --verbose=4 "$helper_path"
}

swift_sandbox_inspect_release_helper() {
  local capture_name="$1" helper_path="$2"
  swift_sandbox_assert_release_binary_path helper "$helper_path" || return 74
  swift_sandbox_supervise "$capture_name" build PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- \
      /usr/bin/arch -arm64 /usr/bin/codesign -d --verbose=4 "$helper_path"
}

swift_sandbox_read_release_helper_cdhash() {
  local capture_name="$1" details
  swift_sandbox_reassert_before_sensitive_host_action "$capture_name" || return 74
  details="$(swift_sandbox_capture_action capture-read "$capture_name" stderr)" || return 74
  printf '%s\n' "$details" | /usr/bin/awk -F= '
    $1 == "Identifier" { identifier=$2; identifiers += 1 }
    $1 == "CDHash" { cdhash=$2; cdhashes += 1 }
    $1 == "Signature" { signature=$2; signatures += 1 }
    $1 == "TeamIdentifier" { team=$2; teams += 1 }
    END {
      if (identifiers != 1 || identifier != "com.johnsilva.lidswitch.helper" ||
          cdhashes != 1 || cdhash !~ /^[0-9a-f]{40}$/ ||
          signatures != 1 || signature != "adhoc" || teams != 1 || team != "not set") exit 74
      print cdhash
    }'
}

swift_sandbox_derive_release_app_source() {
  local helper_relative="$1" helper_cdhash="$2" output line
  local -a lines
  swift_sandbox_assert_named_source_snapshot helper-source "$LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL" || return 74
  output="$(swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- release-derive-source \
      --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" --manifest-fd 36 \
      --helper-source-seal "$LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL" --helper-relative "$helper_relative" \
      --helper-identifier com.johnsilva.lidswitch.helper --helper-cdhash "$helper_cdhash")" || return 74
  lines=(); while IFS= read -r line; do lines+=("$line"); done <<< "$output"
  [[ "${#lines[@]}" == 9 && "${lines[0]}" == schema=lidswitch-release-derive-v1 ]] || return 74
  [[ "${lines[1]}" =~ ^helper_sha256=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_RELEASE_HELPER_SHA256="${lines[1]#*=}"
  [[ "${lines[2]}" =~ ^helper_size=([1-9][0-9]*)$ ]] || return 74; LIDSWITCH_RELEASE_HELPER_SIZE="${lines[2]#*=}"
  [[ "${lines[3]}" == "helper_cdhash=$helper_cdhash" ]] || return 74
  [[ "${lines[4]}" =~ ^release_identity_sha256=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_RELEASE_IDENTITY_SHA256="${lines[4]#*=}"
  [[ "${lines[5]}" =~ ^template_sha256=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_RELEASE_TEMPLATE_SHA256="${lines[5]#*=}"
  [[ "${lines[6]}" =~ ^anchor_sha256=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_RELEASE_ANCHOR_SHA256="${lines[6]#*=}"
  [[ "${lines[7]}" =~ ^manifest_sha256=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_RELEASE_MANIFEST_SHA256="${lines[7]#*=}"
  [[ "${lines[8]}" =~ ^app_source_seal=([0-9a-f]{64})$ ]] || return 74; LIDSWITCH_SWIFT_APP_SOURCE_SEAL="${lines[8]#*=}"
  export LIDSWITCH_RELEASE_HELPER_SHA256 LIDSWITCH_RELEASE_HELPER_SIZE LIDSWITCH_RELEASE_IDENTITY_SHA256
  export LIDSWITCH_RELEASE_TEMPLATE_SHA256 LIDSWITCH_RELEASE_ANCHOR_SHA256 LIDSWITCH_RELEASE_MANIFEST_SHA256
  export LIDSWITCH_SWIFT_APP_SOURCE_SEAL
  swift_sandbox_select_source_snapshot app-source "$LIDSWITCH_SWIFT_APP_SOURCE_SEAL"
}

swift_sandbox_publish_release_output() {
  local helper_relative="$1" app_relative="$2" helper_cdhash="$3" captures="$4"
  local toolchain_seal_sha256 profile_sha256 output line
  local -a lines
  toolchain_seal_sha256="$(/usr/bin/printf '%s' "$LIDSWITCH_SWIFT_DEVELOPER_SEAL" | /usr/bin/shasum -a 256 | /usr/bin/awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $1; ok=1} END {if (!ok) exit 74}')" || return 74
  profile_sha256="${LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL##*|}"
  [[ "$profile_sha256" =~ ^[0-9a-f]{64}$ ]] || return 74
  output="$(swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- release-publish \
      --exec-root "$LIDSWITCH_SWIFT_EXEC_ROOT" --exec-identity "$LIDSWITCH_SWIFT_EXEC_ID" --manifest-fd 36 \
      --helper-source-seal "$LIDSWITCH_SWIFT_HELPER_SOURCE_SEAL" --app-source-seal "$LIDSWITCH_SWIFT_APP_SOURCE_SEAL" \
      --helper-relative "$helper_relative" --app-relative "$app_relative" \
      --helper-sha256 "$LIDSWITCH_RELEASE_HELPER_SHA256" --helper-size "$LIDSWITCH_RELEASE_HELPER_SIZE" \
      --helper-cdhash "$helper_cdhash" --anchor-sha256 "$LIDSWITCH_RELEASE_ANCHOR_SHA256" \
      --template-sha256 "$LIDSWITCH_RELEASE_TEMPLATE_SHA256" \
      --release-identity-sha256 "$LIDSWITCH_RELEASE_IDENTITY_SHA256" --manifest-sha256 "$LIDSWITCH_RELEASE_MANIFEST_SHA256" \
      --capture-identifiers "$captures" --profile-sha256 "$profile_sha256" \
      --toolchain-root "$LIDSWITCH_SWIFT_DEVELOPER_DIR" --toolchain-sdk "$LIDSWITCH_SWIFT_SDKROOT" \
      --toolchain-driver-seal "$LIDSWITCH_SWIFT_DRIVER_SEAL" --toolchain-seal-sha256 "$toolchain_seal_sha256")" || return 74
  lines=(); while IFS= read -r line; do lines+=("$line"); done <<< "$output"
  [[ "${#lines[@]}" == 5 && "${lines[0]}" == schema=lidswitch-release-output-v1 ]] || return 74
  [[ "${lines[1]}" == "release_output=$LIDSWITCH_SWIFT_RELEASE_OUTPUT_ROOT" ]] || return 74
  [[ "${lines[2]}" =~ ^release_output_seal=([0-9a-f]{64})$ ]] || return 74
  [[ "${lines[3]}" =~ ^app_sha256=([0-9a-f]{64})$ ]] || return 74
  [[ "${lines[4]}" =~ ^app_size=([1-9][0-9]*)$ ]] || return 74
  LIDSWITCH_RELEASE_OUTPUT_SEAL="${lines[2]#*=}"
  export LIDSWITCH_RELEASE_OUTPUT_SEAL
}

swift_sandbox_publish_benchmark() {
  [[ "$LIDSWITCH_SWIFT_BENCHMARK_ENABLED" == "1" ]] || return 0
  swift_sandbox_reassert_before_sensitive_host_action test-main || return 74
  [[ ! -e "$LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT" && ! -L "$LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT" ]] || return 74
  swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- copy-new \
      --source-root "$LIDSWITCH_SWIFT_EXEC_ROOT" \
      --source-identity "$LIDSWITCH_SWIFT_EXEC_ID" \
      --destination "$LIDSWITCH_SWIFT_BENCHMARK_REQUESTED_OUTPUT" \
      --destination-identity "$LIDSWITCH_SWIFT_BENCHMARK_DEST_ID" \
      --benchmark-app "$LIDSWITCH_SWIFT_BENCHMARK_APP" \
      --benchmark-helper "$LIDSWITCH_SWIFT_BENCHMARK_HELPER" \
      --max-bytes 33554432
}
