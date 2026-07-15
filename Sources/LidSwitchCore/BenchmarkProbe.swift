import Foundation

/// A debug-only, process-local probe used by the no-launch benchmark harness.
/// It has no sink by default and is compiled to a no-op in release builds.
public enum BenchmarkProbe {
#if DEBUG
    @TaskLocal public static var recorder: (@Sendable (String, Int) -> Void)?

    @inline(__always)
    public static func record(_ operation: String, count: Int = 1) {
        recorder?(operation, count)
    }

    public static func withRecorder<T>(
        _ recorder: @escaping @Sendable (String, Int) -> Void,
        _ operation: () throws -> T
    ) rethrows -> T {
        try $recorder.withValue(recorder, operation: operation)
    }
#else
    @inline(__always)
    public static func record(_: String, count _: Int = 1) {}

    public static func withRecorder<T>(
        _: @escaping @Sendable (String, Int) -> Void,
        _ operation: () throws -> T
    ) rethrows -> T {
        try operation()
    }
#endif
}
