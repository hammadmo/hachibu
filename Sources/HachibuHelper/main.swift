import Foundation
import HachibuKit
import HachibuSystem

// Hachibu's helper. macOS starts it, as root, when the app sends a request,
// and it quits by itself a few seconds after the app lets go.
//
// It carries out four requests (HelperRequest) and nothing else, and only
// for a caller signed as Hachibu by the same Apple team that signed this
// helper. Whenever the app goes away, and when the helper starts or stops,
// the charger is reconnected: a cut must never outlive the app that asked.

final class Service: NSObject, NSXPCListenerDelegate, HelperXPC, @unchecked Sendable {
    /// Seconds without a caller before the helper quits.
    static let idleSeconds = 10.0

    /// All state below is touched on this queue only.
    private let queue = DispatchQueue(label: "app.hachibu.mac.helper.work")
    private var callers = 0
    private var idle: DispatchWorkItem?
    private let program = CommandLine.arguments[0]
    private let startedFrom: FileStamp?
    /// False when this helper has no team signature, so no caller can be checked.
    private let canTrustCallers: Bool

    struct FileStamp: Equatable {
        var inode: UInt64
        var modified: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            modified = info.st_mtimespec.tv_sec
        }
    }

    init(canTrustCallers: Bool) {
        self.canTrustCallers = canTrustCallers
        startedFrom = FileStamp(path: program)
        super.init()
        queue.async {
            self.restoreAdapter()
            self.scheduleIdleExit()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard canTrustCallers else { return false }
        connection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { self?.callerLeft() }
        }
        queue.async {
            // A new build replaced this program: finish, so macOS starts the
            // new one for the caller's next try.
            if FileStamp(path: self.program) != self.startedFrom { self.quit() }
            self.callers += 1
            self.idle?.cancel()
        }
        connection.resume()
        return true
    }

    func perform(_ name: String, value: Int, reply: @escaping @Sendable (String?, Bool, Int) -> Void) {
        queue.async {
            var problem: String?
            switch HelperRequest(name: name, value: value) {
            case .setLimit(let limit): problem = self.setLimit(limit)
            case .cutAdapter: problem = hb_root_adapter_set(true) ? nil : "The charger could not be disconnected."
            case .restoreAdapter: problem = hb_root_adapter_set(false) ? nil : "The charger could not be reconnected."
            case .readStatus: break
            case nil: problem = "The helper does not know this request."
            }
            reply(problem, self.adapterIsCut(), HelperID.version)
        }
    }

    private func setLimit(_ limit: Int) -> String? {
        if limit >= 100 {
            var message = [CChar](repeating: 0, count: 256)
            return hb_limit_disable(&message, 256) ? nil : "macOS did not turn the limit off."
        }
        return hb_root_limit_set(Int32(limit)) ? nil : "The limit could not be written."
    }

    private func adapterIsCut() -> Bool {
        var cut = false
        return hb_adapter_is_cut(&cut) && cut
    }

    private func restoreAdapter() {
        if adapterIsCut() { _ = hb_root_adapter_set(false) }
    }

    private func callerLeft() {
        callers = max(callers - 1, 0)
        guard callers == 0 else { return }
        restoreAdapter()
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.callers == 0 else { return }
            self.quit()
        }
        idle = work
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
    }

    /// Call on `queue`.
    func quit() -> Never {
        restoreAdapter()
        exit(0)
    }

    func quitFromSignal() {
        queue.async { self.quit() }
    }
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("HachibuHelper runs only as root, started by macOS.\n".utf8))
    exit(1)
}

// Without a team signature there is no one to trust: accept no caller at all.
let rule = CodeIdentity.teamID().flatMap { CodeIdentity.requirement(identifier: HelperID.app, team: $0) }
let service = Service(canTrustCallers: rule != nil)

// macOS stops the helper with SIGTERM (shutdown, or the helper was removed).
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminate.setEventHandler { service.quitFromSignal() }
terminate.resume()

let listener = NSXPCListener(machServiceName: HelperID.service)
if let rule { listener.setConnectionCodeSigningRequirement(rule) }
listener.delegate = service
listener.resume()
dispatchMain()
