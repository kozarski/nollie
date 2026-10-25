@preconcurrency import AVFoundation
import Foundation
import UserNotifications
#if os(iOS)
import ActivityKit
import Photos
import UIKit
#else
import AppKit
#endif

/// The real system calls behind each permission. Reading never prompts; only `request` does, and
/// only the Allow button reaches it.
extension PermissionCenter {
    /// The real center, or in the demo copy one with made-up answers (`-nollie-demo-permissions`).
    static func make(push: PushRegistrar) -> PermissionCenter {
        #if DEBUG
        if DemoMode.isOn, let preset = DemoMode.permissions { return demo(preset) }
        #endif
        return system(push: push)
    }

    /// The permissions this device and edition can have. Notifications go through the push
    /// registrar, so a yes still ends in a registered device.
    static func system(push: PushRegistrar) -> PermissionCenter {
        var clients: [PermissionKind: PermissionClient] = [
            .notifications: PermissionClient.notifications(push),
            .microphone: PermissionClient.microphone(),
        ]
        #if os(iOS)
        clients[.localNetwork] = PermissionClient.localNetwork()
        clients[.camera] = PermissionClient.camera()
        clients[.photos] = PermissionClient.photos()
        clients[.liveActivities] = PermissionClient.liveActivities()
        #else
        // Linking an iPhone and letting a bot use this Mac are in the download version only.
        if NativeSetupPlan.directAvailable {
            clients[.localNetwork] = PermissionClient.localNetwork()
            clients[.accessibility] = PermissionClient.computer(.accessibility)
            clients[.screenRecording] = PermissionClient.computer(.screenRecording)
        }
        #endif
        return PermissionCenter(clients: clients)
    }
}

extension PermissionClient {
    // MARK: Opening Settings

    #if os(iOS)
    static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    #else
    /// One of the Privacy & Security pages (or another pane) in System Settings.
    static func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
    #endif

    // MARK: Notifications

    static func notifications(_ push: PushRegistrar) -> PermissionClient {
        PermissionClient(
            read: {
                await push.refreshAuthorization()
                return map(push.authorization)
            },
            request: {
                _ = await push.requestAuthorization()
                return map(push.authorization)
            },
            openSettings: {
                #if os(iOS)
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                #else
                openPane("com.apple.Notifications-Settings.extension")
                #endif
            })
    }

    static func map(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .granted
        @unknown default: .notAsked
        }
    }

    // MARK: Local Network

    static func localNetwork(_ access: LocalNetworkAccess = .shared) -> PermissionClient {
        PermissionClient(
            read: { await access.read() },
            request: { await access.request() },
            openSettings: {
                #if os(iOS)
                openAppSettings()
                #else
                openPane("com.apple.preference.security?Privacy_LocalNetwork")
                #endif
            })
    }

    // MARK: Microphone

    static func microphone() -> PermissionClient {
        PermissionClient(
            read: { map(AVAudioApplication.shared.recordPermission) },
            request: {
                _ = await AVAudioApplication.requestRecordPermission()
                return map(AVAudioApplication.shared.recordPermission)
            },
            openSettings: {
                #if os(iOS)
                openAppSettings()
                #else
                openPane("com.apple.preference.security?Privacy_Microphone")
                #endif
            })
    }

    static func map(_ permission: AVAudioApplication.recordPermission) -> PermissionState {
        switch permission {
        case .undetermined: .notAsked
        case .granted: .granted
        case .denied: .denied
        @unknown default: .notAsked
        }
    }

    #if os(iOS)
    // MARK: Camera

    static func camera() -> PermissionClient {
        PermissionClient(
            read: { map(AVCaptureDevice.authorizationStatus(for: .video)) },
            request: {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                return map(AVCaptureDevice.authorizationStatus(for: .video))
            },
            openSettings: { openAppSettings() })
    }

    static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .unavailable
        @unknown default: .notAsked
        }
    }

    // MARK: Photos (saving only)

    static func photos() -> PermissionClient {
        PermissionClient(
            read: { map(PHPhotoLibrary.authorizationStatus(for: .addOnly)) },
            request: { map(await PHPhotoLibrary.requestAuthorization(for: .addOnly)) },
            openSettings: { openAppSettings() })
    }

    static func map(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorized, .limited: .granted
        case .denied: .denied
        case .restricted: .unavailable
        @unknown default: .notAsked
        }
    }

    // MARK: Live Activities

    /// A switch in Settings only: there is no prompt to show, so asking just reads it again.
    static func liveActivities() -> PermissionClient {
        let read: @MainActor () async -> PermissionState = {
            ActivityAuthorizationInfo().areActivitiesEnabled ? .granted : .denied
        }
        return PermissionClient(read: read, request: read, openSettings: { openAppSettings() })
    }
    #else
    // MARK: Using this Mac

    /// Accessibility and Screen Recording as macOS reports them. macOS cannot say "asked and
    /// refused" apart from "never asked", so a permission is `denied` once Allow was pressed and
    /// it still is not on.
    static func computer(_ kind: ComputerPermissions.Kind, _ permissions: ComputerPermissions = .shared) -> PermissionClient {
        let state: @MainActor () -> PermissionState = {
            permissions.refresh()
            if permissions.granted(kind) { return .granted }
            return permissions.asked.contains(kind) ? .denied : .notAsked
        }
        return PermissionClient(
            read: { state() },
            request: {
                permissions.ask(kind)
                return state()
            },
            openSettings: { permissions.openPrivacySettings(kind) })
    }
    #endif
}

#if DEBUG
extension PermissionCenter {
    /// Pictures only: every row on this device, answered from a table. Allow grants without any
    /// system prompt. `fresh` has nothing answered, `mixed` a bit of everything, `allowed` all on.
    static func demo(_ preset: String) -> PermissionCenter {
        let answers = DemoAnswers(preset)
        var clients: [PermissionKind: PermissionClient] = [:]
        for kind in PermissionKind.listed(isMac: DeviceWords.isMac, direct: true) {
            clients[kind] = PermissionClient(
                read: { answers.state(kind) },
                request: { answers.grant(kind) },
                openSettings: {})
        }
        return PermissionCenter(clients: clients)
    }

    @MainActor
    private final class DemoAnswers {
        private var states: [PermissionKind: PermissionState] = [:]

        init(_ preset: String) {
            for kind in PermissionKind.allCases {
                switch preset {
                case "allowed": states[kind] = .granted
                case "mixed":
                    switch kind {
                    case .notifications, .microphone, .liveActivities: states[kind] = .granted
                    case .camera, .accessibility: states[kind] = .denied
                    default: states[kind] = .notAsked
                    }
                default: states[kind] = kind == .liveActivities ? .granted : .notAsked
                }
            }
        }

        func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notAsked }

        func grant(_ kind: PermissionKind) -> PermissionState {
            states[kind] = .granted
            return .granted
        }
    }
}
#endif
