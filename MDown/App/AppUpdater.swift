import AppKit
import Observation
import Sparkle
import SwiftUI

/// Keeps MDown up to date with Sparkle. Sparkle checks the appcast once a day on its own and offers
/// new versions; this object also remembers whether an update is waiting, so the sidebar can show
/// it, and lets the menu and sidebar start a check.
///
/// Updates are verified with the EdDSA public key in Info.plist (`SUPublicEDKey`); only archives
/// signed with the matching private key are installed.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// The version waiting to be installed, if Sparkle found one.
    private(set) var availableVersion: String?
    private(set) var isChecking = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// Starts Sparkle and, a moment after launch, quietly asks the appcast whether a newer version
    /// exists so the sidebar can show it without interrupting.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.lookForUpdateQuietly()
        }
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// A check the person asked for: Sparkle shows the new version and its notes, or says MDown is up
    /// to date.
    func checkForUpdates() {
        guard let controller else { return }
        isChecking = true
        controller.checkForUpdates(nil)
    }

    private func lookForUpdateQuietly() {
        guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
        isChecking = true
        updater.checkForUpdateInformation()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            availableVersion = version
            isChecking = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            availableVersion = nil
            isChecking = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            isChecking = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated {
            isChecking = false
        }
    }
}

/// The button beside New Document: a highlighted update arrow when a new version is waiting,
/// otherwise a refresh arrow that checks for one.
struct UpdateButton: View {
    private var updater: AppUpdater { .shared }

    var body: some View {
        Group {
            if let version = updater.availableVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Update to MDown \(version)", systemImage: "arrow.uturn.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
                .help("MDown \(version) is available. Click to update.")
            } else if updater.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .help("Checking for updates")
            } else {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Check for Updates")
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 22, height: 22)
    }
}
