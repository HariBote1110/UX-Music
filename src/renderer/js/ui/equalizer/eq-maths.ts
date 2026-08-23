// src/renderer/js/ui/equalizer/eq-maths.ts
// グラフィックEQのカーブエディタが必要とする純粋計算ロジック。
// DOM に一切触れないため、サイドバー版・設定画面版の両方から共有できる。

export const BAND_FREQUENCIES = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

export const MIN_FREQ = 20;
export const MAX_FREQ = 20000;
export const MIN_DB = -12;
export const MAX_DB = 12;

const LOG_MIN_FREQ = Math.log10(MIN_FREQ);
const LOG_MAX_FREQ = Math.log10(MAX_FREQ);

export const EQ_PRESETS: Record<string, number[]> = {
    Flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    Electronic: [7, 5, 2, 0, -2, 0, 2, 3, 4, 5],
    Rock: [5, 3, 1, -2, -1, 1, 3, 4, 5, 6],
    Pop: [-2, 0, 2, 4, 5, 3, 0, -1, -2, -3],
    Jazz: [4, 2, 1, -2, -2, 0, 1, 2, 3, 4],
    Classical: [5, 4, 2, -2, -3, -2, 0, 1, 2, 3],
    Vocal: [-2, -1, 0, 3, 4, 2, 1, 0, -1, -2],
};

/** 周波数（対数軸）をキャンバス上の x 座標へ変換する。 */
export function freqToX(freq: number, width: number): number {
    return ((Math.log10(freq) - LOG_MIN_FREQ) / (LOG_MAX_FREQ - LOG_MIN_FREQ)) * width;
}

/** x 座標を周波数へ逆変換する。 */
export function xToFreq(x: number, width: number): number {
    const ratio = width === 0 ? 0 : x / width;
    return Math.pow(10, LOG_MIN_FREQ + ratio * (LOG_MAX_FREQ - LOG_MIN_FREQ));
}

/** dB 値をキャンバス上の y 座標へ変換する（上端が +MAX_DB、下端が MIN_DB）。 */
export function dbToY(db: number, height: number): number {
    return (1 - (db - MIN_DB) / (MAX_DB - MIN_DB)) * height;
}

/** y 座標を dB 値へ逆変換する。 */
export function yToDb(y: number, height: number): number {
    const ratio = height === 0 ? 0 : y / height;
    return (1 - ratio) * (MAX_DB - MIN_DB) + MIN_DB;
}

/**
 * (x, y) に最も近いバンドの点を探し、ヒット半径内であればそのインデックスを返す。
 * 見つからない場合は -1。
 */
export function nearestBandIndex(
    x: number,
    y: number,
    width: number,
    height: number,
    bands: number[],
    hitRadius = 10,
): number {
    let closestIndex = -1;
    let closestDistance = Infinity;
    BAND_FREQUENCIES.forEach((freq, i) => {
        const px = freqToX(freq, width);
        const py = dbToY(bands[i] ?? 0, height);
        const distance = Math.hypot(px - x, py - y);
        if (distance < hitRadius && distance < closestDistance) {
            closestDistance = distance;
            closestIndex = i;
        }
    });
    return closestIndex;
}

/** プリセット名から 10 バンド配列のコピーを返す。未知のプリセットは null。 */
export function presetBands(name: string): number[] | null {
    const preset = EQ_PRESETS[name];
    return preset ? [...preset] : null;
}

/**
 * 旧・簡易 EQ（Bass/Mid/Treble の3ノブ）の調整量を 10 バンド配列へ折り込む。
 * `equalizer.ts` の旧 applyCurrentSettings と同じ重み付けを踏襲する（後方互換のため）。
 * 入力の bands 配列は変更しない。
 */
export function legacyBandsFromSimpleControls(
    bands: number[],
    bass: number,
    mid: number,
    treble: number,
): number[] {
    const result = [...bands];
    result[0] += bass;
    result[1] += bass;
    result[2] += bass * 0.5;
    result[3] += mid * 0.5;
    result[4] += mid;
    result[5] += mid;
    result[6] += mid * 0.5;
    result[7] += treble * 0.5;
    result[8] += treble;
    result[9] += treble;
    return result;
}
