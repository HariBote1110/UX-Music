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
