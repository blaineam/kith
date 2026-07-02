//! On-device media store, byte-compatible with the iOS `MediaStore` and Android `LocalMedia`:
//! photos/videos/voice are content-addressed (sha-256 of the plaintext, so the ref is identical
//! on every device for the cross-device MediaReq/Chunk fetch) and kept **sealed at rest** to the
//! circle. Videos carry a `v:` ref prefix and voice notes an `a:` prefix so the feed renders the
//! right player; bare refs (or `i:`) are images.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use haven_ffi::HavenSocial;
use sha2::{Digest, Sha256};

pub struct LocalMedia {
    dir: PathBuf,
}

/// What kind of media a ref points at — drives the ref prefix and the rendered player.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
}

impl MediaKind {
    fn prefix(self) -> &'static str {
        match self {
            MediaKind::Image => "",
            MediaKind::Video => "v:",
            MediaKind::Audio => "a:",
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn bare_id(reference: &str) -> &str {
    reference
        .strip_prefix("v:")
        .or_else(|| reference.strip_prefix("a:"))
        .or_else(|| reference.strip_prefix("i:"))
        .unwrap_or(reference)
}

/// Sniff an audio container so the WebView gets a playable `data:` MIME. MediaRecorder in
/// WebKitGTK/WebView2 emits WebM/Opus or Ogg/Opus; Safari/macOS emits MP4/AAC.
pub fn audio_mime(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(b"OggS") {
        "audio/ogg"
    } else if bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        "audio/webm"
    } else if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        "audio/mp4"
    } else if bytes.starts_with(b"ID3") || bytes.starts_with(&[0xFF, 0xFB]) {
        "audio/mpeg"
    } else {
        "audio/webm"
    }
}

impl LocalMedia {
    pub fn new(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        Self { dir }
    }

    pub fn is_video(reference: &str) -> bool {
        reference.starts_with("v:")
    }

    pub fn is_audio(reference: &str) -> bool {
        reference.starts_with("a:")
    }

    /// True if `reference` is a synthetic, non-fetchable attachment (e.g. a `geo:<lat>,<lon>,<label>`
    /// location pin) rather than real media bytes. Location shares ride inside a post's `media`
    /// array, but no peer or relay can EVER serve them — blobstore safe_path (core/haven-net) rejects
    /// ':' in a key component, so such a key was never storable — so the missing-media sweep would
    /// re-enqueue a doomed S3-404 + ~30s iroh dial for them every cycle and the pending count would
    /// never settle to 0. Real media refs are `img_`/`vid_`/`aud_` or a bare content hash; the legacy
    /// single-letter media schemes `v:`/`i:`/`a:` stay fetchable, so we key off a MULTI-char URI
    /// scheme (a ':' at index > 1) rather than a bare "contains ':'".
    pub fn is_synthetic(reference: &str) -> bool {
        reference.find(':').is_some_and(|i| i > 1)
    }

    /// Store plaintext bytes sealed to `circle_id` under a typed ref.
    pub fn store_kind(&self, social: &Arc<HavenSocial>, circle_id: &str, bytes: &[u8], kind: MediaKind) -> String {
        let hash = sha256_hex(bytes);
        let to_write = social
            .seal_circle_media(circle_id.to_string(), bytes.to_vec())
            .unwrap_or_else(|_| bytes.to_vec());
        let _ = fs::write(self.dir.join(&hash), &to_write);
        format!("{}{hash}", kind.prefix())
    }

    /// Store plaintext bytes sealed to `circle_id`; returns a media ref.
    pub fn store(&self, social: &Arc<HavenSocial>, circle_id: &str, bytes: &[u8], is_video: bool) -> String {
        self.store_kind(social, circle_id, bytes, if is_video { MediaKind::Video } else { MediaKind::Image })
    }

    /// Load + decrypt a stored media ref, or `None` if we don't have it.
    pub fn load(&self, social: &Arc<HavenSocial>, circle_id: &str, reference: &str) -> Option<Vec<u8>> {
        let f = self.dir.join(bare_id(reference));
        let stored = fs::read(&f).ok()?;
        Some(
            social
                .open_circle_media(circle_id.to_string(), stored.clone())
                .unwrap_or(stored),
        )
    }

    pub fn has(&self, reference: &str) -> bool {
        self.dir.join(bare_id(reference)).exists()
    }

    /// Load decrypted bytes trying every circle's key (for serving a media request).
    pub fn load_any_circle(&self, social: &Arc<HavenSocial>, reference: &str) -> Option<Vec<u8>> {
        let f = self.dir.join(bare_id(reference));
        let stored = fs::read(&f).ok()?;
        for c in social.circles() {
            if let Some(open) = social.open_circle_media(c.id, stored.clone()) {
                return Some(open);
            }
        }
        Some(stored)
    }

    /// Store received plaintext bytes under an exact ref (sealed at rest to the circle).
    pub fn store_under_ref(&self, social: &Arc<HavenSocial>, circle_id: &str, reference: &str, bytes: &[u8]) {
        let to_write = social
            .seal_circle_media(circle_id.to_string(), bytes.to_vec())
            .unwrap_or_else(|_| bytes.to_vec());
        let _ = fs::write(self.dir.join(bare_id(reference)), &to_write);
    }

    /// The at-rest sealed blob for a ref — uploaded to the relay verbatim.
    pub fn raw_sealed(&self, reference: &str) -> Option<Vec<u8>> {
        fs::read(self.dir.join(bare_id(reference))).ok()
    }

    /// Write a sealed blob fetched from the relay straight to disk.
    pub fn write_raw_sealed(&self, reference: &str, blob: &[u8]) {
        let _ = fs::write(self.dir.join(bare_id(reference)), blob);
    }

    // ---- Chunked reassembly (large-media fix) -----------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB, so large sealed videos are transferred as 8 MB
    // chunks (see engine::upload_media / fetch_media_from_relay). On download we APPEND each chunk to a
    // temp file on disk — the full sealed blob is NEVER held in RAM at once — then adopt it.

    /// A fresh empty temp file to reassemble an incoming chunked (sealed) transfer for `reference`.
    pub fn new_sealed_part(&self, reference: &str) -> PathBuf {
        let p = self.dir.join(format!("incoming_{}.part", bare_id(reference)));
        let _ = fs::remove_file(&p);
        let _ = fs::File::create(&p);
        p
    }

    /// Append one sealed chunk's bytes to the temp reassembly file (streaming — no full blob in RAM).
    pub fn append_sealed_part(&self, part: &Path, bytes: &[u8]) -> bool {
        use std::io::Write;
        fs::OpenOptions::new()
            .append(true)
            .open(part)
            .and_then(|mut f| f.write_all(bytes))
            .is_ok()
    }

    /// Move a fully-reassembled sealed temp file into place under `reference`.
    pub fn adopt_sealed_part(&self, reference: &str, part: &Path) -> bool {
        let dst = self.dir.join(bare_id(reference));
        fs::rename(part, &dst).is_ok()
    }

    /// Delete every stored media file (part of "start over").
    pub fn clear(&self) {
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ref_kind_classification() {
        assert!(LocalMedia::is_video("v:abc"));
        assert!(!LocalMedia::is_video("a:abc"));
        assert!(!LocalMedia::is_video("abc"));
        assert!(LocalMedia::is_audio("a:abc"));
        assert!(!LocalMedia::is_audio("v:abc"));
        assert!(!LocalMedia::is_audio("abc"));
    }

    #[test]
    fn synthetic_excludes_geo_but_keeps_media() {
        // geo: location pins carry no bytes and were never relay-storable → skip in sweeps.
        assert!(LocalMedia::is_synthetic("geo:36.213,-118.687,Place Name"));
        // Real media refs stay fetchable — img_/vid_/aud_, bare hashes, and legacy v:/i:/a:.
        assert!(!LocalMedia::is_synthetic("img_deadbeef"));
        assert!(!LocalMedia::is_synthetic("vid_deadbeef"));
        assert!(!LocalMedia::is_synthetic("aud_deadbeef"));
        assert!(!LocalMedia::is_synthetic("deadbeefcafe"));
        assert!(!LocalMedia::is_synthetic("v:deadbeef"));
        assert!(!LocalMedia::is_synthetic("i:deadbeef"));
        assert!(!LocalMedia::is_synthetic("a:deadbeef"));
    }

    #[test]
    fn bare_id_strips_every_prefix() {
        assert_eq!(bare_id("v:deadbeef"), "deadbeef");
        assert_eq!(bare_id("a:deadbeef"), "deadbeef");
        assert_eq!(bare_id("i:deadbeef"), "deadbeef");
        assert_eq!(bare_id("deadbeef"), "deadbeef");
    }

    #[test]
    fn kind_prefixes() {
        assert_eq!(MediaKind::Image.prefix(), "");
        assert_eq!(MediaKind::Video.prefix(), "v:");
        assert_eq!(MediaKind::Audio.prefix(), "a:");
    }

    #[test]
    fn audio_mime_sniffing() {
        assert_eq!(audio_mime(b"OggS\x00\x02..."), "audio/ogg");
        assert_eq!(audio_mime(&[0x1A, 0x45, 0xDF, 0xA3, 0x01]), "audio/webm");
        assert_eq!(audio_mime(b"\x00\x00\x00\x20ftypM4A "), "audio/mp4");
        assert_eq!(audio_mime(b"ID3\x03..."), "audio/mpeg");
        assert_eq!(audio_mime(b"unknownbytes"), "audio/webm"); // safe default
    }
}
