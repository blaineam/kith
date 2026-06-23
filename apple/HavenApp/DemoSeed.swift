import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Screenshot / demo launch routing
//
// The App Store / portfolio screenshot pipeline (Tools/capture_screenshots.sh →
// _shared/update-screenshots.sh) launches the app in the simulator with a set of
// launch-environment flags so each scene can be captured deterministically and
// WITHOUT any real data:
//
//   HAVEN_DEMO=1            seed the PII-free synthetic dataset (DemoSeeder)
//   HAVEN_SKIP_ONBOARDING=1 jump straight into the app (no onboarding flow)
//   HAVEN_NO_NET=1          never bring the live P2P node online (offline, fast, deterministic)
//   HAVEN_TAB=<circle|messages|you>   which tab is selected at launch
//   HAVEN_SCENE=<scene>     auto-present a specific scene for its hero shot
//
// Everything here is gated on HAVEN_DEMO so it is impossible to trigger in a real
// build — the synthetic identities, circles, posts, stories, and DMs only ever
// exist when the capture harness asks for them.

/// A deep-link scene the capture harness can ask the app to auto-present.
enum DemoScene: String {
    case feed        // circle feed (default — nothing extra to present)
    case you         // the You profile (default for the `you` tab)
    case messages    // the DM list (default for the `messages` tab)
    case thread      // open the first DM thread
    case story       // full-screen story viewer
    case identity    // the identity switcher / backup sheet
    case call        // an in-progress group call overlay
}

enum DemoEnv {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// True when the PII-free demo dataset should be seeded + shown.
    static var isDemo: Bool { env["HAVEN_DEMO"] == "1" }
    /// The scene to auto-present, if any.
    static var scene: DemoScene? { env["HAVEN_SCENE"].flatMap(DemoScene.init) }
}

// MARK: - Demo seeder
//
// Drives the REAL hybrid-PQ social engine with a small cast of fictional people so
// screenshots show a populated, lively app without ever touching real contacts,
// circles, posts, or messages. It does this exactly the way the app does at runtime:
// each "friend" is a full `HavenSocial` identity (a deterministic throwaway seed);
// they handshake into circles, author sealed posts/stories/DMs, and those envelopes
// are `receive()`d into the user's engine — so the feed, reactions, comments, stories
// tray, DM threads, and circle switcher are all genuinely populated, not faked views.

@MainActor
enum DemoSeeder {
    private static var didSeed = false

    /// Friend node ids + the demo circle name, stashed so the `call` scene can spin up a
    /// group-call overlay with the right participants after seeding.
    private(set) static var callParticipants: [String] = []
    private(set) static var callName = "Weekend Crew"

    /// A fictional person in the demo dataset.
    private struct Persona {
        let name: String
        let emoji: String
        let bio: String
        let seedByte: UInt8     // fills a deterministic 32-byte account seed
        var engine: HavenSocial?
        var hex: String = ""
    }

    /// Seed the dataset once. Safe to call repeatedly (idempotent within a launch).
    static func seed(feed: FeedStore) {
        guard DemoEnv.isDemo, !didSeed, let main = feed.demoEngine else { return }
        didSeed = true

        // ── The user ("me") ───────────────────────────────────────────────────────
        let me = ProfileStore.shared
        me.displayName = "Riley Avery"
        me.emoji = "🌿"
        me.bio = "designer · plant hoarder · weekend hiker 🌄"
        me.link = "rileyavery.studio"
        if let avatar = DemoArt.avatar(top: (0.40, 0.78, 0.55), bottom: (0.16, 0.52, 0.82)) {
            me.setAvatar(avatar)
        }

        let mainHex = main.myNodeHex()
        main.createCircle(id: "default", name: "Your circle")

        // ── The cast ──────────────────────────────────────────────────────────────
        var people = [
            Persona(name: "Maya Quinn",  emoji: "🌸", bio: "ceramics & cold brew", seedByte: 0xA1),
            Persona(name: "Theo Park",   emoji: "🦊", bio: "trail runner, map nerd", seedByte: 0xB2),
            Persona(name: "Nina Brooks", emoji: "🦋", bio: "film photography", seedByte: 0xC3),
            Persona(name: "Sam Rivera",  emoji: "🌊", bio: "surf + sourdough", seedByte: 0xD4),
        ]

        for i in people.indices {
            guard let engine = try? HavenSocial(accountSeed: seedData(people[i].seedByte)) else { continue }
            people[i].engine = engine
            engine.createCircle(id: "default", name: "Your circle")
            // I learn their keys (so I can open their posts) and they learn mine (so they can
            // seal posts to a circle that includes me).
            let hex = (try? main.addContactBundle(circleId: "default", bundle: engine.myBundle())) ?? ""
            _ = try? engine.addContactBundle(circleId: "default", bundle: main.myBundle())
            people[i].hex = hex
            guard !hex.isEmpty else { continue }
            let p = people[i]
            ContactsStore.shared.add(name: p.name, idHex: hex)
            ContactsStore.shared.setCard(idHex: hex, name: p.name, bio: p.bio, link: "", avatar: "", emoji: p.emoji)
            feed.recordHeard(hex)   // shows a live green "Connected" dot
        }
        let valid = people.filter { $0.engine != nil && !$0.hex.isEmpty }
        callParticipants = Array(valid.prefix(3).map(\.hex))

        // ── Demo media (abstract, unmistakably synthetic gradient "photos") ─────────
        DemoArt.installPhotos()

        // ── Stories tray (me + two friends) ─────────────────────────────────────────
        story(main, by: valid.first, refs: ["img_demo_sunset"], caption: "golden hour 🌅", at: mins(40))
        story(main, by: valid.dropFirst().first, refs: ["img_demo_trail"], caption: "made it to the ridge", at: mins(95))
        // My own story.
        _ = try? main.post(circleId: "default", body: "studio day ✷", media: ["img_demo_studio"],
                           music: nil, retentionSecs: 86_400, story: true, muteVideo: false,
                           createdAt: msAgo(mins(20)))

        // ── The circle feed: a lively mix of friends + me, with reactions + comments ─
        // Friend posts (each is sealed by the friend and received into my engine), so the
        // feed is authentically multi-author.
        let p1 = friendPost(main, valid: valid, by: 0, body: "first throw off the new wheel 🪴 obsessed",
                            media: ["img_demo_studio"], at: mins(180))
        let p2 = friendPost(main, valid: valid, by: 1, body: "12 miles before breakfast. trail magic is real.",
                            media: ["img_demo_trail"], music: track("Sunrun", "The Wanderers"), at: mins(140))
        let p3 = myPost(main, body: "new little corner of the studio came together today 🌿",
                        media: ["img_demo_studio2"], at: mins(75))
        let p4 = friendPost(main, valid: valid, by: 2, body: "shot a whole roll at the coast. can't wait to develop these.",
                            media: ["img_demo_coast"], at: mins(30))

        // Reactions + comments fan in from the circle. Friends only react to posts they hold,
        // so we feed my posts to them first (done inside the helpers below).
        react(main, valid: valid, targets: p1, emoji: "🔥", by: [1, 2, 3])
        react(main, valid: valid, targets: p1, emoji: "🪴", by: [0])
        comment(main, valid: valid, target: p1, by: 1, body: "the glaze on this!! 😍", at: mins(170))
        comment(main, valid: valid, target: p1, by: 3, body: "teach me your ways", at: mins(165))

        react(main, valid: valid, targets: p2, emoji: "👟", by: [0, 2])
        comment(main, valid: valid, target: p2, by: 0, body: "those views are unreal", at: mins(130))

        react(main, valid: valid, targets: p3, emoji: "🌿", by: [0, 1, 2, 3])
        comment(main, valid: valid, target: p3, by: 2, body: "cozy!! love the light in here", at: mins(60))

        react(main, valid: valid, targets: p4, emoji: "🎞️", by: [0, 1])
        react(main, valid: valid, targets: p4, emoji: "🌊", by: [3])

        // ── A second circle, so the switcher is populated ───────────────────────────
        let crew = "demo-weekend-crew"
        main.createCircle(id: crew, name: "Weekend Crew")
        for p in valid.prefix(3) {
            _ = try? main.addExistingToCircle(circleId: crew, nodeHex: p.hex)
            p.engine?.createCircle(id: crew, name: "Weekend Crew")
            _ = try? p.engine?.addContactBundle(circleId: crew, bundle: main.myBundle())
        }
        if let env = try? valid.first?.engine?.post(circleId: crew, body: "who's in for the cabin this weekend? ⛰️",
                                                     media: [], music: nil, retentionSecs: nil, story: false,
                                                     muteVideo: false, createdAt: msAgo(mins(220))) {
            _ = try? main.receive(circleId: crew, envelope: env)
        }
        _ = try? main.post(circleId: crew, body: "me!! bringing the sourdough 🍞", media: [], music: nil,
                           retentionSecs: nil, story: false, muteVideo: false, createdAt: msAgo(mins(210)))

        // ── DM threads (each DM is a private 2-person circle) ───────────────────────
        if valid.count >= 1 { seedDM(main: main, mainHex: mainHex, friend: valid[0], lines: [
            (false, "did you see the new kiln schedule?", mins(300), nil),
            (true,  "yes! booked us both for saturday 🔥", mins(298), nil),
            (false, "you're the best. coffee after?", mins(295), nil),
            (true,  "always ☕️", mins(292), track("Slow Morning", "Wax & Wane")),
        ]) }
        if valid.count >= 2 { seedDM(main: main, mainHex: mainHex, friend: valid[1], lines: [
            (false, "trail conditions look perfect for sunday", mins(500), nil),
            (true,  "sending the gpx now 🗺️", mins(496), nil),
            (false, "🙌", mins(495), nil),
        ]) }

        feed.refreshCircles()
        feed.refresh()
        feed.demoPersist()
    }

    /// Kick off a demo group-call overlay (used by the `call` scene). Slight delay so the
    /// overlay animates in over the seeded feed.
    static func startDemoCall() {
        guard DemoEnv.isDemo, !callParticipants.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CallManager.shared.enterDemoCall(participants: callParticipants, name: callName)
        }
    }

    // MARK: - Authoring helpers

    /// A friend authors a post into the default circle; it's received into my engine. Returns
    /// the shared post id (so reactions/comments can target it).
    @discardableResult
    private static func friendPost(_ main: HavenSocial, valid: [Persona], by i: Int, body: String,
                                   media: [String] = [], music: TrackRefFfi? = nil, at minutesAgo: Int) -> String? {
        guard valid.indices.contains(i), let engine = valid[i].engine else { return nil }
        let ts = msAgo(minutesAgo)
        guard let env = try? engine.post(circleId: "default", body: body, media: media, music: music,
                                         retentionSecs: nil, story: false, muteVideo: false, createdAt: ts),
              (try? main.receive(circleId: "default", envelope: env)) == true else { return nil }
        return idForCreatedAt(main, ts)
    }

    /// I author a post into the default circle. Returns its id.
    @discardableResult
    private static func myPost(_ main: HavenSocial, body: String, media: [String] = [],
                              music: TrackRefFfi? = nil, at minutesAgo: Int) -> String? {
        let ts = msAgo(minutesAgo)
        guard (try? main.post(circleId: "default", body: body, media: media, music: music,
                              retentionSecs: nil, story: false, muteVideo: false, createdAt: ts)) != nil
        else { return nil }
        return idForCreatedAt(main, ts)
    }

    /// Friends react to a target post. `by` are indices into `valid`.
    private static func react(_ main: HavenSocial, valid: [Persona], targets id: String?, emoji: String, by: [Int]) {
        guard let id else { return }
        for i in by {
            guard valid.indices.contains(i), let engine = valid[i].engine else { continue }
            // Ensure the friend holds the target post (receive my circle's envelopes once).
            ensureHasCircleHistory(main: main, friend: engine)
            if let env = try? engine.react(circleId: "default", target: id, emoji: emoji, createdAt: msAgo(mins(5))) {
                _ = try? main.receive(circleId: "default", envelope: env)
            }
        }
    }

    private static func comment(_ main: HavenSocial, valid: [Persona], target id: String?, by i: Int,
                                body: String, at minutesAgo: Int) {
        guard let id, valid.indices.contains(i), let engine = valid[i].engine else { return }
        ensureHasCircleHistory(main: main, friend: engine)
        if let env = try? engine.comment(circleId: "default", target: id, body: body, media: [], createdAt: msAgo(minutesAgo)) {
            _ = try? main.receive(circleId: "default", envelope: env)
        }
    }

    /// Replay my whole default-circle history into a friend's engine so they can react/comment on
    /// my posts (idempotent — receiving a known envelope is a no-op).
    private static func ensureHasCircleHistory(main: HavenSocial, friend: HavenSocial) {
        for env in main.syncEnvelopes(circleId: "default") {
            _ = try? friend.receive(circleId: "default", envelope: env)
        }
    }

    private static func story(_ main: HavenSocial, by persona: Persona?, refs: [String], caption: String, at minutesAgo: Int) {
        guard let engine = persona?.engine else { return }
        if let env = try? engine.post(circleId: "default", body: caption, media: refs, music: nil,
                                      retentionSecs: 86_400, story: true, muteVideo: false, createdAt: msAgo(minutesAgo)) {
            _ = try? main.receive(circleId: "default", envelope: env)
        }
    }

    /// Build a two-person DM circle and a short back-and-forth thread.
    private static func seedDM(main: HavenSocial, mainHex: String, friend: Persona,
                               lines: [(mine: Bool, body: String, mins: Int, music: TrackRefFfi?)]) {
        guard let engine = friend.engine else { return }
        let dmId = "dm:" + [mainHex, friend.hex].sorted().joined(separator: "-")
        main.createCircle(id: dmId, name: friend.name)
        _ = try? main.addExistingToCircle(circleId: dmId, nodeHex: friend.hex)
        engine.createCircle(id: dmId, name: "Riley Avery")
        _ = try? engine.addContactBundle(circleId: dmId, bundle: main.myBundle())
        for line in lines {
            let ts = msAgo(line.mins)
            if line.mine {
                _ = try? main.post(circleId: dmId, body: line.body, media: [], music: line.music,
                                   retentionSecs: nil, story: false, muteVideo: false, createdAt: ts)
            } else if let env = try? engine.post(circleId: dmId, body: line.body, media: [], music: line.music,
                                                 retentionSecs: nil, story: false, muteVideo: false, createdAt: ts) {
                _ = try? main.receive(circleId: dmId, envelope: env)
            }
        }
    }

    // MARK: - Small utilities

    private static func idForCreatedAt(_ main: HavenSocial, _ ts: UInt64) -> String? {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return main.feed(circleId: "default", nowMs: now, viewerRetentionSecs: nil)
            .first { $0.createdAt == ts }?.id
    }

    private static func track(_ title: String, _ artist: String) -> TrackRefFfi {
        TrackRefFfi(catalogId: "demo-\(title)", title: title, artist: artist, artworkUrl: "", durationMs: 192_000)
    }

    private static func mins(_ m: Int) -> Int { m }
    private static func msAgo(_ minutesAgo: Int) -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 - Double(minutesAgo) * 60) * 1000)
    }

    /// A deterministic 32-byte account seed from a single distinguishing byte.
    private static func seedData(_ b: UInt8) -> Data {
        var d = Data(count: 32)
        for i in 0..<32 { d[i] = b &+ UInt8(i) }
        return d
    }
}

// MARK: - Synthetic demo art
//
// All demo imagery is generated on-device with Core Graphics — abstract gradient
// "photos" and avatars. Nothing here is, or resembles, a real person or place: it is
// impossible for this to leak PII into a screenshot.

@MainActor
enum DemoArt {
    typealias RGB = (CGFloat, CGFloat, CGFloat)

    /// Install the gradient "photos" the demo posts/stories reference, under fixed refs.
    static func installPhotos() {
        let photos: [(String, RGB, RGB)] = [
            ("img_demo_sunset",  (0.99, 0.62, 0.38), (0.55, 0.21, 0.52)),
            ("img_demo_trail",   (0.36, 0.62, 0.36), (0.13, 0.30, 0.42)),
            ("img_demo_studio",  (0.92, 0.78, 0.55), (0.62, 0.40, 0.34)),
            ("img_demo_studio2", (0.74, 0.82, 0.72), (0.30, 0.45, 0.50)),
            ("img_demo_coast",   (0.40, 0.74, 0.86), (0.12, 0.28, 0.55)),
        ]
        for (ref, a, b) in photos {
            guard !MediaStore.shared.has(ref),
                  let img = photo(top: a, bottom: b),
                  let data = img.jpegData(compressionQuality: 0.9) else { continue }
            MediaStore.shared.store(ref, data)
        }
    }

    /// A portrait gradient "photo" with a soft light bloom.
    static func photo(top: RGB, bottom: RGB, w: Int = 1200, h: Int = 1500) -> PlatformImage? {
        render(w: w, h: h) { ctx in
            drawLinear(ctx, top: top, bottom: bottom, w: w, h: h)
            bloom(ctx, at: CGPoint(x: Double(w) * 0.72, y: Double(h) * 0.30), radius: Double(w) * 0.6)
        }
    }

    /// A square avatar gradient.
    static func avatar(top: RGB, bottom: RGB, size: Int = 400) -> PlatformImage? {
        render(w: size, h: size) { ctx in
            drawLinear(ctx, top: top, bottom: bottom, w: size, h: size)
            bloom(ctx, at: CGPoint(x: Double(size) * 0.3, y: Double(size) * 0.78), radius: Double(size) * 0.7)
        }
    }

    // MARK: drawing primitives

    private static func render(w: Int, h: Int, _ draw: (CGContext) -> Void) -> PlatformImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return PlatformImage(cgImage: cg)
    }

    private static func drawLinear(_ ctx: CGContext, top: RGB, bottom: RGB, w: Int, h: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(colorSpace: cs, components: [top.0, top.1, top.2, 1])!,
                      CGColor(colorSpace: cs, components: [bottom.0, bottom.1, bottom.2, 1])!] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    private static func bloom(_ ctx: CGContext, at center: CGPoint, radius: Double) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(colorSpace: cs, components: [1, 1, 1, 0.45])!,
                      CGColor(colorSpace: cs, components: [1, 1, 1, 0])!] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: CGFloat(radius), options: [])
    }
}
