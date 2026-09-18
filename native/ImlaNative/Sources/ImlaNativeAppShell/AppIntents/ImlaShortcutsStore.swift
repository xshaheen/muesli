import ImlaCore
import ImlaNativeApp

/// Shared DB access for read-only App Intents. Opens its own connection
/// rather than routing through ImlaController.current, so "get last
/// dictation/meeting" Shortcuts still work even when Imla isn't running.
/// Uses AppIdentity.supportDirectoryURL (reads the running process's own
/// Bundle.main) rather than the ImlaPaths default, so this resolves the
/// correct per-identity database — ImlaDev vs Imla vs ImlaCanary —
/// instead of always reading production data regardless of which app is
/// actually running.
enum ImlaShortcutsStore {
    static func open() throws -> DictationStore {
        let store = DictationStore(
            databaseURL: AppIdentity.supportDirectoryURL.appendingPathComponent("imla.db")
        )
        try store.migrateIfNeeded()
        return store
    }
}
