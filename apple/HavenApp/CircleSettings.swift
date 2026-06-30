import Foundation
import SwiftUI
import LocalAuthentication

/// Per-circle preferences (on-device only), keyed by circle id. These live app-side rather
/// than in the Rust engine because they're personal viewing choices, not part of the shared
/// circle state: whether this circle's posts go into Spotlight, and whether opening the circle
/// requires a Face ID / Touch ID unlock.
@MainActor
final class CircleSettingsStore: ObservableObject {
    static let shared = CircleSettingsStore()

    @Published private var spotlight: [String: Bool]
    @Published private var biometric: [String: Bool]
    // Per-circle media overrides. A MISSING key = inherit the global default (SettingsStore).
    @Published private var saveOwn: [String: Bool]
    @Published private var saveOthers: [String: Bool]
    @Published private var optimize: [String: Bool]
    @Published private var retention: [String: Int]

    private let d = UserDefaults.standard
    private let kSpot = "haven.circle.spotlight"
    private let kBio = "haven.circle.biometric"
    private let kSaveOwn = "haven.circle.saveOwn"
    private let kSaveOthers = "haven.circle.saveOthers"
    private let kOptimize = "haven.circle.optimize"
    private let kRetention = "haven.circle.retention"

    private init() {
        spotlight = (d.dictionary(forKey: kSpot) as? [String: Bool]) ?? [:]
        biometric = (d.dictionary(forKey: kBio) as? [String: Bool]) ?? [:]
        saveOwn = (d.dictionary(forKey: kSaveOwn) as? [String: Bool]) ?? [:]
        saveOthers = (d.dictionary(forKey: kSaveOthers) as? [String: Bool]) ?? [:]
        optimize = (d.dictionary(forKey: kOptimize) as? [String: Bool]) ?? [:]
        retention = (d.dictionary(forKey: kRetention) as? [String: Int]) ?? [:]
    }

    /// Factory-reset this store — clear all per-circle settings + unlocks (in-memory + persisted).
    func wipe() {
        spotlight = [:]; biometric = [:]; saveOwn = [:]; saveOthers = [:]; optimize = [:]; retention = [:]
        [kSpot, kBio, kSaveOwn, kSaveOthers, kOptimize, kRetention].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: Media settings (per circle, falling back to the global default)

    func saveOwnToPhotos(_ c: String) -> Bool { saveOwn[c] ?? SettingsStore.shared.saveToPhotos }
    func saveOthersToPhotos(_ c: String) -> Bool { saveOthers[c] ?? SettingsStore.shared.saveOthersToPhotos }
    func autoOptimize(_ c: String) -> Bool { optimize[c] ?? SettingsStore.shared.autoOptimize }
    func retentionDays(_ c: String) -> Int { retention[c] ?? SettingsStore.shared.retentionDays }
    func retentionSecs(_ c: String) -> UInt64? { let n = retentionDays(c); return n <= 0 ? nil : UInt64(n) * 86_400 }

    /// True when the circle overrides a setting (so the UI can show "Custom" vs "Default").
    func hasMediaOverride(_ c: String) -> Bool {
        saveOwn[c] != nil || saveOthers[c] != nil || optimize[c] != nil || retention[c] != nil
    }

    // nil clears the override (back to the global default).
    func setSaveOwn(_ v: Bool?, for c: String) { saveOwn[c] = v; d.set(saveOwn, forKey: kSaveOwn); objectWillChange.send() }
    func setSaveOthers(_ v: Bool?, for c: String) { saveOthers[c] = v; d.set(saveOthers, forKey: kSaveOthers); objectWillChange.send() }
    func setOptimize(_ v: Bool?, for c: String) { optimize[c] = v; d.set(optimize, forKey: kOptimize); objectWillChange.send() }
    func setRetention(_ v: Int?, for c: String) { retention[c] = v; d.set(retention, forKey: kRetention); objectWillChange.send() }
    func clearMediaOverrides(for c: String) {
        saveOwn[c] = nil; saveOthers[c] = nil; optimize[c] = nil; retention[c] = nil
        d.set(saveOwn, forKey: kSaveOwn); d.set(saveOthers, forKey: kSaveOthers)
        d.set(optimize, forKey: kOptimize); d.set(retention, forKey: kRetention)
        objectWillChange.send()
    }
    /// Whether this circle has its OWN value for each setting (for the UI's per-row "default" state).
    func ownOverride(_ c: String) -> Bool? { saveOwn[c] }
    func othersOverride(_ c: String) -> Bool? { saveOthers[c] }
    func optimizeOverride(_ c: String) -> Bool? { optimize[c] }
    func retentionOverride(_ c: String) -> Int? { retention[c] }

    // MARK: Spotlight (per circle)

    func spotlightEnabled(_ circleId: String) -> Bool { spotlight[circleId] ?? false }

    func setSpotlight(_ on: Bool, for circleId: String) {
        spotlight[circleId] = on
        d.set(spotlight, forKey: kSpot)
        if on { SpotlightIndex.reindexCircle(circleId) } else { SpotlightIndex.clearCircle(circleId) }
    }

    /// Circle ids that opt into Spotlight AND aren't biometric-locked (a locked circle must
    /// never leak its posts into the system search index).
    var spotlightCircleIds: [String] {
        spotlight.filter { $0.value && !(biometric[$0.key] ?? false) }.map(\.key)
    }

    // MARK: Biometric lock (per circle)

    func biometricRequired(_ circleId: String) -> Bool { biometric[circleId] ?? false }

    func setBiometric(_ on: Bool, for circleId: String) {
        biometric[circleId] = on
        d.set(biometric, forKey: kBio)
        // Mirror the locked set so the Notification Service Extension can redact pushes for it.
        SharedLockedCircles.write(Set(biometric.filter { $0.value }.map(\.key)))
        // A circle that just became locked must drop out of Spotlight immediately.
        if on, spotlightEnabled(circleId) { SpotlightIndex.clearCircle(circleId) }
        if !on, spotlightEnabled(circleId) { SpotlightIndex.reindexCircle(circleId) }
        BiometricGate.shared.relock(circleId)
    }

    /// Whether the device can actually do biometric auth (so we hide the toggle otherwise).
    static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }
}

/// Tracks which biometric-locked circles are unlocked for the current foreground session.
/// Locking is per app-foreground: going to the background relocks everything.
@MainActor
final class BiometricGate: ObservableObject {
    static let shared = BiometricGate()
    @Published private(set) var unlocked: Set<String> = []
    @Published var lastError: String?

    /// True when this circle is gated and not yet unlocked this session.
    func isLocked(_ circleId: String) -> Bool {
        CircleSettingsStore.shared.biometricRequired(circleId) && !unlocked.contains(circleId)
    }

    /// Prompt for Face ID / Touch ID (falling back to the device passcode) to open a circle.
    func unlock(_ circleId: String) {
        guard isLocked(circleId) else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometrics/passcode set up — don't trap the user out of their own circle.
            unlocked.insert(circleId)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock this circle") { [weak self] ok, error in
            Task { @MainActor in
                if ok {
                    self?.unlocked.insert(circleId)
                    self?.lastError = nil
                } else {
                    self?.lastError = error?.localizedDescription
                    // Don't trap the user: if they have a circle that isn't locked, drop them
                    // there. If every circle is locked, they stay on the lock screen.
                    FeedStore.shared.switchToUnlockedCircle(excluding: circleId)
                }
            }
        }
    }

    /// Relock a specific circle (e.g. its requirement was just turned on).
    func relock(_ circleId: String) { unlocked.remove(circleId) }

    /// Relock everything — called when the app goes to the background.
    func relockAll() { unlocked.removeAll() }
}

/// The full-screen cover shown over a biometric-locked circle's feed until the user unlocks it.
struct CircleLockView: View {
    let circleName: String
    @ObservedObject private var gate = BiometricGate.shared
    let circleId: String

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(HavenTheme.pink)
                Text(circleName).font(.title3.weight(.semibold))
                Text("This circle is locked. Unlock with Face ID to view it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { gate.unlock(circleId) } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                        .background(HavenTheme.pink, in: Capsule()).foregroundStyle(.white)
                }
                if let err = gate.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { gate.unlock(circleId) }   // prompt immediately
    }
}

/// A full-screen privacy cover shown while a biometric-locked circle is active but the app
/// isn't frontmost — so the app-switcher snapshot (and a glance over your shoulder) shows
/// only this, never locked content.
struct PrivacyBlurView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(HavenTheme.pink)
                Text("Haven is locked").font(.headline)
            }
        }
    }
}

/// Settings for a single circle — rename it, control its Spotlight/biometric privacy, and
/// leave it. Mirrors the You settings screen, reached from the gear in the circle view.
struct CircleSettingsView: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var circleSettings = CircleSettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var isDefault: Bool { circleId == "default" }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                Section {
                    TextField("Circle name", text: $name)
                        .onSubmit { store.renameCircle(circleId, to: name) }
                } header: {
                    Text("Name")
                } footer: {
                    Text("What this circle is called for you and everyone in it.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { circleSettings.spotlightEnabled(circleId) },
                        set: { circleSettings.setSpotlight($0, for: circleId) }
                    )) { Label("Index in Spotlight", systemImage: "magnifyingglass") }
                    .tint(HavenTheme.pink)
                    .disabled(circleSettings.biometricRequired(circleId))

                    if CircleSettingsStore.biometricsAvailable {
                        Toggle(isOn: Binding(
                            get: { circleSettings.biometricRequired(circleId) },
                            set: { circleSettings.setBiometric($0, for: circleId) }
                        )) { Label("Require Face ID to open", systemImage: "faceid") }
                        .tint(HavenTheme.pink)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(circleSettings.biometricRequired(circleId)
                         ? "Locked — hidden from Spotlight, and notifications won't show content until you unlock with Face ID."
                         : "Spotlight finds this circle's posts in system search (on-device only). Face ID locks the circle each time you open the app.")
                }

                Section {
                    Picker(selection: Binding(get: { circleSettings.ownOverride(circleId) },
                                              set: { circleSettings.setSaveOwn($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.saveToPhotos ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Save your posts", systemImage: "square.and.arrow.down") }
                    Picker(selection: Binding(get: { circleSettings.othersOverride(circleId) },
                                              set: { circleSettings.setSaveOthers($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.saveOthersToPhotos ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Save others' posts", systemImage: "square.and.arrow.down.on.square") }
                    Picker(selection: Binding(get: { circleSettings.optimizeOverride(circleId) },
                                              set: { circleSettings.setOptimize($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.autoOptimize ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Auto-optimize media", systemImage: "wand.and.stars") }
                    Picker(selection: Binding(get: { circleSettings.retentionOverride(circleId) },
                                              set: { circleSettings.setRetention($0, for: circleId) })) {
                        Text("Default").tag(Int?.none)
                        Text("Off").tag(Int?.some(0)); Text("After 1 week").tag(Int?.some(7))
                        Text("After 1 month").tag(Int?.some(30)); Text("After 3 months").tag(Int?.some(90))
                        Text("After 1 year").tag(Int?.some(365))
                    } label: { Label("Auto-delete old posts", systemImage: "trash") }
                    if circleSettings.hasMediaOverride(circleId) {
                        Button("Use the app defaults here") { circleSettings.clearMediaOverrides(for: circleId) }
                    }
                } header: {
                    Text("Media in this circle")
                } footer: {
                    Text("Override the app-wide Photos / optimize / auto-delete defaults just for this circle.")
                        .fixedSize(horizontal: false, vertical: true)   // wrap fully; don't truncate on macOS
                }

                // Per-circle relay OVERRIDE: pick which configured relays THIS circle uses, beyond the
                // global default. Configuring/adding relays lives in Settings ▸ Relays — this screen only
                // SELECTS from already-configured relays, plus a link to go manage them.
                CircleRelayOverrideSection(circleId: circleId)
                Section {
                    NavigationLink { RelaysView() } label: {
                        Label("Manage relays", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Add, name, deactivate, or set a default relay under Settings ▸ Relays.")
                }

                if !isDefault {
                    Section {
                        Button(role: .destructive) {
                            store.leaveActiveCircle(); dismiss()
                        } label: {
                            Label("Leave this circle", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Circle settings")
        .havenInlineNavTitle()
        .onAppear { name = store.circles.first { $0.id == circleId }?.name ?? "" }
        .onDisappear { store.renameCircle(circleId, to: name) }   // persist a rename made without hitting return
    }
}

/// Per-circle relay OVERRIDE: toggle which of your configured relays THIS circle uses. The all-circles
/// default still applies on top (shown but not toggleable here — manage it under Settings ▸ Relays).
/// Wired to RelayMailboxStore's per-circle associations (`relaysByCircle`).
struct CircleRelayOverrideSection: View {
    let circleId: String
    @ObservedObject private var store = RelayMailboxStore.shared

    private var configured: [RelayEntry] { store.allEntries().filter { $0.active } }
    private var explicit: Set<String> { Set(store.explicitRelays(forCircle: circleId)) }

    var body: some View {
        if configured.isEmpty {
            EmptyView()
        } else {
            Section {
                ForEach(configured) { e in
                    let isDefault = store.defaultNodeHex == e.hex
                    Toggle(isOn: Binding(
                        get: { explicit.contains(e.hex) || isDefault },
                        set: { FeedStore.shared.setCircleRelay(e.hex, circleId: circleId, on: $0) }
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: e.isS3 ? "externaldrive.fill" : "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.subheadline)
                                if isDefault { Text("Default — inherited by every circle").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .tint(HavenTheme.pink)
                    .disabled(isDefault)   // the default is always on; manage it under Settings ▸ Relays
                }
            } header: {
                Text("Relays for this circle")
            } footer: {
                Text("Choose which configured relays this circle uses, overriding the default. Posts are mirrored to every relay turned on here and read from any that's reachable. The default relay (if set) always applies — change it under Settings ▸ Relays.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
