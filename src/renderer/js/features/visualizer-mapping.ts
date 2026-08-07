// src/renderer/js/features/visualizer-mapping.ts
//
// 6バーの再生インジケーター用に、FFT周波数バイト配列(0-255, dBスケール済み)を
// 知覚特性に沿ったバー高さへ変換する純粋関数。DOMやWailsブリッジに依存しないため、
// vitest から単体でテストできる。

/** 各バーが担当する帯域の境界(Hz)。連続する対数スケールバンド。 */
const BAND_EDGES_HZ = [40, 150, 450, 1400, 4000, 9000, 16000];

/** ノイズフロア（この正規化値未満は無音扱い）。 */
const NOISE_FLOOR = 0.22;

/** dBスケール済みデータに対するゆるいダイナミクス調整カーブ。 */
const CURVE_EXPONENT = 1.1;

/** 等ラウドネス補正（低音をやや抑え、高音を持ち上げる）。 */
const BAND_GAINS = [0.9, 1.0, 1.05, 1.15, 1.25, 1.35];

const MIN_HEIGHT_PX = 4;
const MAX_HEIGHT_PX = 20;
const HEIGHT_SCALE_PX = 16;

const ATTACK_COEFFICIENT = 0.55;
const RELEASE_COEFFICIENT = 0.18;
const REFERENCE_FRAME_MS = 16.7;
const MAX_COEFFICIENT_MULTIPLIER = 2;

/**
 * sourceData（周波数バイト配列）から6バー分の高さ(px)を計算する。
 * lastHeights は前フレームの高さを保持する長さ6の配列で、この関数が
 * アタック/リリースのスムージング結果でその場を更新する。
 *
 * @param sourceData FFT周波数バイト配列（dBスケール済み、0-255）
 * @param sampleRate サンプルレート(Hz)
 * @param fftSize FFTサイズ（sourceData.length のおよそ2倍）
 * @param lastHeights 前フレームの高さ(px)。長さ6。破壊的に更新される
 * @param dtMs 前フレームからの経過時間(ms)。rAFのタイムスタンプ差分
 * @returns 今フレームのバー高さ(px)。長さ6
 */
export function computeBarHeights(
    sourceData: Uint8Array,
    sampleRate: number,
    fftSize: number,
    lastHeights: number[],
    dtMs: number
): number[] {
    const binWidth = sampleRate / fftSize;
    const barCount = BAND_EDGES_HZ.length - 1;
    const frameMultiplier = Math.min(MAX_COEFFICIENT_MULTIPLIER, dtMs > 0 ? dtMs / REFERENCE_FRAME_MS : 1);
    const attackCoefficient = ATTACK_COEFFICIENT * frameMultiplier;
    const releaseCoefficient = RELEASE_COEFFICIENT * frameMultiplier;

    const heights = new Array(barCount);

    for (let i = 0; i < barCount; i++) {
        const startHz = BAND_EDGES_HZ[i];
        const endHz = BAND_EDGES_HZ[i + 1];

        let startBin = Math.floor(startHz / binWidth);
        let endBin = Math.ceil(endHz / binWidth) - 1;

        startBin = Math.max(0, Math.min(startBin, sourceData.length - 1));
        endBin = Math.max(startBin, Math.min(endBin, sourceData.length - 1));

        let sum = 0;
        let count = 0;
        for (let b = startBin; b <= endBin; b++) {
            sum += sourceData[b];
            count++;
        }
        const avg = count > 0 ? sum / count : 0;

        const v = avg / 255;
        const u = Math.max(0, (v - NOISE_FLOOR) / (1 - NOISE_FLOOR));
        const curved = Math.pow(u, CURVE_EXPONENT);
        const compensated = Math.min(1, curved * BAND_GAINS[i]);

        const target = compensated * HEIGHT_SCALE_PX + MIN_HEIGHT_PX;

        const previous = lastHeights[i] ?? MIN_HEIGHT_PX;
        let next;
        if (target > previous) {
            next = previous + (target - previous) * attackCoefficient;
        } else {
            next = previous + (target - previous) * releaseCoefficient;
        }
        next = Math.min(MAX_HEIGHT_PX, Math.max(MIN_HEIGHT_PX, next));

        lastHeights[i] = next;
        heights[i] = next;
    }

    return heights;
}
