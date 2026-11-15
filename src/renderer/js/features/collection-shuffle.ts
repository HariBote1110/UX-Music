export type CollectionKind = 'album' | 'playlist';
export type CollectionRef = { kind: CollectionKind; key: string };
export type ShufflePreference = 'on' | 'off' | null;

type CollectionShuffleApp = {
    GetCollectionShufflePreferences?: () => Promise<Record<string, unknown>>;
    SetCollectionShufflePreference?: (kind: CollectionKind, key: string, preference: '' | 'on' | 'off') => Promise<void>;
};

let preferences = new Map<string, Exclude<ShufflePreference, null>>();
const listeners = new Set<() => void>();
/** 読み込み（GetCollectionShufflePreferences）の実行中数 */
let loadsInFlight = 0;
/** 読み込み中に完了した set の結果（null は削除）。読み込み結果の上に再適用する。 */
const changedDuringLoad = new Map<string, Exclude<ShufflePreference, null> | null>();

function preferenceKey(ref: CollectionRef): string {
    return `${ref.kind}:${ref.key}`;
}

function getApp(): CollectionShuffleApp | undefined {
    return window.go?.server?.App as CollectionShuffleApp | undefined;
}

function notifyListeners(): void {
    for (const listener of listeners) {
        try {
            listener();
        } catch (error) {
            console.error('[CollectionShuffle] listener failed', error);
        }
    }
}

function isPreference(value: unknown): value is Exclude<ShufflePreference, null> {
    return value === 'on' || value === 'off';
}

// 新規キューだけがコレクション既定値を採用する。既存キュー内の移動では、
// ライブキューのシャッフル状態を変えない。
export function resolveEffectiveShuffle(
    baseline: boolean,
    preference: ShufflePreference,
    isNewQueue: boolean,
): boolean {
    if (isNewQueue && preference != null) {
        return preference === 'on';
    }
    return baseline;
}

export async function loadCollectionShufflePreferences(): Promise<void> {
    const app = getApp();
    if (!app?.GetCollectionShufflePreferences) {
        // バインディング未初期化時は既存のキャッシュを維持する（空に置き換えない）
        return;
    }
    loadsInFlight += 1;
    let raw: Record<string, unknown>;
    try {
        raw = await app.GetCollectionShufflePreferences();
    } finally {
        loadsInFlight -= 1;
    }
    const next = new Map<string, Exclude<ShufflePreference, null>>();
    for (const [key, value] of Object.entries(raw ?? {})) {
        if ((key.startsWith('album:') || key.startsWith('playlist:')) && isPreference(value)) {
            next.set(key, value);
        }
    }
    for (const [key, value] of changedDuringLoad) {
        if (value == null) {
            next.delete(key);
        } else {
            next.set(key, value);
        }
    }
    if (loadsInFlight === 0) {
        changedDuringLoad.clear();
    }
    preferences = next;
    notifyListeners();
}

export function getCollectionShufflePreference(ref: CollectionRef): ShufflePreference {
    return preferences.get(preferenceKey(ref)) ?? null;
}

export async function setCollectionShufflePreference(ref: CollectionRef, pref: ShufflePreference): Promise<void> {
    const app = getApp();
    if (!app?.SetCollectionShufflePreference) {
        throw new Error('Collection shuffle preferences are unavailable');
    }
    await app.SetCollectionShufflePreference(ref.kind, ref.key, pref ?? '');
    const key = preferenceKey(ref);
    if (loadsInFlight > 0) {
        changedDuringLoad.set(key, pref ?? null);
    }
    if (pref == null) {
        preferences.delete(key);
    } else {
        preferences.set(key, pref);
    }
    notifyListeners();
}

export function subscribeCollectionShufflePreferences(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
}
