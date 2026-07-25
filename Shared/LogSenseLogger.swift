import Foundation

enum LogSenseLogger {
    static func debug(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}
