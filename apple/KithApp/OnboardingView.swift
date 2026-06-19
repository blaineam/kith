import SwiftUI

/// A warm, plain-language first run: welcome → pick your name & avatar → how it
/// works → into the app.
struct OnboardingView: View {
    @ObservedObject var profile: ProfileStore
    @State private var step = 0
    @State private var name = ""
    @State private var emoji = "🌿"

    var body: some View {
        ZStack {
            KithBackground()
            VStack {
                content
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
                    .id(step)
                Spacer()
                controls
            }
            .padding(24)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: pickName
        default: howItWorks
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Circle()
                .fill(KithTheme.brand)
                .frame(width: 110, height: 110)
                .overlay(Text("🜂").font(.system(size: 52)))
                .shadow(color: KithTheme.pink.opacity(0.4), radius: 20, y: 10)
            BrandText(text: "Welcome to Kith")
            Text("A private little place for the people you love.\nNo ads. No tracking. No strangers. Just your people.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var pickName: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("What should your\npeople call you?")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Circle()
                .fill(KithTheme.brand)
                .frame(width: 92, height: 92)
                .overlay(Text(emoji).font(.system(size: 44)))

            TextField("Your name or nickname", text: $name)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                .padding(.horizontal, 20)

            Text("Pick an avatar")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(ProfileStore.avatarChoices, id: \.self) { e in
                    Text(e).font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .background(emoji == e ? AnyShapeStyle(KithTheme.brandHorizontal.opacity(0.25)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Circle())
                        .overlay(Circle().strokeBorder(emoji == e ? KithTheme.pink : .clear, lineWidth: 2))
                        .onTapGesture { withAnimation(KithTheme.snappy) { emoji = e } }
                }
            }
            Spacer()
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("How Kith works")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            point("🔒", "Private by design", "Everything you share is locked so only the people in your circle can ever see it.")
            point("🚫", "No ads, no tracking", "There's no algorithm and no company watching. Kith doesn't collect anything about you.")
            point("🤝", "You choose your circle", "Nothing happens with strangers. You invite the people you want, one at a time.")
            Spacer()
        }
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(icon).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Button(action: advance) {
                Text(step == 0 ? "Get started" : step == 1 ? "Continue" : "Enter Kith")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(step == 1 && name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(step == 1 && name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            HStack(spacing: 7) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i == step ? AnyShapeStyle(KithTheme.brandHorizontal) : AnyShapeStyle(Color(.tertiaryLabel)))
                        .frame(width: i == step ? 22 : 7, height: 7)
                        .animation(KithTheme.bouncy, value: step)
                }
            }
        }
    }

    private func advance() {
        if step == 1 {
            profile.displayName = name.trimmingCharacters(in: .whitespaces)
            profile.emoji = emoji
        }
        if step >= 2 {
            withAnimation(KithTheme.smooth) { profile.onboarded = true }
        } else {
            withAnimation(KithTheme.smooth) { step += 1 }
        }
    }
}
