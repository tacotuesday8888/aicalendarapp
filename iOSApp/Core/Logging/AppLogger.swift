import Foundation
import OSLog

final class AppLogger: @unchecked Sendable {
    private let logger: Logger

    nonisolated init(category: String) {
        logger = Logger(subsystem: "com.langqi.aicalendarapp", category: category)
    }

    nonisolated func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    nonisolated func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    nonisolated func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
