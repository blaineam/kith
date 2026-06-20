import SwiftUI

/// Where Kith's web invite links live. The static landing page at
/// `wemiller.com/apps/kith/` resolves `/u/<id>#<verify>` into an "open in Kith" page.
enum KithSite {
    static let inviteDomain = "wemiller.com/apps/kith"
}

/// The guided "make a connection" flow: show your invite, or add a friend from
/// theirs — in plain language, with friendly safety words instead of hex.
struct ConnectView: View {
    let account: Account
    @ObservedObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var pasted = ""
    @State private var found: LinkInfo?
    @State private var friendName = ""
    @State private var problem: String?
    @State private var addedName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        Picker("", selection: $mode) {
                            Text("Invite a friend").tag(0)
                            Text("Add a friend").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if mode == 0 { invite } else { addFriend }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: - Invite

    private var invite: some View {
        VStack(spacing: 16) {
            Text("Invite someone you trust")
                .font(.title3.bold())
            Text("Have them scan this, or send them your invite link.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qr = QRCode.image(from: account.kithUri()) {
                Image(uiImage: qr)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: KithTheme.violet.opacity(0.25), radius: 16, y: 8)
            }

            if let url = URL(string: account.kithLink(domain: KithSite.inviteDomain)) {
                ShareLink(item: url) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(BrandButtonStyle())
            }

            safetyCard(
                title: "Your safety words",
                words: SafetyWords.words(fromHex: account.verificationHex()),
                note: "When your friend adds you, make sure they see these same words — that's how you both know it's really you."
            )
        }
        .kithCard()
    }

    // MARK: - Add a friend

    private var addFriend: some View {
        VStack(spacing: 16) {
            if let added = addedName {
                addedConfirmation(added)
            } else if let f = found {
                foundConfirmation(f)
            } else {
                Text("Add a friend")
                    .font(.title3.bold())
                Text("Paste the invite link your friend sent you.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Paste invite link…", text: $pasted, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pasteLink")

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                Button("Find my friend") { lookup() }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .kithCard()
    }

    private func foundConfirmation(_ f: LinkInfo) -> some View {
        VStack(spacing: 16) {
            Text("Found someone! 🎉").font(.title3.bold())
            safetyCard(
                title: "Check these safety words",
                words: SafetyWords.words(fromHex: f.verificationHex),
                note: "Ask your friend to read their safety words aloud. If they match, it's really them."
            )
            TextField("Give them a name", text: $friendName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("friendName")
            Button("Add to my circle") {
                let name = friendName.trimmingCharacters(in: .whitespaces)
                contacts.add(name: name.isEmpty ? "Friend" : name, idHex: f.idHex)
                withAnimation(KithTheme.bouncy) { addedName = name.isEmpty ? "Friend" : name }
            }
            .buttonStyle(BrandButtonStyle())
            Text("You'll be connected the moment you're both online.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func addedConfirmation(_ name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54)).foregroundStyle(.green)
            Text("\(name) is in your circle")
                .font(.title3.bold()).multilineTextAlignment(.center)
            Text("They'll show up once you're both online.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(BrandButtonStyle())
        }
    }

    private func safetyCard(title: String, words: [String], note: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(words, id: \.self) { w in
                    Text(w)
                        .font(.callout.weight(.semibold).monospaced())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(KithTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func lookup() {
        problem = nil
        do {
            let info = try parseLink(s: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            withAnimation(KithTheme.bouncy) { found = info }
        } catch {
            problem = "That doesn't look like a Kith invite link. Double-check and try again."
        }
    }
}
