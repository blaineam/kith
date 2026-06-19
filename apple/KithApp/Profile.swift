import SwiftUI
import PhotosUI

/// The user's chosen display name, emoji, and optional profile photo. Not PII
/// collection — it lives on this device and is only ever shared, end-to-end, with
/// people you connect to.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var displayName: String { didSet { defaults.set(displayName, forKey: nameKey) } }
    @Published var emoji: String { didSet { defaults.set(emoji, forKey: emojiKey) } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: doneKey) } }
    @Published private(set) var avatar: UIImage?

    private let defaults = UserDefaults.standard
    private let nameKey = "kith.displayName"
    private let emojiKey = "kith.emoji"
    private let doneKey = "kith.onboarded"

    private init() {
        displayName = defaults.string(forKey: nameKey) ?? ""
        emoji = defaults.string(forKey: emojiKey) ?? "🌿"
        onboarded = defaults.bool(forKey: doneKey)
        avatar = Self.loadAvatar()

        if ProcessInfo.processInfo.environment["KITH_SKIP_ONBOARDING"] == "1" {
            if displayName.isEmpty { displayName = "You" }
            onboarded = true
        }
    }

    /// Set or clear the custom profile photo (emoji remains the fallback).
    func setAvatar(_ image: UIImage?) {
        avatar = image
        if let image, let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: Self.avatarURL)
        } else {
            try? FileManager.default.removeItem(at: Self.avatarURL)
        }
    }

    private static var avatarURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kith-avatar.jpg")
    }
    private static func loadAvatar() -> UIImage? {
        (try? Data(contentsOf: avatarURL)).flatMap(UIImage.init)
    }

    static let avatarChoices = ["🌿", "🌸", "🔥", "⭐️", "🦊", "🐢", "🌊", "🍯", "🎈", "🪴", "🦋", "🌙"]
}

/// A profile avatar: the custom photo if set, otherwise the emoji on a brand circle.
struct KithAvatar: View {
    var image: UIImage?
    var emoji: String
    var size: CGFloat
    var gradient: LinearGradient = KithTheme.brand

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                gradient.overlay(Text(emoji).font(.system(size: size * 0.5)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Single-image picker (Photos library) returning a `UIImage`.
struct SingleImagePicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SingleImagePicker
        init(_ parent: SingleImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { parent.dismiss() }
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                if let img = object as? UIImage {
                    Task { @MainActor in self.parent.onPicked(img) }
                }
            }
        }
    }
}

/// Edit your name, emoji, and profile photo.
struct EditProfileSheet: View {
    @ObservedObject private var profile = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        KithAvatar(image: profile.avatar, emoji: profile.emoji, size: 110)
                            .shadow(color: KithTheme.pink.opacity(0.3), radius: 14, y: 8)

                        HStack(spacing: 12) {
                            Button { showPhotoPicker = true } label: {
                                Label(profile.avatar == nil ? "Add photo" : "Change photo", systemImage: "photo")
                            }.buttonStyle(.bordered).tint(KithTheme.pink)
                            if profile.avatar != nil {
                                Button(role: .destructive) { profile.setAvatar(nil) } label: {
                                    Label("Remove", systemImage: "trash")
                                }.buttonStyle(.bordered)
                            }
                        }

                        TextField("Your name", text: $profile.displayName)
                            .font(.title3).multilineTextAlignment(.center)
                            .padding(.vertical, 12).background(.background, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1))).padding(.horizontal, 30)

                        Text(profile.avatar == nil ? "Pick an emoji" : "Emoji (used if you remove your photo)")
                            .font(.footnote).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(ProfileStore.avatarChoices, id: \.self) { e in
                                Text(e).font(.system(size: 30)).frame(width: 44, height: 44)
                                    .background(profile.emoji == e ? AnyShapeStyle(KithTheme.brandHorizontal.opacity(0.25)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Circle())
                                    .overlay(Circle().strokeBorder(profile.emoji == e ? KithTheme.pink : .clear, lineWidth: 2))
                                    .onTapGesture { withAnimation(KithTheme.snappy) { profile.emoji = e } }
                            }
                        }.padding(.horizontal, 20)
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPhotoPicker) {
                SingleImagePicker { profile.setAvatar($0) }
            }
        }
    }
}
