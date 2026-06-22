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
    /**
     * Comment on a post (or another comment) by its event id.
     */
    comment(target: string, body: string, media: string[], created_at: bigint): Uint8Array;
    contact_count(): number;
    /**
     * Edit the body/media of one of your own posts or comments.
     */
    edit(target: string, body: string, media: string[], created_at: bigint): Uint8Array;
    /**
     * The reduced feed as JSON (posts + comments + reactions), newest-first per the engine.
     */
    feed_json(now_ms: bigint): string;
    invite_link(domain: string): string;
    /**
     * Author a direct message into the circle thread.
     */
    message(body: string, created_at: bigint): Uint8Array;
    /**
     * Create a fresh identity, or restore one from a 64-char hex seed (e.g. decoded
     * from a phone's transfer code — same identity across devices).
     */
    constructor(seed_hex?: string | null);
    node_id_hex(): string;
    /**
     * Author a text post; returns the sealed envelope bytes to broadcast to the circle.
     */
    post(body: string, created_at: bigint): Uint8Array;
    /**
     * Author a post with media refs and/or a story flag (story = ephemeral 24h slide).
     */
    post_full(body: string, media: string[], story: boolean, created_at: bigint): Uint8Array;
    /**
     * React to a post or comment with an emoji.
     */
    react(target: string, emoji: string, created_at: bigint): Uint8Array;
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
    /**
     * Unsend (retract) one of your own posts, comments, or messages.
     */
    unsend(target: string, created_at: bigint): Uint8Array;
    verification_hex(): string;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_havenengine_free: (a: number, b: number) => void;
    readonly havenengine_add_contact: (a: number, b: number, c: number) => [number, number, number, number];
    readonly havenengine_bundle_hex: (a: number) => [number, number];
    readonly havenengine_comment: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: bigint) => [number, number];
    readonly havenengine_contact_count: (a: number) => number;
    readonly havenengine_edit: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: bigint) => [number, number];
    readonly havenengine_feed_json: (a: number, b: bigint) => [number, number];
    readonly havenengine_invite_link: (a: number, b: number, c: number) => [number, number];
    readonly havenengine_message: (a: number, b: number, c: number, d: bigint) => [number, number];
    readonly havenengine_new: (a: number, b: number) => [number, number, number];
    readonly havenengine_node_id_hex: (a: number) => [number, number];
    readonly havenengine_post: (a: number, b: number, c: number, d: bigint) => [number, number];
    readonly havenengine_post_full: (a: number, b: number, c: number, d: number, e: number, f: number, g: bigint) => [number, number];
    readonly havenengine_react: (a: number, b: number, c: number, d: number, e: number, f: bigint) => [number, number];
    readonly havenengine_receive: (a: number, b: number, c: number) => number;
    readonly havenengine_seed_hex: (a: number) => [number, number];
    readonly havenengine_self_test: (a: number) => number;
    readonly havenengine_sync_envelopes_json: (a: number) => [number, number];
    readonly havenengine_unsend: (a: number, b: number, c: number, d: bigint) => [number, number];
    readonly havenengine_verification_hex: (a: number) => [number, number];
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
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
