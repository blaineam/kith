package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.parseLink
import uniffi.haven_ffi.selfTest

/**
 * On-device tests that exercise the real Rust core through the Kotlin bindings — this is the
 * "unit-green ≠ device-working" guard: these only pass if libhaven_ffi.so actually loads and
 * runs on the hardware/emulator. They also prove two Android identities can seal/open to each
 * other (the cross-device handshake math).
 */
@RunWith(AndroidJUnit4::class)
class CoreInstrumentedTest {

    @Test fun self_test_passes_on_device() {
        val r = selfTest()
        assertTrue("identity", r.identityOk)
        assertTrue("hybrid KEM seal/open", r.hybridKemOk)
        assertTrue("signatures", r.signatureOk)
        assertTrue("links", r.linkOk)
        assertTrue("all", r.allOk)
    }

    @Test fun account_from_seed_is_deterministic() {
        val a = Account.generate()
        val seed = a.secretSeed()
        val b = Account.fromSeed(seed)
        assertEquals(a.nodeIdHex(), b.nodeIdHex())
        assertEquals(a.verificationHex(), b.verificationHex())
    }

    @Test fun invite_link_parses_back_to_our_id() {
        val a = Account.generate()
        val info = parseLink(a.havenUri())
        assertEquals(a.nodeIdHex(), info.idHex)
        assertEquals(a.verificationHex(), info.verificationHex)
    }

    @Test fun two_identities_form_a_circle_and_exchange_a_post() {
        // Alice and Bob each have their own engine.
        val alice = Account.generate()
        val bob = Account.generate()
        val aliceSocial = HavenSocial(alice.secretSeed())
        val bobSocial = HavenSocial(bob.secretSeed())

        // They exchange bundles (the Hello handshake) into the default circle.
        aliceSocial.addContactBundle("default", bobSocial.myBundle())
        bobSocial.addContactBundle("default", aliceSocial.myBundle())

        // Alice posts; the sealed envelopes are what the wire carries.
        aliceSocial.post("default", "hello bob", emptyList(), null, null, false, false, 1_000UL)
        val envs = aliceSocial.syncEnvelopes("default")
        assertTrue("alice produced envelopes", envs.isNotEmpty())

        // Bob ingests them and sees Alice's post in his feed.
        var ingested = false
        for (env in envs) if (bobSocial.receive("default", env)) ingested = true
        assertTrue("bob ingested at least one", ingested)

        val bobFeed = bobSocial.feed("default", 2_000UL, null)
        assertNotNull(bobFeed)
        assertTrue("bob sees alice's post", bobFeed.any { it.body == "hello bob" && !it.isMe })
    }

    @Test fun dm_circle_id_is_deterministic_and_symmetric() {
        // Both ends must derive the identical dm: circle id (full sorted node ids).
        val a = Account.generate().nodeIdHex()
        val b = Account.generate().nodeIdHex()
        val pair = listOf(a, b).sorted()
        val expected = "dm:${pair[0]}-${pair[1]}"
        // id(a,b) computed from a's view == id(b,a) from b's view.
        fun dmId(me: String, them: String) = "dm:" + listOf(me, them).sorted().joinToString("-")
        assertEquals(expected, dmId(a, b))
        assertEquals(dmId(a, b), dmId(b, a))
    }

    @Test fun two_identities_exchange_a_dm() {
        val alice = Account.generate(); val bob = Account.generate()
        val aliceSocial = HavenSocial(alice.secretSeed())
        val bobSocial = HavenSocial(bob.secretSeed())
        val pair = listOf(alice.nodeIdHex(), bob.nodeIdHex()).sorted()
        val dmId = "dm:${pair[0]}-${pair[1]}"

        // Both create the DM circle and add each other (the startDm + Hello handshake).
        aliceSocial.createCircle(dmId, "Bob")
        bobSocial.createCircle(dmId, "Alice")
        aliceSocial.addContactBundle(dmId, bobSocial.myBundle())
        bobSocial.addContactBundle(dmId, aliceSocial.myBundle())

        aliceSocial.post(dmId, "hey bob, dm", emptyList(), null, null, false, false, 1UL)
        var got = false
        for (env in aliceSocial.syncEnvelopes(dmId)) if (bobSocial.receive(dmId, env)) got = true
        assertTrue(got)
        assertTrue(bobSocial.feed(dmId, 2UL, null).any { it.body == "hey bob, dm" && !it.isMe })
    }

    @Test fun call_signal_sdp_and_ice_json_round_trip() {
        // SDP/ICE JSON must match the iOS CallSignal shape ({t,sdp} / {c,m,i}) for call interop.
        val sdpJson = com.blaineam.haven.core.CallSignal.encodeSdp("offer", "v=0\r\no=- 1 2 IN IP4 0.0.0.0")
        val sdp = com.blaineam.haven.core.CallSignal.decodeSdp(sdpJson)!!
        assertEquals("offer", sdp.type)
        assertTrue(sdp.sdp.startsWith("v=0"))
        // The JSON keys are exactly t/sdp.
        val obj = org.json.JSONObject(String(sdpJson))
        assertTrue(obj.has("t") && obj.has("sdp"))

        val iceJson = com.blaineam.haven.core.CallSignal.encodeCandidate("candidate:1 1 udp", 0, "0")
        val ice = com.blaineam.haven.core.CallSignal.decodeCandidate(iceJson)!!
        assertEquals("candidate:1 1 udp", ice.candidate)
        assertEquals(0, ice.mLineIndex)
        assertEquals("0", ice.mid)
        val iceObj = org.json.JSONObject(String(iceJson))
        assertTrue(iceObj.has("c") && iceObj.has("m"))
    }

    @Test fun story_flag_round_trips_through_the_feed() {
        val a = Account.generate()
        val s = HavenSocial(a.secretSeed())
        // A normal post and a story.
        s.post("default", "normal", emptyList(), null, null, false, false, 1UL)
        s.post("default", "my story", emptyList(), null, 86_400UL, true, false, 2UL)
        val feed = s.feed("default", 3UL, null)
        assertTrue("story flagged", feed.any { it.body == "my story" && it.story })
        assertTrue("normal not a story", feed.any { it.body == "normal" && !it.story })
    }

    @Test fun export_import_preserves_posts_reactions_and_comments() {
        // The persistence contract HavenNet relies on: exportState() -> importState() into a
        // fresh engine restores the full feed. Guards against posts vanishing on app restart.
        val a = Account.generate()
        val s1 = HavenSocial(a.secretSeed())
        val postEnv = s1.post("default", "remembered post", emptyList(), null, null, false, false, 1UL)
        // self-comment + self-react so the whole event log is exercised.
        val pid = s1.feed("default", 2UL, null).first().id
        s1.comment("default", pid, "my comment", emptyList(), 2UL)
        s1.react("default", pid, "🔥", 3UL)

        val blob = s1.exportState()
        val s2 = HavenSocial(a.secretSeed())
        s2.importState(blob)

        val restored = s2.feed("default", 4UL, null).firstOrNull { it.body == "remembered post" }
        assertNotNull("post survived restart", restored)
        assertTrue("comment survived", restored!!.comments.any { it.body == "my comment" })
        assertTrue("reaction survived", restored.reactions.any { it.emoji == "🔥" })
        assertTrue(postEnv.isNotEmpty())
    }

    @Test fun local_media_seals_stores_and_loads_back() {
        val ctx = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        com.blaineam.haven.core.HavenNet.init(ctx)
        com.blaineam.haven.core.LocalMedia.init(ctx)
        val original = ByteArray(4096) { (it * 31).toByte() }
        val id = com.blaineam.haven.core.LocalMedia.store("default", original)
        assertTrue("media stored", com.blaineam.haven.core.LocalMedia.has(id))
        val back = com.blaineam.haven.core.LocalMedia.load("default", id)
        assertNotNull("media loaded back", back)
        assertArrayEquals("media round-trips byte-identical", original, back)
    }

    @Test fun seal_open_media_roundtrips_between_two_identities() {
        val alice = Account.generate()
        val bob = Account.generate()
        val aliceSocial = HavenSocial(alice.secretSeed())
        val bobSocial = HavenSocial(bob.secretSeed())
        // Both directions of the handshake: Alice must hold Bob's bundle to seal *to* him.
        aliceSocial.addContactBundle("default", bobSocial.myBundle())
        bobSocial.addContactBundle("default", aliceSocial.myBundle())

        val data = "secret bytes".toByteArray()
        val sealed = aliceSocial.sealMedia(bobSocial.myNodeHex(), data)
        val opened = bobSocial.openMedia(sealed)
        assertNotNull("bob opened the sealed media", opened)
        assertEquals("secret bytes", opened!!.toString(Charsets.UTF_8))

        // A third party cannot open it.
        val eve = HavenSocial(Account.generate().secretSeed())
        assertNull(eve.openMedia(sealed))
    }
}
