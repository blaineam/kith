import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Move your identity to another device (another phone, the Mac, the web app). The
/// transfer code IS your master seed — anyone holding it becomes you — so it's shown
/// only behind a confirmation and meant to be scanned by *your* other device.
struct TransferIdentityView: View {
    let accountStore: AccountStore
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 44)).foregroundStyle(HavenTheme.pink).padding(.top, 8)
                    Text("Move to another device").font(.title3.bold())
                    Text("On your other device, choose **Restore identity** and scan this code. You'll be the same person in your circle — same posts, same contacts.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if revealed {
                        let code = accountStore.transferCode()
                        if let img = QRCode.image(from: code) {
                            Image(platformImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Button {
                            PlatformPasteboard.setSecret(code)   // local-only + expiring (it's the full identity)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy transfer code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered).tint(HavenTheme.pink)
                        Label("Anyone with this code can become you. Never share it with anyone else, and don't post it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Button { revealed = true } label: {
                            Label("Reveal transfer code", systemImage: "eye.fill")
                        }
                        .buttonStyle(BrandButtonStyle())
                        Text("Only do this with your own device in front of you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Transfer")
        .havenInlineNavTitle()
    }
}

/// Link a *second* device to this identity. Unlike "Move", linking is meant to keep both
/// devices active on the same identity — they each post and receive, and (once both hold the
/// same seed) can sync content to each other directly. The mechanism is the same transfer
/// code, framed for keeping both devices.
struct LinkDeviceView: View {
    let accountStore: AccountStore
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 44)).foregroundStyle(HavenTheme.pink).padding(.top, 8)
                    Text("Link a new device").font(.title3.bold())
                    Text("On your other device, open Haven → **Settings → Advanced → Restore identity here** and scan this code. Both devices then act as **you** — each can post and receive, and they sync to each other directly when they're near or online together.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if revealed {
                        let code = accountStore.transferCode()
                        if let img = QRCode.image(from: code) {
                            Image(platformImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Button {
                            PlatformPasteboard.string = code
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy link code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered).tint(HavenTheme.pink)
                        Label("This code grants your identity. Only scan it onto a device you own — never share or post it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Button { revealed = true } label: {
                            Label("Show link code", systemImage: "qrcode")
                        }
                        .buttonStyle(BrandButtonStyle())
                        Text("Only do this with your own second device in front of you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Link device")
        .havenInlineNavTitle()
    }
}

/// Adopt an existing identity on this device by scanning/pasting a transfer code.
struct RestoreIdentityView: View {
    let accountStore: AccountStore
    var onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var error = false
    @State private var scanning = true

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Text("Restore your identity").font(.title3.bold()).padding(.top, 8)
                    Text("Scan the transfer code from your other device, or paste it below.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if scanning {
                        QRScannerView { code in attempt(code) }
                            .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2))
                    }

                    VStack(spacing: 8) {
                        TextField("Paste your recovery code", text: $pasted, axis: .vertical)
                            .havenAutocap(.never).autocorrectionDisabled()
                            .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        Button { attempt(pasted) } label: { Label("Restore from code", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if error {
                        Label("That code isn't valid. Check you copied the whole thing.", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Label("This replaces the identity on this device.", systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .navigationTitle("Restore")
        .havenInlineNavTitle()
    }

    private func attempt(_ code: String) {
        if accountStore.restore(fromTransferCode: code) {
            FeedStore.shared.reconfigure(seed: accountStore.account.secretSeed())
            onRestored()
            dismiss()
        } else {
            error = true
        }
    }
}
