import Foundation
import Security

/// Names the app and the helper share.
public enum HelperID {
    public static let app = "app.hachibu.mac"
    /// The helper's launchd label, its service name, and its signing identifier.
    public static let service = "app.hachibu.mac.helper"
    public static let plist = "app.hachibu.mac.helper.plist"
    public static let version = 1
}

/// Everything the helper can be asked to do. The list is closed: a request
/// that does not parse into one of these four is refused.
public enum HelperRequest: Equatable, Sendable {
    case setLimit(Int), cutAdapter, restoreAdapter, readStatus

    /// The limits the helper accepts.
    public static let limitRange = 20...100

    public var name: String {
        switch self {
        case .setLimit: "set-limit"
        case .cutAdapter: "cut-adapter"
        case .restoreAdapter: "restore-adapter"
        case .readStatus: "read-status"
        }
    }

    public var value: Int {
        if case .setLimit(let limit) = self { return limit }
        return 0
    }

    /// nil for an unknown name, a limit outside 20–100, or a value on a
    /// request that takes none.
    public init?(name: String, value: Int) {
        switch name {
        case "set-limit":
            guard Self.limitRange.contains(value) else { return nil }
            self = .setLimit(value)
        case "cut-adapter" where value == 0: self = .cutAdapter
        case "restore-adapter" where value == 0: self = .restoreAdapter
        case "read-status" where value == 0: self = .readStatus
        default: return nil
        }
    }
}

/// What the helper answers to every request.
public struct HelperReply: Equatable, Sendable {
    /// nil when the request was carried out.
    public var problem: String?
    /// True while the helper holds the charger disconnected.
    public var adapterCut: Bool
    public var version: Int

    public init(problem: String?, adapterCut: Bool = false, version: Int = 0) {
        self.problem = problem
        self.adapterCut = adapterCut
        self.version = version
    }

    public var succeeded: Bool { problem == nil }
}

/// The one message between the app and the helper.
@objc public protocol HelperXPC {
    func perform(_ name: String, value: Int, reply: @escaping @Sendable (String?, Bool, Int) -> Void)
}

/// The helper as the Helper tab shows it.
public enum HelperState: Equatable, Sendable {
    case checking, notInstalled, needsApproval, running
    case failed(String)
    /// This copy of Hachibu cannot install a helper, and why.
    case unavailable(String)

    public var title: String {
        switch self {
        case .checking: "Checking…"
        case .notInstalled, .unavailable: "Not installed"
        case .needsApproval: "Needs approval"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    public var isRunning: Bool { self == .running }
}

public enum HelperNeed {
    /// The lowest limit macOS holds without the helper.
    public static let lowestWithoutHelper = 80

    /// True when the saved limit cannot be kept without the helper and the
    /// helper is not there. Not while its state is still being checked.
    public static func isMissing(savedLimit: Int?, state: HelperState) -> Bool {
        guard let savedLimit, savedLimit < lowestWithoutHelper else { return false }
        return state != .running && state != .checking
    }

    /// Where the limit goes when the helper is removed: unchanged at 80% or
    /// above, otherwise the lowest limit macOS offers on its own.
    public static func limitAfterRemoval(current: Int, official: [Int]) -> Int {
        let stops = LimitStops.normalized(official).filter { $0 >= lowestWithoutHelper }
        if stops.contains(current) { return current }
        return stops.first { $0 >= current } ?? 100
    }
}

/// Who signed the running program, and the rule a peer must meet.
public enum CodeIdentity {
    /// The Apple team that signed this program. nil when it is signed ad hoc
    /// or not at all.
    public static func teamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The code-signing rule for a peer: this identifier, signed with a
    /// certificate Apple issued to this team. nil when the team is not a
    /// plain team ID, so nothing odd can end up inside the rule.
    public static func requirement(identifier: String, team: String) -> String? {
        let plain = team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let safe = !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        guard plain, safe else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
