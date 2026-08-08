import { beforeEach, describe, expect, it, vi } from 'vitest';

type ListenerMap = Record<string, (event: any) => void>;

function elementStub(value = '') {
    const listeners: ListenerMap = {};
    return {
        value,
        dataset: {} as Record<string, string>,
        innerHTML: '',
        textContent: '',
        style: {} as Record<string, string>,
        classList: {
            add: vi.fn(),
            remove: vi.fn(),
        },
        addEventListener: vi.fn((type: string, listener: (event: any) => void) => {
            listeners[type] = listener;
        }),
        listeners,
    };
}

function installWindowStub(appOverrides: Record<string, unknown> = {}) {
    globalThis.window = {
        electronAPI: {
            CHANNELS: { SEND: {}, INVOKE: {}, ON: {} },
            send: vi.fn(),
            invoke: vi.fn(),
            on: vi.fn(),
            removeAllListeners: vi.fn(),
        },
        go: {
            server: {
                App: appOverrides,
            },
        },
    } as any;
}

describe('AI 音声解析設定', () => {
    beforeEach(() => {
        vi.resetModules();
        installWindowStub();
    });

    it('Windows パスでも検索結果の曲名だけを表示名にする', async () => {
        const module = await import('./ai-embed-settings.js');

        expect(module.moodSearchDisplayName('C:\\Users\\yuki\\Music\\song.flac')).toBe('song.flac');
        expect(module.moodSearchDisplayName('/Users/yuki/Music/song.flac')).toBe('song.flac');
    });

    it('検索入力で Enter を押すとムード検索を実行する', async () => {
        const search = vi.fn(async () => []);
        const elements: Record<string, ReturnType<typeof elementStub>> = {
            'ai-audio-embed-search-input': elementStub('夜に沈む曲'),
            'ai-audio-embed-search-btn': elementStub(),
            'ai-audio-embed-search-results': elementStub(),
            'ai-audio-embed-status': elementStub(),
            'ai-special-actions': elementStub(),
            'ai-special-result': elementStub(),
        };
        installWindowStub({
            GetAudioEmbedStatus: vi.fn(async () => ({ stored: 0, version: 'test' })),
            SearchTracksByMood: search,
        });
        globalThis.document = {
            getElementById: vi.fn((id: string) => elements[id] ?? null),
        } as any;

        const { initAiEmbedSettings } = await import('./ai-embed-settings.js');
        initAiEmbedSettings();

        const event = { key: 'Enter', preventDefault: vi.fn() };
        await elements['ai-audio-embed-search-input'].listeners.keydown(event);
        await new Promise(resolve => setTimeout(resolve, 0));

        expect(event.preventDefault).toHaveBeenCalled();
        expect(search).toHaveBeenCalledWith('夜に沈む曲', 20);
    });
});
