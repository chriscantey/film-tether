import SwiftUI
import Combine
import Sparkle

/// Updates, the one way every app of ours does them: Sparkle, a feed on the
/// app's site, an opt-out, nothing collected. The updater exists only when the
/// bundle carries `SUFeedURL`. A dev build carries none, so it never checks
/// and shows no update item. The bundle script writes the feed keys per line
/// (`scripts/updates-plist.sh`), never the source.
///
/// Nothing here, and nothing in the bundle, turns on `SUEnableSystemProfiling`:
/// the only traffic is an HTTPS fetch of the feed once a day, when the person
/// allows it, and of the update when they say install.
@MainActor
enum AppUpdates {
    static let controller: SPUStandardUpdaterController? = {
        guard feedURL != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static var updater: SPUUpdater? { controller?.updater }

    private static var started = false

    /// Starts the updater once, from the main window's `onAppear`, never from
    /// `App.init`: started there, Sparkle asks its first question before the
    /// window exists, and the app comes up with the question and no window
    /// (seen on both film apps after the update proof).
    static func start() {
        guard let controller, !started else { return }
        started = true
        controller.startUpdater()
    }

    /// The feed the bundle was built for, nil on a build with no feed.
    static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
    }

    /// The one sentence on updates, the same on the site. The host is the
    /// feed's own, so a beta build names the place it really checks.
    static var privacySentence: String {
        let host = feedURL?.host ?? "its site"
        return "If you let it, Film Tether checks \(host) once a day for a new version, "
            + "with a standard HTTPS request and nothing else."
    }

    /// For the About panel: the credit and the sentence, or the fact that this
    /// build does not check at all.
    static var aboutSentence: String {
        guard feedURL != nil else { return "This build does not check for updates." }
        return "Updates come through Sparkle (MIT). " + privacySentence
    }
}

/// "Check for Updates…" in the app menu, enabled while Sparkle can start a
/// check (not while one is running or an update sheet is up).
struct CheckForUpdatesButton: View {
    private let updater: SPUUpdater
    @ObservedObject private var state: CheckForUpdatesState

    init(updater: SPUUpdater) {
        self.updater = updater
        state = CheckForUpdatesState(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!state.canCheckForUpdates)
    }
}

final class CheckForUpdatesState: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

/// Settings > Updates: the one switch, bound to Sparkle's own setting, and the
/// sentence that says what the app sends (nothing).
struct UpdatesSettingsTab: View {
    let updater: SPUUpdater

    var body: some View {
        let automatic = Binding<Bool>(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: automatic)
            } footer: {
                Text(AppUpdates.privacySentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
