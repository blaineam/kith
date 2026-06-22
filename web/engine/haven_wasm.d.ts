/* tslint:disable */
/* eslint-disable */

/**
 * A real Haven engine instance for one identity (default circle = your contacts).
 */
export class HavenEngine {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Add a contact from their public bundle (hex); returns their node id (hex).
     */
    add_contact(bundle_hex: string): string;
    /**
     * The full public bundle (hex) to hand a contact so they can seal to us.
     */
    bundle_hex(): string;
    contact_count(): number;
    /**
     * The reduced feed as JSON (posts + comments + reactions), newest-first per the engine.
     */
    feed_json(now_ms: bigint): string;
    invite_link(domain: string): string;
    /**
     * Create a fresh identity, or restore one from a 64-char hex seed (e.g. decoded
     * from a phone's transfer code — same identity across devices).
     */
    constructor(seed_hex?: string | null);
    node_id_hex(): string;
    /**
     * Author a post; returns the sealed envelope bytes to broadcast to the circle.
     */
    post(body: string, created_at: bigint): Uint8Array;
    /**
     * Ingest a sealed envelope received from a peer. Returns true if it was new.
     */
    receive(envelope: Uint8Array): boolean;
    /**
     * The 32-byte master seed as hex — persist this (IndexedDB/localStorage) to stay
     * the same identity across reloads.
     */
    seed_hex(): string;
    /**
     * A real seal→open round trip with this identity — the browser-side privacy check.
     */
    self_test(): boolean;
    /**
     * Our own events, each sealed to the circle, as a JSON array of hex strings — to
     * back-fill a peer that just connected.
     */
    sync_envelopes_json(): string;
    verification_hex(): string;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_kithengine_free: (a: number, b: number) => void;
    readonly kithengine_add_contact: (a: number, b: number, c: number) => [number, number, number, number];
    readonly kithengine_bundle_hex: (a: number) => [number, number];
    readonly kithengine_contact_count: (a: number) => number;
    readonly kithengine_feed_json: (a: number, b: bigint) => [number, number];
    readonly kithengine_invite_link: (a: number, b: number, c: number) => [number, number];
    readonly kithengine_new: (a: number, b: number) => [number, number, number];
    readonly kithengine_node_id_hex: (a: number) => [number, number];
    readonly kithengine_post: (a: number, b: number, c: number, d: bigint) => [number, number];
    readonly kithengine_receive: (a: number, b: number, c: number) => number;
    readonly kithengine_seed_hex: (a: number) => [number, number];
    readonly kithengine_self_test: (a: number) => number;
    readonly kithengine_sync_envelopes_json: (a: number) => [number, number];
    readonly kithengine_verification_hex: (a: number) => [number, number];
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
