#if os(macOS)
import AppKit
import Foundation
import Observation
import NollieCore

/// Installation needs a bundled, signed native service. Existing connections and the
/// user-selected configuration backup remain available without changing Hermes.
@MainActor @Observable
final class MacHermesSetup {
    var nativeSetupAvailable: Bool { directInstallationAvailable }
    let directInstallationAvailable = NativeSetupPlan.directAvailable
    let nativeBackupAvailable = true
    private(set) var dependencies = NativeSetupPlan.steps
    private(set) var importPreview: ScopedHermesImport.Preview?
    private(set) var importCompleted = false
    private(set) var importDetail = "Only root instructions and an inactive configuration backup are copied. Configuration may include sensitive settings. Profiles, separate credential files, chats, schedules, Board and computer permissions stay in the original setup."
    private(set) var isolatedHomePath: String?
    private var importSource: URL?
    private var installation: URL?
    let managedRuntime = ManagedRuntimeClient()
    static let selectedInstallationKey = "nollie.nativeSetup.installationID.v1"
    private(set) var headline = "Native setup is being prepared"
    private(set) var detail = "This build can connect to an existing setup. Installing a new local runtime needs Nollie's signed setup service."
    private(set) var error: String?
    private(set) var isBusy = false
    private(set) var canConnect = false
    private(set) var gatewayURL: String?
    private(set) var connectionToken: String?
    private(set) var existingInstallationDetected: Bool?
    private(set) var backupCompleted = false
    private(set) var backupDetail = "Copies root config.yaml, SOUL.md and AGENTS.md only. Configuration may include sensitive settings. Separate .env and auth files, profiles, chats, schedules and Board are not included."
    private(set) var scriptURL: URL?

    var runtimePrepared: Bool {
        NativeSetupPlan.runtimeSteps.allSatisfy { id in
            dependencies.contains { $0.id == id && $0.state == .ready }
        }
    }
    var backgroundActionTitle: String {
        managedRuntime.state == .needsVerification ? "Check connection" : "Keep it running"
    }

    func inspect() async {
        // Do not infer installation from an old receipt or enumerate another app's home.
        inspectExistingMetadata()
        await inspectDependencies()
    }

    private func inspectExistingMetadata() {
        #if NOLLIE_DIRECT
        // Only known path metadata is inspected. A denied sandbox read remains unknown
        // and the user can grant access with the existing native folder picker.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".hermes", isDirectory: true)
        let config = root.appendingPathComponent("config.yaml")
        do {
            let folder = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let file = try config.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            existingInstallationDetected = folder.isDirectory == true && folder.isSymbolicLink != true
                && file.isRegularFile == true && file.isSymbolicLink != true
        } catch {
            // Absence and lack of access both retain the explicit find option. Neither
            // proves that an assistant lives elsewhere or that a connection is ready.
            if existingInstallationDetected != true { existingInstallationDetected = nil }
        }
        #endif
    }

    func prepare(preferences: OnboardingPreferences) async { await installDependencies(preferences: preferences) }
    func openModelSignIn() async { unavailable() }

    /// The setup this Mac chose earlier, when its ownership record still names it.
    static func selectedInstallation() -> URL? {
        guard let value = UserDefaults.standard.string(forKey: selectedInstallationKey), let id = UUID(uuidString: value) else { return nil }
        let candidate = installationsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard let data = try? OwnedSetupFiles.read(candidate.appendingPathComponent("ownership.json"), maximum: 4096),
              let owner = try? JSONDecoder().decode([String: String].self, from: data),
              owner["owner"] == "com.coreykozarski.nollie", owner["installationID"] == id.uuidString else { return nil }
        return candidate
    }

    /// Brings a prepared setup's add-ons up to the ones this copy of Nollie carries, without asking:
    /// they were part of the setup the person agreed to. Runs at launch. A setup whose runtime is not
    /// prepared, or is from an older plan, is left for the setup screen. Hermes loads the new add-ons
    /// the next time the background service starts.
    static func updateAddOnsIfNeeded() async {
        guard NativeSetupPlan.directAvailable, !DemoMode.isOn, let installation = selectedInstallation() else { return }
        let installer = NativeDependencyInstaller(installation: installation)
        for id in NativeSetupPlan.runtimeSteps {
            guard (try? await installer.verified(id)) == true else { return }
        }
        guard (try? await installer.verified("addons")) != true else { return }
        try? await installer.install("addons")
    }

    func inspectDependencies() async {
        if installation == nil, let candidate = Self.selectedInstallation() {
            installation = candidate
            isolatedHomePath = candidate.appendingPathComponent("home").path
        }
        if let installation {
            dependencies = await NativeDependencyInstaller(installation: installation).inspect()
        } else {
            dependencies = NativeSetupPlan.steps.map { step in
                var step = step
                if step.state == .notChecked { step.state = directInstallationAvailable ? .needsInstall : .blocked }
                return step
            }
        }
        await managedRuntime.refresh(installationID: installationID)
        applyRuntimeState()
    }

    func installDependencies(preferences: OnboardingPreferences) async {
        guard directInstallationAvailable, !isBusy else { if !directInstallationAvailable { unavailable() }; return }
        isBusy = true
        defer { isBusy = false }
        for id in NativeSetupPlan.preparationSteps {
            await performDependency(id, preferences: preferences)
            if error != nil { return }
        }
        headline = "Runtime files prepared"
        detail = "Start the background service when you're ready. Your existing setup stays separate."
    }

    func installDependency(_ id: String, preferences: OnboardingPreferences) async {
        guard directInstallationAvailable, !isBusy else { if !directInstallationAvailable { unavailable() }; return }
        isBusy = true
        defer { isBusy = false }
        await performDependency(id, preferences: preferences)
    }

    private func performDependency(_ id: String, preferences: OnboardingPreferences) async {
        guard NativeSetupPlan.preparationSteps.contains(id) else { return }
        guard let index = dependencies.firstIndex(where: { $0.id == id }) else { return }
        error = nil
        dependencies[index].state = .installing
        do {
            let directory = try prepareOwnedHome(preferences: preferences)
            let installer = NativeDependencyInstaller(installation: directory)
            try await installer.install(id)
            dependencies = await installer.inspect()
            applyRuntimeState()
            headline = "Preparation saved"
            detail = "Verified files stay in Nollie's own folder. Your existing setup is unchanged."
        } catch {
            dependencies[index].state = .failed
            self.error = safeMessage(error, fallback: "This preparation step could not finish. Existing files are unchanged.")
        }
    }

    func startBackgroundService() async {
        guard directInstallationAvailable, !isBusy, runtimePrepared, let installationID else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        await managedRuntime.start(installationID: installationID)
        applyRuntimeState()
    }

    func stopBackgroundService() async {
        guard directInstallationAvailable, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await managedRuntime.stop()
        applyRuntimeState()
    }

    var installationID: UUID? { installation.flatMap { UUID(uuidString: $0.lastPathComponent) } }

    func prepareConnection(name: String, connections: () -> [GatewayConnection],
                           isCurrent: () -> Bool) async throws -> ManagedRuntimeHandoff.Prepared {
        guard directInstallationAvailable, !DemoMode.isOn, !isBusy, canConnect,
              let id = installationID, let endpoint = managedRuntime.endpoint,
              let token = managedRuntime.sessionToken else { throw ManagedRuntimeHandoff.Failure.changed }
        isBusy = true
        defer { isBusy = false }
        return try await ManagedRuntimeHandoff.prepare(installationID: id, endpoint: endpoint, token: token,
            name: name, readStatus: ManagedRuntimeClient.readStatus, connections: connections,
            isCurrent: {
                isCurrent() && self.installationID == id && self.managedRuntime.canConnect
                    && self.managedRuntime.endpoint == endpoint && self.managedRuntime.sessionToken == token
            })
    }

    private func applyRuntimeState() {
        canConnect = managedRuntime.canConnect
        gatewayURL = canConnect ? managedRuntime.endpoint?.absoluteString : nil
        connectionToken = canConnect ? managedRuntime.sessionToken : nil
        guard let index = dependencies.firstIndex(where: { $0.id == "service" }) else { return }
        dependencies[index].detail = managedRuntime.message
        switch managedRuntime.state {
        case .ready: dependencies[index].state = .ready
        case .starting: dependencies[index].state = .installing
        case .requiresApproval, .unavailable: dependencies[index].state = .blocked
        case .failed: dependencies[index].state = .failed
        case .off, .stopped, .needsVerification: dependencies[index].state = .needsInstall
        }
        if managedRuntime.state == .failed { error = managedRuntime.message }
        if canConnect { headline = "Connection verified"; detail = "Continue with model and computer setup." }
    }

    func previewImport() async {
        guard directInstallationAvailable, !isBusy else { if !directInstallationAvailable { unavailable() }; return }
        let picker = sourcePicker()
        picker.title = "Choose the configuration to copy"
        picker.prompt = "Preview copy"
        guard picker.runModal() == .OK, let source = picker.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        isBusy = true
        error = nil
        importPreview = nil
        importCompleted = false
        defer { isBusy = false }
        do {
            let preview = try await Task.detached(priority: .userInitiated) { try ScopedHermesImport.preview(source: source) }.value
            importSource = source
            importPreview = preview
            existingInstallationDetected = true
        } catch {
            importSource = nil
            self.error = safeMessage(error, fallback: "This folder could not be previewed safely.")
        }
    }

    func importExisting(preferences: OnboardingPreferences) async {
        guard directInstallationAvailable else { unavailable(); return }
        guard !isBusy, !importCompleted, let source = importSource, let preview = importPreview else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let root = installationsRoot
            let result = try await Task.detached(priority: .userInitiated) {
                try ScopedHermesImport.create(source: source, preview: preview, installations: root)
            }.value
            try recordOwnership(result.directory, id: result.installationID, preferences: preferences)
            selectInstallation(result.directory, id: result.installationID)
            importCompleted = true
            backupCompleted = true
            importDetail = "Copied the reviewed instructions and verified the configuration backup. config.yaml remains inactive and may include sensitive settings. No profiles, separate credential files, chats, schedules, Board or computer permissions were copied.\n" + result.directory.path
            backupDetail = "Verified configuration backup: " + result.backup.path + "\nThese copies may contain sensitive settings."
            headline = "Configuration copied"
            canConnect = false
            await inspectDependencies()
        } catch { self.error = safeMessage(error, fallback: "The copy did not finish. Your original setup is unchanged.") }
    }

    private var installationsRoot: URL { Self.installationsRootURL }
    private static var installationsRootURL: URL { NolliePaths.current.setups }

    private func prepareOwnedHome(preferences: OnboardingPreferences) throws -> URL {
        if let installation { return installation }
        let starter = try StarterAssistantDefaults.prepare(assistantName: preferences.resolvedAssistantName)
        let id = UUID()
        let directory = installationsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(installationsRoot)
        try OwnedSetupFiles.createPrivateDirectory(directory, exclusive: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try OwnedSetupFiles.createPrivateDirectory(home, exclusive: true)
        try OwnedSetupFiles.writeNew(starter.configuration, to: home.appendingPathComponent("config.yaml"))
        try OwnedSetupFiles.writeNew(starter.soul, to: home.appendingPathComponent("SOUL.md"))
        try OwnedSetupFiles.writeNew(starter.profile, to: home.appendingPathComponent("profile.yaml"))
        try recordOwnership(directory, id: id, preferences: preferences)
        selectInstallation(directory, id: id)
        return directory
    }

    private func recordOwnership(_ directory: URL, id: UUID, preferences: OnboardingPreferences) throws {
        let values = ["owner": "com.coreykozarski.nollie", "installationID": id.uuidString,
                      "assistantName": preferences.resolvedAssistantName, "schema": "1"]
        try OwnedSetupFiles.writeNew(JSONEncoder().encode(values), to: directory.appendingPathComponent("ownership.json"))
    }

    private func selectInstallation(_ directory: URL, id: UUID) {
        installation = directory
        isolatedHomePath = directory.appendingPathComponent("home").path
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedInstallationKey)
    }

    private func safeMessage(_ error: Error, fallback: String) -> String {
        (error as? ConfigurationBackup.Failure)?.message
            ?? (error as? StarterAssistantDefaults.Failure)?.errorDescription ?? fallback
    }

    func checkThisMac() async {
        guard !isBusy else { return }
        let picker = sourcePicker()
        guard picker.runModal() == .OK, let source = picker.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let names = try ConfigurationBackup.availableFiles(in: source)
            existingInstallationDetected = !names.isEmpty
            headline = names.isEmpty ? "No configuration found" : "Existing configuration found"
            detail = names.isEmpty ? "Choose the root folder of your Hermes setup." : "Connecting preserves your bots, models, chats, schedules and Board."
            error = nil
        } catch {
            self.error = (error as? ConfigurationBackup.Failure)?.message ?? "This folder could not be checked safely."
        }
    }

    func backupExisting() async {
        guard !isBusy else { return }
        let picker = sourcePicker()
        guard picker.runModal() == .OK, let source = picker.url else { return }
        let sourceAccess = source.startAccessingSecurityScopedResource()
        defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
        let destination = NSOpenPanel()
        destination.title = "Choose where to save the configuration backup"
        destination.message = "These copies may contain sensitive settings. A new private backup folder will be created here."
        destination.prompt = "Save backup here"
        destination.canChooseFiles = false
        destination.canChooseDirectories = true
        destination.canCreateDirectories = true
        destination.allowsMultipleSelection = false
        guard destination.runModal() == .OK, let folder = destination.url else { return }
        let destinationAccess = folder.startAccessingSecurityScopedResource()
        defer { if destinationAccess { folder.stopAccessingSecurityScopedResource() } }
        isBusy = true
        backupCompleted = false
        error = nil
        defer { isBusy = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ConfigurationBackup.create(from: source, in: folder)
            }.value
            backupCompleted = true
            existingInstallationDetected = true
            headline = "Backed up and checked"
            backupDetail = "Copied \(result.files.count) configuration files and verified their checksums.\n\(result.directory.path)\nThese copies may contain sensitive settings. Separate .env/auth files, profiles, chats, schedules and Board are excluded."
        } catch {
            self.error = (error as? ConfigurationBackup.Failure)?.message ?? "Backup could not finish safely. Existing files are unchanged."
        }
    }

    private func sourcePicker() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose your Hermes folder"
        panel.message = "Choose the root setup folder. Only config.yaml, SOUL.md and AGENTS.md will be checked. Profile folders are excluded."
        panel.prompt = "Choose folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel
    }

    private func unavailable() {
        error = "Native installation is not included in this build yet. Your existing setup is unchanged."
    }
}
#endif
