import Foundation
#if canImport(os)
import os
#endif

/// CoreLog writes agtermCore's diagnostics: the unified log on macOS, stderr where there is none.
struct CoreLog: Sendable {
    #if canImport(os)
    private let logger: Logger
    #else
    private let category: String
    #endif

    init(category: String) {
        #if canImport(os)
        logger = Logger(subsystem: "com.umputun.agterm", category: category)
        #else
        self.category = category
        #endif
    }

    func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category)] \(message)\n".utf8))
        #endif
    }

    func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category)] error: \(message)\n".utf8))
        #endif
    }
}
