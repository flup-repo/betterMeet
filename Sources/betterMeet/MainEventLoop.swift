import Foundation

enum MainEventLoop {
    /// Enter directly from synchronous main, never from a task or dispatch
    /// callback. The blocking AppKit loop must be free to service both.
    static func run(_ body: @MainActor () throws -> Void) throws {
        precondition(Thread.isMainThread, "AppKit must start on the main thread")
        withUnsafeCurrentTask { task in
            precondition(task == nil, "AppKit must start outside the Swift async runtime")
        }
        try MainActor.assumeIsolated { try body() }
    }
}
