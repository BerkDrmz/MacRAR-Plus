import AppKit

final class TaskCancellation {
    private let lock = NSLock()
    private var stopped = false
    private var cancellationHandler: (() -> Void)?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() {
        lock.lock(); stopped = true; let handler = cancellationHandler; lock.unlock(); handler?()
    }
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock(); cancellationHandler = handler; let alreadyStopped = stopped; lock.unlock()
        if alreadyStopped { handler() }
    }
    func clearHandler() { lock.lock(); cancellationHandler = nil; lock.unlock() }
    func check() throws { if cancelled { throw CocoaError(.userCancelled) } }
}

/// Event-driven tracking: no timers, polling or work while the app is idle.
final class TaskCenter {
    static let shared = TaskCenter()
    private var active: [UUID: () -> Void] = [:]
    private var activity: NSObjectProtocol?
    var hasActiveTasks: Bool { !active.isEmpty }
    func begin(cancel: @escaping () -> Void) -> UUID {
        if active.isEmpty { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "User-requested archive operation") }
        let id = UUID(); active[id] = cancel; return id
    }
    func finish(_ id: UUID) {
        active.removeValue(forKey: id)
        if active.isEmpty, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func cancelAll() { Array(active.values).forEach { $0() } }

    @discardableResult
    func work<T>(title: String, host: NSWindow?, commitsChanges: Bool = false, discardCancelledResult: ((T) -> Void)? = nil,
                 body: @escaping (TaskCancellation) throws -> T,
                 completion: @escaping (Result<T, Error>) -> Void) -> TaskCancellation {
        let token = TaskCancellation()
        let panel = ProgressPanel(title: title)
        let id = begin { token.cancel() }
        panel.onCancel = { token.cancel() }; panel.show(on: host)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try token.check(); return try body(token) }
            DispatchQueue.main.async {
                var delivered = result
                // Preparation can finish just before Cancel reaches the main queue.
                // Stop the next stage, but preserve success after a completed commit.
                if !commitsChanges, token.cancelled, case .success(let value) = result {
                    discardCancelledResult?(value)
                    delivered = .failure(CocoaError(.userCancelled))
                }
                panel.onCancel = nil; panel.dismiss(); self.finish(id); completion(delivered)
            }
        }
        return token
    }
}

enum EnergyMode: String, CaseIterable {
    case economy, balanced, fast
    var title: String {
        switch self {
        case .economy: return P("Pil dostu", "Energy saver")
        case .balanced: return P("Dengeli", "Balanced")
        case .fast: return P("Hızlı", "Fast")
        }
    }
}

enum EnergyPolicy {
    static var constrained: Bool {
        let system = ProcessInfo.processInfo
        return system.isLowPowerModeEnabled || system.thermalState == .serious || system.thermalState == .critical
    }
    static var mode: EnergyMode {
        get { EnergyMode(rawValue: UserDefaults.standard.string(forKey: "plus.energy") ?? "economy") ?? .economy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "plus.energy") }
    }
    static var threads: Int {
        let system = ProcessInfo.processInfo
        if constrained { return 1 }
        switch mode {
        case .economy: return 1
        case .balanced: return min(4, max(1, system.activeProcessorCount / 2))
        case .fast: return min(8, system.activeProcessorCount)
        }
    }
    static var dictionaryMiB: Int? {
        if constrained { return 16 }
        switch mode { case .economy: return 16; case .balanced: return 64; case .fast: return nil }
    }
}
