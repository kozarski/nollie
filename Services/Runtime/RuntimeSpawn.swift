#if os(macOS)
import Darwin

/// How Nollie Runtime starts a Hermes process. Only Darwin, so the setup rehearsal
/// (`Tools/dev/managed-setup-dry-run.py`) builds this same file into its launcher.
enum RuntimeSpawn {
    /// Its own process group, no descriptor but the ones given, and signals as a fresh process has them.
    static let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                             | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)

    /// Starts `executable` with stdin and stderr on /dev/null, stdout on `output`, and `owner`
    /// and `keys` as descriptors 3 and 4 (`NollieRuntimeContract.ownerDescriptor` and `keysDescriptor`).
    /// Returns the PID, or nil.
    ///
    /// The signal settings matter. A child otherwise inherits the mask of the thread that starts it,
    /// and Swift concurrency and Dispatch threads block SIGCHLD and SIGTERM. Hermes and everything it
    /// starts would then never see either: SIGTERM could not stop it, and uv, which waits for its
    /// bytecode helpers through SIGCHLD, would wait for ever once the engine's packages were in.
    static func start(executable: String, arguments: [String], environment: [String: String], directory: String,
                      output: Int32, owner: Int32, keys: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        let settings = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, owner, 3),
            posix_spawn_file_actions_adddup2(&actions, keys, 4),
            posix_spawn_file_actions_addchdir(&actions, directory),
            // Its own process group, so everything Hermes starts (an installer, a model server) can be stopped
            // with it. Left behind, such a process keeps a lock and the next start waits on it for ever.
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigmask(&attributes, &unblocked),
            posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, flags)
        ]
        guard settings.allSatisfy({ $0 == 0 }) else { return nil }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environ = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; environ.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, &environ) == 0 else { return nil }
        return pid
    }
}
#endif
