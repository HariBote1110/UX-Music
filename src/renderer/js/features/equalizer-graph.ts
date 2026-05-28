export interface EqualizerGraphLike {
    context: { currentTime: number };
    nodes: {
        preamp: { gain: { setValueAtTime(value: number, time: number): void } };
        eqBands: Array<{ gain: { setValueAtTime(value: number, time: number): void } }>;
    };
}

export interface EqualizerGraphSettings {
    preamp: number;
    bands: number[];
}

export function applyEqualizerToGraph(graph: EqualizerGraphLike | null | undefined, settings: EqualizerGraphSettings): void {
    if (!graph) return;
    const context = graph.context;
    const preampValue = Math.pow(10, settings.preamp / 20);
    graph.nodes.preamp.gain.setValueAtTime(preampValue, context.currentTime);

    for (let i = 0; i < graph.nodes.eqBands.length; i++) {
        graph.nodes.eqBands[i].gain.setValueAtTime(settings.bands[i] ?? 0, context.currentTime);
    }
}
