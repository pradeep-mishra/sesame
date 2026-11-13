import Foundation

/// What macOS says about Sesame's login item. The raw values are the words of the `login status=` log line.
public enum LoginStatus: String, Sendable {
    case enabled
    case requiresApproval = "requires_approval"
    case notRegistered = "not_registered"
    case notFound = "not_found"
}

/// How a speed measurement ended. The raw values are the words of the `bench status=` log line.
public enum BenchStatus: String, Sendable {
    case ok
    case failed
    case timeout
}

/// The log files in the `logs/` folder of the Sesame folder.
public enum LogFile: String, Sendable {
    case app = "app.log"
    case index = "index.log"
    case encode = "encode.log"
}

/// Everything a log line can say. Each case holds a number or a fixed enum, never a `String` or an error, so a
/// query, a path or an error text cannot reach a log.
public enum LogEvent: Sendable {
    case unit(inputs: Int)
    case loginStatus(LoginStatus)
    case benchStatus(BenchStatus)

    var line: String {
        switch self {
        case let .unit(inputs): "unit n=\(inputs)\n"
        case let .loginStatus(status): "login status=\(status.rawValue)\n"
        case let .benchStatus(status): "bench status=\(status.rawValue)\n"
        }
    }
}

/// The one module that writes `app.log`, `index.log` and `encode.log` (static rule `log-typed`).
public enum Log {
    /// Adds one line for `event` to `file` in `Sesame/logs/` (made when missing) through `SesameFolder.append`,
    /// which keeps the log under its cap.
    public static func write(_ event: LogEvent, to file: LogFile) throws {
        try SesameFolder.createLogs()
        try SesameFolder.append(Data(event.line.utf8), to: file.rawValue, in: .logs)
    }
}
