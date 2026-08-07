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

/** AGCエンベロープの下限（無音・静かなパッセージでノイズを増幅しないための床）。 */
const ENV_FLOOR = 0.25;

/** エンベロープ減衰の半減期(ms)。 */
const ENV_DECAY_HALF_LIFE_MS = 4000;

/** エンベロープ立ち上がりの半減期(ms)。瞬時追従を避け、突発的な音の一発でエンベロープが張り付くのを防ぐ。 */
const ENV_RISE_HALF_LIFE_MS = 250;

/** 正規化後の相対ダイナミクスに対するコントラストカーブ。 */
const AGC_CONTRAST_EXPONENT = 1.6;

/** エンベロープに対するヘッドルーム。持続音がバーの上限に張り付かないよう、正規化の分母を底上げする。 */
const HEADROOM = 1.2;

const BAR_COUNT = BAND_EDGES_HZ.length - 1;

/** バー描画に用いる永続状態。前フレームの高さと帯域別AGCエンベロープを保持する。 */
export interface VisualizerState {
    /** 前フレームの高さ(px)。長さ6。 */
    lastHeights: number[];
    /** 帯域別AGCエンベロープ（直近ピークの追跡値）。長さ6。 */
    envelope: number[];
}

/**
 * computeBarHeights 用の初期状態を生成する。
 * lastHeights は無音時の高さ(4px)、envelope はAGCの下限値で初期化する。
 */
export function createVisualizerState(): VisualizerState {
    return {
        lastHeights: new Array(BAR_COUNT).fill(MIN_HEIGHT_PX),
        envelope: new Array(BAR_COUNT).fill(ENV_FLOOR)
    };
}

/**
 * sourceData（周波数バイト配列）から6バー分の高さ(px)を計算する。
 * state は前フレームの高さと帯域別AGCエンベロープを保持するオブジェクトで、
 * この関数がその場で破壊的に更新する。
 *
 * 各帯域は自身の直近ピーク（エンベロープ）に対して正規化される（AGC）。
 * これにより、音楽全体の音量に関わらずバーは常に相対的なダイナミクスを表現し、
 * 常に上限付近に張り付くことを防ぐ。
 *
 * @param sourceData FFT周波数バイト配列（dBスケール済み、0-255）
 * @param sampleRate サンプルレート(Hz)
 * @param fftSize FFTサイズ（sourceData.length のおよそ2倍）
 * @param state 前フレームの高さとAGCエンベロープ。破壊的に更新される
 * @param dtMs 前フレームからの経過時間(ms)。rAFのタイムスタンプ差分
 * @returns 今フレームのバー高さ(px)。長さ6
 */
export function computeBarHeights(
    sourceData: Uint8Array,
    sampleRate: number,
    fftSize: number,
    state: VisualizerState,
    dtMs: number
): number[] {
    const { lastHeights, envelope } = state;
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

        let out;
        if (compensated <= 0) {
            // ノイズゲート済み: エンベロープは更新せず、出力は0のまま。
            out = 0;
        } else {
            if (compensated > envelope[i]) {
                // 瞬時に追従せず、短い半減期で滑らかに立ち上がらせる。
                // これにより単発の突発音（トランジェント）はエンベロープを追い越して
                // 一瞬だけ上限まで振れるが、持続音はエンベロープに追いつかれて頭打ちになる。
                envelope[i] += (compensated - envelope[i]) * (1 - Math.pow(0.5, dtMs / ENV_RISE_HALF_LIFE_MS));
            } else {
                envelope[i] = Math.max(ENV_FLOOR, envelope[i] * Math.pow(0.5, dtMs / ENV_DECAY_HALF_LIFE_MS));
            }
            const normalized = Math.min(1, compensated / (envelope[i] * HEADROOM));
            out = Math.pow(normalized, AGC_CONTRAST_EXPONENT);
        }

        const target = out * HEIGHT_SCALE_PX + MIN_HEIGHT_PX;

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
