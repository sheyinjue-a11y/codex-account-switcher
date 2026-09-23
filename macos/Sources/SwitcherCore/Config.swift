import Foundation

public enum SwitcherError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct Route: Codable, Equatable {
    public var lines: [String]
    public init(lines: [String] = []) { self.lines = lines }
}

public enum ConfigEditor {
    public static func applying(_ route: Route, to text: String) throws -> String {
        // Implemented after the preservation contract is exercised in CI.
        text
    }
}
