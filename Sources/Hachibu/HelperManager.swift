import Foundation
import HachibuKit
import Observation
import ServiceManagement

/// Sends one request to the helper and waits for its answer. Each request
/// opens its own connection and closes it afterwards, so the helper can quit
/// when nothing is asked of it.
///
/// For M3: the helper reconnects the charger as soon as its last caller
/// leaves, so a charger cut needs a connection that stays open.
nonisolated enum HelperClient {
    static func send(_ request: HelperRequest) async -> HelperReply {
        guard !Store.isOverridden else { return HelperReply(problem: "Test runs never reach the helper.") }
        guard let team = CodeIdentity.teamID(),
              let rule = CodeIdentity.requirement(identifier: HelperID.service, team: team) else {
            return HelperReply(problem: "This copy of Hachibu is not signed, so it cannot trust a helper.")
        }
        var reply = await sendOnce(request, rule: rule)
        // The helper may have been quitting, or was just replaced by a new
        // build. macOS starts it again for the second try.
        if !reply.succeeded, reply.version == 0 {
            try? await Task.sleep(for: .milliseconds(400))
            reply = await sendOnce(request, rule: rule)
        }
        return reply
    }

    private static func sendOnce(_ request: HelperRequest, rule: String) async -> HelperReply {
        let connection = NSXPCConnection(machServiceName: HelperID.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
        connection.setCodeSigningRequirement(rule)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.finish(HelperReply(problem: "The helper did not answer."))
            } as? HelperXPC
            guard let proxy else {
                once.finish(HelperReply(problem: "The helper did not answer."))
                return
            }
            proxy.perform(request.name, value: request.value) { problem, adapterCut, version in
                once.finish(HelperReply(problem: problem, adapterCut: adapterCut, version: version))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                once.finish(HelperReply(problem: "The helper did not answer in time."))
            }
        }
    }

    /// Resumes a continuation exactly once, whichever answer comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HelperReply, Never>?

        init(_ continuation: CheckedContinuation<HelperReply, Never>) { self.continuation = continuation }

        func finish(_ reply: HelperReply) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: reply)
        }
    }
}

/// Installs, removes, and watches the helper. The Helper tab and the limit
/// slider read its state.
@Observable
final class HelperManager {
    private(set) var state: HelperState
    /// True while an install or a removal is under way.
    private(set) var isWorking = false
    /// Why the last install failed, in words for the user.
    private(set) var installProblem: String?
    @ObservationIgnored private let isFixed: Bool
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// The real helper. Test runs never ask macOS about it.
    init() {
        isFixed = Store.isOverridden
        state = Store.isOverridden ? .notInstalled : .checking
    }

    /// A fixed state for snapshots.
    init(fixed state: HelperState) {
        isFixed = true
        self.state = state
    }

    var isRunning: Bool { state.isRunning }

    /// Why this copy of Hachibu cannot install a helper. nil when it can.
    nonisolated static var unavailableReason: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperID.plist)")
        if !FileManager.default.fileExists(atPath: plist.path) { return "This copy of Hachibu was built without the helper." }
        if CodeIdentity.teamID() == nil { return "This copy of Hachibu is not signed with an Apple certificate, which the helper needs." }
        return nil
    }

    private nonisolated static var daemon: SMAppService { SMAppService.daemon(plistName: HelperID.plist) }

    /// Asks macOS whether the helper is installed and approved, then asks
    /// the helper itself: "Running" is only shown for a helper that answered.
    /// `fresh` is for right after an install or a removal: a check that
    /// began earlier says nothing about the state now, so read again.
    func refresh(fresh: Bool = false) async {
        guard !isFixed else { return }
        // One check at a time; a second caller waits for the one under way.
        while let inFlight {
            await inFlight.value
            if !fresh { return }
            if self.inFlight == inFlight { self.inFlight = nil }
        }
        let check = Task {
            let found = await Task.detached { await Self.readState() }.value
            if !isWorking { state = found }
        }
        inFlight = check
        await check.value
        if inFlight == check { inFlight = nil }
    }

    private nonisolated static func readState() async -> HelperState {
        if let reason = unavailableReason { return .unavailable(reason) }
        switch daemon.status {
        // macOS answers "not found" for a helper it has never been told
        // about. The helper's file is in this copy (checked above), so that
        // means not installed yet.
        case .notRegistered, .notFound: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .enabled:
            let reply = await HelperClient.send(.readStatus)
            if let problem = reply.problem { return .failed(problem) }
            return reply.version == HelperID.version ? .running
                : .failed("The helper is from a different version of Hachibu. Remove it, then install it again.")
        @unknown default: return .failed("macOS reported a helper state Hachibu does not know.")
        }
    }

    /// Registers the helper with macOS. macOS then asks the user to allow it
    /// in System Settings > General > Login Items.
    func install() async {
        guard !isFixed, !isWorking else { return }
        isWorking = true
        let failure: String? = await Task.detached {
            do { try Self.daemon.register(); return nil } catch { return error.localizedDescription }
        }.value
        isWorking = false
        await refresh(fresh: true)
        // Waiting for approval is not a failure, whatever register() threw.
        installProblem = state == .notInstalled ? "macOS did not install the helper: \(failure ?? "no reason given")" : nil
    }

    /// Removes the helper from macOS. The caller first reconnects the
    /// charger and raises the limit (BatteryMonitor.removeHelper).
    func unregister() async -> String? {
        guard !isFixed else { return nil }
        isWorking = true
        let failure: String? = await Task.detached {
            do { try await Self.daemon.unregister(); return nil } catch { return error.localizedDescription }
        }.value
        isWorking = false
        await refresh(fresh: true)
        return failure
    }

    static func openLoginItems() {
        guard !Store.isOverridden else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
