import Foundation

/// A cancelled connection switch restores the already authorized runtime, never
/// its abandoned destination. The recovery has its own cancellation lifetime.
@MainActor
enum InterruptedRuntimeRecovery {
    static func schedule<Runtime: AnyObject>(
        _ previous: Runtime, connectionID: UUID,
        currentRuntime: @escaping @MainActor () -> Runtime?,
        activeConnectionID: @escaping @MainActor () -> UUID?,
        isCurrent: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor (Runtime) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak previous] in
            guard !Task.isCancelled, let previous, isCurrent(),
                  currentRuntime() === previous, activeConnectionID() == connectionID else { return }
            await start(previous)
        }
    }
}
