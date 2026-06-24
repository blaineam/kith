//! Haven desktop — Tauri 2 GUI client plus a headless circle-relay mode, both built on the
//! shared Rust core (`haven_ffi`). The GUI is the WebView2 frontend in `../ui`; `--headless`
//! runs only the in-process relay/mailbox (the "invisible relay", like the Mac app).

mod callwire;
mod commands;
mod engine;
mod localmedia;
mod relayhealth;
mod scheduled;
mod secret;
mod store;
mod wire;

use std::sync::Arc;

use anyhow::{anyhow, Result};
use haven_ffi::Account;
use sha2::{Digest, Sha256};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

use crate::engine::Engine;
use crate::store::Paths;

/// Load the master seed from the secure store, or mint + persist a new identity.
fn ensure_seed() -> Result<[u8; 32]> {
    if let Some(s) = store::load_seed()? {
        return Ok(s);
    }
    let acct: Arc<Account> = Account::generate();
    let seed: [u8; 32] = acct
        .secret_seed()
        .try_into()
        .map_err(|_| anyhow!("generated seed is not 32 bytes"))?;
    store::save_seed(&seed)?;
    Ok(seed)
}

/// Resolve the active identity's seed + data dir, migrating a legacy single-identity install
/// into the roster on first run (the legacy identity keeps the existing flat data dir).
fn ensure_active_identity() -> Result<([u8; 32], Paths)> {
    let base = Paths::resolve()?;
    let mut ids = store::Identities::load(&base);

    if ids.is_empty() {
        // First run (or pre-roster install): adopt the legacy seed, or mint a fresh identity.
        let seed = match store::load_seed()? {
            Some(s) => s,
            None => {
                let acct: Arc<Account> = Account::generate();
                let s: [u8; 32] = acct
                    .secret_seed()
                    .try_into()
                    .map_err(|_| anyhow!("generated seed is not 32 bytes"))?;
                store::save_seed(&s)?;
                s
            }
        };
        let hex = Account::from_seed(seed.to_vec())
            .map_err(|e| anyhow!("derive node id: {e}"))?
            .node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        ids.add(&hex, "Identity 1"); // first identity → legacy root, active
        ids.save(&base)?;
        return Ok((seed, Paths::resolve_for("")?));
    }

    let entry = ids
        .active_entry()
        .cloned()
        .ok_or_else(|| anyhow!("roster has no active identity"))?;
    let seed = match store::load_identity_seed(&entry.node_hex)? {
        Some(s) => s,
        None => store::load_seed()?.ok_or_else(|| anyhow!("active identity seed missing"))?,
    };
    // Keep the legacy `master-seed` mirrored to the active identity so the headless relay follows.
    let _ = store::save_seed(&seed);
    Ok((seed, Paths::resolve_for(&entry.dir)?))
}

/// Run the full GUI app.
pub fn run() {
    let (seed, paths) = ensure_active_identity().expect("load or create identity");
    let engine = Engine::new(paths, seed).expect("build engine");

    let setup_engine = engine.clone();
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(engine)
        .setup(move |app| {
            let handle = app.handle().clone();
            setup_engine.set_app(handle.clone());
            let e = setup_engine.clone();
            tauri::async_runtime::spawn(async move {
                e.start().await;
                // If the user opted in, host the relay automatically — combined with
                // launch-on-login this makes the desktop app a reboot-surviving relay.
                if e.host_on_launch() {
                    let _ = e.start_hosting().await;
                }
            });

            // System tray: show the window, toggle the relay, or quit. The relay keeps running
            // when the window is closed, so the tray is the "invisible background relay" surface.
            let show = MenuItem::with_id(app, "show", "Open Haven", true, None::<&str>)?;
            let relay = MenuItem::with_id(app, "relay", "Host relay", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Haven", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &relay, &quit])?;
            let tray_engine = setup_engine.clone();
            TrayIconBuilder::with_id("haven-tray")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("Haven")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "relay" => {
                        let e = tray_engine.clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = e.start_hosting().await;
                        });
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::bootstrap,
            commands::self_test,
            commands::get_profile,
            commands::set_profile,
            commands::circles,
            commands::create_circle,
            commands::rename_circle,
            commands::leave_circle,
            commands::add_to_circle,
            commands::feed,
            commands::post,
            commands::post_story,
            commands::comment,
            commands::react,
            commands::unreact,
            commands::edit_post,
            commands::unsend_post,
            commands::dm_threads,
            commands::start_dm,
            commands::messages,
            commands::send_dm,
            commands::connect_by_link,
            commands::pending,
            commands::approve,
            commands::dismiss,
            commands::contacts,
            commands::blocked,
            commands::block,
            commands::unblock,
            commands::relay_status,
            commands::start_hosting,
            commands::stop_hosting,
            commands::adopt_relay,
            commands::relays,
            commands::forget_relay,
            commands::autostart_status,
            commands::set_autostart,
            commands::add_media,
            commands::add_audio,
            commands::media_data_url,
            commands::schedule_message,
            commands::scheduled,
            commands::cancel_scheduled,
            commands::call_group_invite,
            commands::call_accept,
            commands::call_hangup,
            commands::call_signal,
            commands::my_node_hex,
            commands::identities,
            commands::add_identity,
            commands::import_identity,
            commands::rename_identity,
            commands::remove_identity,
            commands::switch_identity,
            commands::s3_status,
            commands::s3_configure,
            commands::s3_clear,
            commands::set_foreground,
            commands::reset,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Haven");
}

/// Run with no window. Serves the circle relay/mailbox (E2E-sealed blobs it can never read) AND
/// runs the active identity's engine so **scheduled messages dispatch and the mailbox syncs even
/// with the GUI closed** — leave this running on an always-on machine and "send later" works
/// without the app open. The messaging keys stay on this machine (the relay still never sees
/// plaintext); the relay node id is derived from a distinct relay-specific seed.
pub fn run_headless() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async {
        let (seed, paths) = ensure_active_identity().expect("load or create identity");

        // Stable relay-specific seed, distinct from the messaging identity (per the core's contract).
        let mut hasher = Sha256::new();
        hasher.update(seed);
        hasher.update(b"haven-relay");
        let relay_seed: [u8; 32] = hasher.finalize().into();

        let dir = paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();
        let handle = haven_ffi::RelayServerHandle::start(relay_seed.to_vec(), dir.to_string_lossy().to_string())
            .await
            .expect("start relay");
        let node_hex = handle.node_id_hex();

        // Build + start the engine for the active identity: this brings up the messaging node,
        // the 15s mailbox poll, and the scheduled-message dispatcher (which also flushes anything
        // overdue on launch). No AppHandle → notifications/UI events are simply no-ops.
        let engine = Engine::new(paths.clone(), seed).expect("build engine");
        engine.start().await;

        let prefs = store::Prefs::load(&paths);
        let members: Vec<String> = prefs.contacts.iter().map(|c| c.id_hex.clone()).collect();
        let link = haven_ffi::make_relay_link(node_hex.clone(), members);
        let pending = engine.list_scheduled().len();

        println!("Haven relay + scheduler running.");
        println!("  relay node id : {node_hex}");
        println!("  relay link    : {link}");
        println!("  storage       : {}", dir.display());
        println!("  scheduled     : {pending} message(s) queued — they'll send while this runs");
        println!("Share the relay link with your circle, then leave this running. Ctrl-C to stop.");

        let _ = tokio::signal::ctrl_c().await;
        println!("\nStopping.");
        drop(handle);
    });
}
