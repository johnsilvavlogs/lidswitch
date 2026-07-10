import Darwin

guard getuid() == 0 else {
    fputs("LidSwitchHelper must run as root.\n", stderr)
    exit(0)
}
guard let configuration = HelperConfiguration.parse(arguments: CommandLine.arguments) else {
    fputs("Invalid LidSwitchHelper configuration.\n", stderr)
    // Configuration failure is handled and persistent; do not trigger launchd's
    // crash-only KeepAlive loop.
    exit(0)
}
exit(HelperRuntime(configuration: configuration).run())
