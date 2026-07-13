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
 * 公式再生（embed）用のラウドネス正規化ゲイン。
 *
 * effectiveLoudness は YouTube player response の audioConfig から Go 側が
 * 解決したコンテンツの実効ラウドネス（LUFS、perceptualLoudnessDb ≒
 * -14 + loudnessDb）。ローカル曲の resolveLocalPlaybackGain と同じ思想で
 * gainDb = targetLoudness − effectiveLoudness を線形ゲインに変換する。
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
    const gainDb = safeTargetLoudness - effectiveLoudness;
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
