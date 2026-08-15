export function parseLoudnessValue(value: unknown): number | null {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value === 'string') {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) {
            return parsed;
        }
    }
    return null;
}

/**
 * YouTube プレイヤーが自前の正規化で狙うラウドネス（LUFS）。
 * これより大きいコンテンツは減衰され、小さいコンテンツはそのまま流れる
 * （減衰は片方向で、ブーストはされない）。
 */
const YOUTUBE_PLAYER_TARGET_LOUDNESS = -14.0;

/**
 * 公式再生（embed）用のラウドネス正規化ゲイン（再生開始時の推定値）。
 *
 * effectiveLoudness は YouTube player response の audioConfig から Go 側が
 * 解決したコンテンツの実効ラウドネス（LUFS、perceptualLoudnessDb ≒
 * -14 + loudnessDb）。ただし埋め込みプレイヤーはこの値を基準に自前の正規化
 * 減衰を掛けてから音を出すため（実測: cont -14.6 / tgt -19.0 の動画で
 * video.volume が 0.60 = -4.4 dB）、コンテンツラウドネスをそのまま基準に
 * すると二重に減衰してローカル曲より小さく鳴る。
 *
 * そこでタップへ届くラウドネスを min(コンテンツ, YouTube のターゲット) と
 * 推定してゲインを決める。YouTube 側のターゲットは常に -14 とは限らない
 * （DRC 適用時に -19 を観測）ため、これはあくまで開始直後の暫定値であり、
 * 実際の音量差は再生開始後に Go 側の実測ラウドネス補正が引き取る。
 *
 * 値が取れない動画は正規化なし（1.0）で通常再生にフォールバックする。
 * 上限 64 倍は Go 側 SetNormalisationGain の maxNormGain と一致させている。
 */
export function resolveEmbedPlaybackGain({
    effectiveLoudness,
    targetLoudness
}: {
    effectiveLoudness: number | null;
    targetLoudness: number;
}): number {
    if (typeof effectiveLoudness !== 'number' || !Number.isFinite(effectiveLoudness)) {
        return 1.0;
    }
    const safeTargetLoudness =
        typeof targetLoudness === 'number' && Number.isFinite(targetLoudness)
            ? targetLoudness
            : -18.0;
    const loudnessAfterPlayer = Math.min(effectiveLoudness, YOUTUBE_PLAYER_TARGET_LOUDNESS);
    const gainDb = safeTargetLoudness - loudnessAfterPlayer;
    const maxNormGain = 64.0;
    return Math.min(maxNormGain, Math.pow(10, gainDb / 20));
}

export function resolveLocalPlaybackGain({
    savedLoudnessRaw,
    targetLoudness,
    forcePlay
}: {
    savedLoudnessRaw: unknown;
    targetLoudness: number;
    forcePlay: boolean;
}): { gainLinear: number; shouldWaitForAnalysis: boolean } {
    const savedLoudness = parseLoudnessValue(savedLoudnessRaw);
    if (savedLoudness === null) {
        return {
            gainLinear: 1.0,
            shouldWaitForAnalysis: !forcePlay
        };
    }

    const safeTargetLoudness =
        typeof targetLoudness === 'number' && Number.isFinite(targetLoudness)
            ? targetLoudness
            : -18.0;
    const gainDb = safeTargetLoudness - savedLoudness;

    return {
        gainLinear: Math.pow(10, gainDb / 20),
        shouldWaitForAnalysis: false
    };
}
