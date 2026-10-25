import Foundation
import NollieCore

/// Registering this device, putting the companion on the gateway, and taking it off again.
extension PushSetupModel {
    // MARK: This device

    func registerPhone(push: PushRegistrar, runtime rt: GatewayRuntime) async {
        registering = true
        registerOutcome = nil
        defer { registering = false }
        _ = await push.requestAuthorization()
        // The device token lands shortly after permission is granted; nothing can be published without it.
        _ = await poll(times: 10, every: .milliseconds(500)) { push.deviceToken != nil }
        await push.syncRegistration(runtime: rt)
        await push.registerWithRelay()
        registerOutcome = registrationSummary(push)
    }

    private func registrationSummary(_ push: PushRegistrar) -> String {
        switch (push.lastError ?? push.relayError, push.registeredAt) {
        case (let problem?, _):
            return "Failed: \(problem)"
        case (nil, nil):
            return "Could not send: \(DeviceWords.the) has not received a push token yet. Give it a moment and try again."
        case (nil, _):
            let relayPart = PushRelay.isConfigured ? " and \(DeviceWords.the) is on the relay." : "."
            return "Registered at \(Date().formatted(date: .omitted, time: .shortened)). The device file is on the gateway" + relayPart
        }
    }

    private enum KeyProblem: LocalizedError {
        case unreadable(String), notAKey(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Could not read \(name)."
            case .notAKey(let name): "\(name) does not look like an APNs .p8 key file."
            }
        }
    }

    /// Reads the .p8 file chosen in the picker. The Key ID comes from its name (AuthKey_ABC123DEFG.p8).
    func importKey(_ url: URL) {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else { throw KeyProblem.unreadable(name) }
            guard let text = String(data: data, encoding: .utf8), text.contains("PRIVATE KEY") else { throw KeyProblem.notAKey(name) }
            let stem = url.deletingPathExtension().lastPathComponent
            (keyData, keyFileName, error) = (data, name, nil)
            keyID = stem.hasPrefix("AuthKey_") ? String(stem.dropFirst(8)) : ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Installing

    /// Why Install cannot run yet, in words; nil when it can.
    func uploadBlocker(for rt: GatewayRuntime) -> String? {
        let ownKeyMissing = !PushRelay.isConfigured && keyData == nil
        let ownKeyIncomplete = !PushRelay.isConfigured && (keyID.isEmpty || teamID.count != 10)
        var needsSignInFirst = false
        if case .needsSignIn = credential(for: rt) { needsSignInFirst = true }
        // The first reason that holds is the one shown.
        let reasons: [(holds: Bool, words: String)] = [
            (companionSignInRejected, "The gateway turned down the companion's sign-in. Sign in again before installing."),
            (gatewayURL.isEmpty, "Enter the gateway address for the companion first."),
            (ownKeyMissing, "This build cannot relay pushes itself, so add your APNs .p8 key first (step 1)."),
            (ownKeyIncomplete, "Step 1 needs the Key ID and a 10-character Team ID."),
            (needsSignInFirst, "Please sign in to the companion first."),
        ]
        return reasons.first(where: \.holds)?.words
    }

    func canUpload(for rt: GatewayRuntime) -> Bool { uploadBlocker(for: rt) == nil }

    /// The one install action of the wizard: back up, write the config and script, add the plugin.
    func installOnGateway(runtime rt: GatewayRuntime) async {
        if let blocker = uploadBlocker(for: rt) {
            error = blocker
            return
        }
        installing = true
        defer { installing = false }
        (installedAt, pluginInstalledAt, pluginResult, installedFiles) = (nil, nil, nil, [])
        guard await backUpCompanion(runtime: rt) else { return }
        // A companion already running loads new files by itself, so it must not be sent through a
        // pointless gateway restart.
        let alive = heartbeat.map { CompanionSignInState.isFresh($0, at: Date()) } ?? false
        let reloadsItself = runningCanSelfReload && alive
        await uploadPushFolder(runtime: rt)
        guard error == nil else { return }
        await installPlugin(runtime: rt)
        guard let outcome = pluginResult, outcome.hasPrefix("Installed") else {
            error = pluginResult ?? "Could not install the plugin."
            return
        }
        (pluginInstalledAt, installedAt, urlInUse) = (Date(), Date(), gatewayURL)
        guard reloadsItself else { return scheduleRestartCountdown(runtime: rt) }

        restartLater()
        restartPending = false
        let settled = await poll(times: 10) {
            await checkCompanion(runtime: rt)
            return companionHealthy || companionSignInRejected
        }
        // A fresh heartbeat shows the process is alive. A connection problem needs its own fix, and
        // restarting the gateway cannot repair a refused sign-in.
        let stillAlive = heartbeat.map { CompanionSignInState.isFresh($0, at: Date()) } ?? false
        if !settled && !stillAlive { scheduleRestartCountdown(runtime: rt) }
    }

    /// The config the companion reads. It never holds this device's own tokens.
    func configText(for rt: GatewayRuntime) -> String {
        let folder = pushDir(for: rt)
        var settings: [(String, String)] = [
            ("GATEWAY_URL", gatewayURL),
            ("PUBLIC_URL", rt.connection.gateway.description),
        ]
        switch credential(for: rt) {
        case .sessionToken:
            if let token = rt.secrets.sessionToken { settings.append(("GATEWAY_TOKEN", token)) }
        case .ready:
            settings += [("GATEWAY_BEARER", companionSecrets?.accessToken),
                         ("GATEWAY_REFRESH_TOKEN", companionSecrets?.refreshToken)].compactMap { name, value in
                value.map { (name, $0) }
            }
        case .needsSignIn:
            break
        }
        if rt.secrets.access.isConfigured {
            settings += [("CF_ACCESS_CLIENT_ID", rt.secrets.access.clientId),
                         ("CF_ACCESS_CLIENT_SECRET", rt.secrets.access.clientSecret)]
        }
        if !PushRelay.isConfigured {
            settings += [("APNS_KEY_FILE", "\(folder)/AuthKey_\(keyID).p8"), ("APNS_KEY_ID", keyID), ("APNS_TEAM_ID", teamID)]
        }
        settings.append(("DEVICES_DIR", folder + "/devices"))
        let header = "# Written by Nollie for hermes_push.py. Settings already in the environment win over these."
        return ([header] + settings.map { "HERMES_PUSH_\($0.0)=\($0.1)" }).joined(separator: "\n") + "\n"
    }

    /// One file on its way to the gateway.
    private struct Parcel {
        let name: String
        let data: Data
        let mime: String
    }

    /// Script, installer, config and (without a relay) the key, into `<home>/push/`.
    func uploadPushFolder(runtime rt: GatewayRuntime) async {
        if let blocker = uploadBlocker(for: rt) { error = blocker; return }
        if !installing, !(await backUpCompanion(runtime: rt)) { return }
        error = nil
        uploadedAt = nil
        guard let script = CompanionBundle.script, let installer = CompanionBundle.installer else {
            error = "This build is missing the companion files."
            return
        }
        let folder = pushDir(for: rt)
        var parcels = [
            Parcel(name: "hermes_push.py", data: script.data, mime: script.mime),
            Parcel(name: "install.sh", data: installer.data, mime: installer.mime),
            Parcel(name: "hermes-push.conf", data: Data(configText(for: rt).utf8), mime: "text/plain"),
        ]
        if !PushRelay.isConfigured {
            guard let keyData else {
                error = "Choose the APNs key first."
                return
            }
            parcels.append(Parcel(name: "AuthKey_\(keyID).p8", data: keyData, mime: "application/x-pem-file"))
        }
        for parcel in parcels {
            do {
                try await writeFile(rt, path: folder + "/" + parcel.name, data: parcel.data, mime: parcel.mime)
            } catch {
                self.error = "\(parcel.name): \(error.localizedDescription)"
                return
            }
            installedFiles.append(InstalledFile(name: parcel.name, directory: folder + "/", bytes: parcel.data.count))
        }
        uploadedAt = Date()
        companionSignIn.installed(after: heartbeat?.updatedAt, at: Date())
        companionSignIn.save(connectionID: rt.connection.id)
    }

    /// Writes the plugin to `<home>/plugins/nollie-push/` and turns it on. Hermes picks it up on the
    /// next restart and runs the relay itself.
    func installPlugin(runtime rt: GatewayRuntime) async {
        if !installing, !(await backUpCompanion(runtime: rt)) { pluginResult = error; return }
        installingPlugin = true
        defer { installingPlugin = false }
        guard let home = rt.profileHome else { pluginResult = "The gateway did not say where its home folder is."; return }
        guard let files = CompanionBundle.pluginFiles else { pluginResult = "This build is missing the plugin files."; return }
        let folder = "\(home)/plugins/\(Self.pluginID)"
        do {
            for file in files {
                try await writeFile(rt, path: "\(folder)/\(file.name)", data: file.data, mime: file.mime)
                installedFiles.append(InstalledFile(name: file.name, directory: folder + "/", bytes: file.data.count))
            }
            let reply = try await enableCompanion(runtime: rt)
            if reply["ok"]?.boolValue == false {
                pluginResult = reply["error"]?.stringValue ?? "Hermes would not enable the plugin."
                return
            }
            pluginResult = "Plugin v\(Self.bundledPluginVersion) is installed and on. Restart the gateway to start it."
        } catch {
            pluginResult = error.localizedDescription
        }
    }

    /// A private, checked copy of the files an install is about to replace.
    func backUpCompanion(runtime rt: GatewayRuntime) async -> Bool {
        guard let home = rt.profileHome, home.hasPrefix("/") else {
            error = "Wait for Hermes to connect before backing up the companion."
            return false
        }
        let plugin = "plugins/\(Self.pluginID)"
        let relative = ["push/hermes_push.py", "push/install.sh", "push/hermes-push.conf"]
            + ["hermes_push.py", "plugin.yaml", "__init__.py"].map { "\(plugin)/\($0)" }
        do {
            _ = try await CompanionFileBackup.create(paths: relative.map { "\(home)/\($0)" }, parent: NolliePaths.current.companionBackups) { path in
                try await self.readData(rt, path: path)
            }
            return true
        } catch {
            self.error = "The companion backup could not be checked, so nothing was installed."
            return false
        }
    }

    // MARK: Taking it away

    /// Disables the plugin, withdraws this device, and has Hermes run `install.sh --uninstall` in a
    /// new chat (which asks for approval, like any command). This device forgets its setup too.
    func uninstall(runtime rt: GatewayRuntime, model: AppModel) async {
        await switchOffPlugin(rt)
        await model.push.removeRegistration(runtime: rt)
        await askHermesToUninstall(runtime: rt, model: model)
        startOver(runtime: rt)
        heartbeat = nil
        installedVersion = nil
        installedScriptMatches = false
        await checkCompanion(runtime: rt)
    }

    private func switchOffPlugin(_ rt: GatewayRuntime) async {
        let route = "/api/dashboard/agent-plugins/" + Self.pluginID + "/disable"
        let _: JSONValue? = try? await rt.api.send("POST", route, body: EmptyBody())
    }

    /// Opens a chat that asks Hermes to run the uninstall command, and shows it.
    private func askHermesToUninstall(runtime rt: GatewayRuntime, model: AppModel) async {
        guard let chat = try? await rt.newChat() else { return }
        let command = installCommand(for: rt) + " --uninstall"
        let request = "Run this exact command in the terminal and show me all of its output: `\(command)`. "
            + "It stops the Nollie companion service and deletes its files. "
            + "If it fails, tell me the error word for word."
        await chat.send(request)
        let connectionID = rt.connection.id
        model.pendingRoute = PendingRoute(connectionID: connectionID, storedSessionID: chat.storedID, profile: chat.profile)
        model.selectedTab = .chats
    }

    func startOver(runtime rt: GatewayRuntime) {
        gatewayURL = ""
        urlInUse = nil
        signOutCompanion(runtime: rt)
        uploadedAt = nil
        installedAt = nil
        pluginInstalledAt = nil
        pluginResult = nil
        error = nil
        testPhase = .idle
        registerOutcome = nil
        forgetCompleted(for: rt)
    }
}
