import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * jsdom の本物の DOM 上でクイズ画面を組み立てて検証する。
 * 差し替えるのは以下だけ:
 *  - HTMLMediaElement.play/pause（jsdom が未実装のため）
 *  - core/state.js（ライブラリ内容をテストから決めたいため）
 *  - window.electronAPI（Electron ブリッジ）
 * 要素そのものは quiz.ts が生成した実マークアップをそのまま使う。
 */
describe('stopQuiz cleanup', () => {
    let audioPause: ReturnType<typeof vi.spyOn>;
    let audioPlay: ReturnType<typeof vi.spyOn>;
    let quizAudio: HTMLAudioElement | null;
    let volumeSlider: HTMLInputElement;

    beforeEach(() => {
        vi.resetModules();
        vi.useFakeTimers();

        document.body.innerHTML = `
            <div id="quiz-container"></div>
            <audio id="main-player"></audio>
        `;

        audioPlay = vi.spyOn(window.HTMLMediaElement.prototype, 'play').mockResolvedValue(undefined);
        audioPause = vi.spyOn(window.HTMLMediaElement.prototype, 'pause').mockImplementation(() => {});

        // quiz.ts はモジュール読み込み時に `new Audio()` するので、
        // 生成された実インスタンスを掴んでおく（生成物自体は本物の <audio>）。
        quizAudio = null;
        const RealAudio = window.Audio;
        globalThis.Audio = vi.fn(() => {
            const el = new RealAudio();
            quizAudio = el;
            return el;
        }) as unknown as typeof Audio;

        volumeSlider = document.createElement('input');
        volumeSlider.type = 'range';
        volumeSlider.value = '1';

        (window as unknown as { electronAPI: unknown }).electronAPI = {
            invoke: vi.fn(async () => []),
        };

        const fakeSongs = Array.from({ length: 6 }, (_, i) => ({
            id: `song-${i}`,
            type: 'local',
            duration: 200,
            artist: `Artist ${i}`,
            title: `Song ${i}`,
            path: `/music/song-${i}.mp3`,
            albumKey: 'album-1',
        }));

        vi.doMock('../core/state.js', () => ({
            state: {
                library: fakeSongs,
                playCounts: {},
                albums: new Map(),
            },
            elements: { volumeSlider },
        }));
    });

    afterEach(() => {
        vi.useRealTimers();
        vi.restoreAllMocks();
        document.body.innerHTML = '';
    });

    function container(): HTMLElement {
        return document.getElementById('quiz-container') as HTMLElement;
    }

    function el<T extends HTMLElement = HTMLElement>(id: string): T {
        return document.getElementById(id) as T;
    }

    function isHidden(id: string): boolean {
        return el(id).classList.contains('hidden');
    }

    function answerButtons(): HTMLButtonElement[] {
        return Array.from(el('quiz-answers').querySelectorAll<HTMLButtonElement>('.answer-btn'));
    }

    /** 開始ボタン→再生ボタンと押して、スニペット再生タイマーが動く状態まで進める。 */
    function startAndPlay(): void {
        el<HTMLButtonElement>('quiz-start-btn').click();
        // performance.now() はフェイクタイマー下では 0 始まりなので、
        // startTime が falsy にならないよう時計を進めてから再生する。
        vi.advanceTimersByTime(50);
        el<HTMLButtonElement>('quiz-play-btn').click();
    }

    it('pauses and resets the quiz audio element', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(container());

        stopQuiz();

        expect(audioPause).toHaveBeenCalled();
        expect(quizAudio).not.toBeNull();
        expect(quizAudio?.getAttribute('src')).toBe('');
    });

    it('clears the snippet auto-stop timeout and the timer interval so nothing fires after the view is left', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(container());

        startAndPlay();

        // playSnippet が snippetTimeout と timerInterval を張った状態であること。
        expect(el('quiz-play-btn').hasAttribute('disabled')).toBe(true);
        expect(audioPlay).toHaveBeenCalled();
        expect(vi.getTimerCount()).toBeGreaterThan(0);

        stopQuiz();

        // stopQuiz は保留中のタイマーを1つも残してはいけない。
        expect(vi.getTimerCount()).toBe(0);

        const timerTextAfterStop = el('quiz-timer').textContent;
        const pauseCallsAfterStop = audioPause.mock.calls.length;

        vi.advanceTimersByTime(20000);

        // タイマーが生き残っていれば経過時間表示が書き換わるか、
        // スニペット停止の pause が追加で呼ばれるはず。
        expect(el('quiz-timer').textContent).toBe(timerTextAfterStop);
        expect(audioPause.mock.calls.length).toBe(pauseCallsAfterStop);
    });

    it('restores the start screen and clears the audio source, and stays that way when called repeatedly', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(container());

        startAndPlay();
        expect(isHidden('quiz-game-screen')).toBe(false);
        expect(isHidden('quiz-start-screen')).toBe(true);

        stopQuiz();
        stopQuiz();
        stopQuiz();

        expect(isHidden('quiz-start-screen')).toBe(false);
        expect(isHidden('quiz-game-screen')).toBe(true);
        expect(isHidden('quiz-final-screen')).toBe(true);
        expect(quizAudio?.getAttribute('src')).toBe('');
        expect(vi.getTimerCount()).toBe(0);
    });

    it('resets the playing flag and final-screen flag so a later stopQuiz reflects a clean state', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(container());

        stopQuiz();

        // 後片付け後は開始画面だけが見えている状態に戻る。
        expect(isHidden('quiz-start-screen')).toBe(false);
        expect(isHidden('quiz-game-screen')).toBe(true);
        expect(isHidden('quiz-final-screen')).toBe(true);
    });

    it('marks the correct and selected answers when a question is answered', async () => {
        const { renderQuizView } = await import('./quiz.js');
        renderQuizView(container());

        startAndPlay();

        const buttons = answerButtons();
        expect(buttons).toHaveLength(4);

        buttons[0].click();

        // quiz.ts の解答マーキング分岐が実際に走ること。
        expect(buttons.every(btn => btn.disabled)).toBe(true);
        expect(buttons.filter(btn => btn.classList.contains('correct'))).toHaveLength(1);
        expect(isHidden('quiz-result')).toBe(false);
        expect(el('quiz-result-message').textContent).toMatch(/正解！|残念！/);
    });

    it('resets isResultShowing on stopQuiz, so a stray Space press after leaving mid-result does not advance the quiz', async () => {
        const { renderQuizView, stopQuiz, handleQuizKeyPress } = await import('./quiz.js');
        renderQuizView(container());

        startAndPlay();
        answerButtons()[0].click();

        // 結果表示中であることを確認してから離脱する。
        expect(isHidden('quiz-result')).toBe(false);
        expect(el('quiz-question-number').textContent).toBe('1');

        stopQuiz();

        const spaceEvent = { code: 'Space', preventDefault: vi.fn() } as unknown as KeyboardEvent;
        handleQuizKeyPress(spaceEvent);

        // isResultShowing が残っていれば nextQuestion → generateQuestion が走り、
        // 問題番号が 2 に進んでしまう。
        expect(el('quiz-question-number').textContent).toBe('1');
        expect(vi.getTimerCount()).toBe(0);
    });

    it('leaves the view in the stopped state when a Space press arrives with no active question', async () => {
        const { renderQuizView, stopQuiz, handleQuizKeyPress } = await import('./quiz.js');
        renderQuizView(container());

        stopQuiz();

        const spaceEvent = { code: 'Space', preventDefault: vi.fn() } as unknown as KeyboardEvent;
        handleQuizKeyPress(spaceEvent);

        expect(spaceEvent.preventDefault).toHaveBeenCalled();
        expect(isHidden('quiz-start-screen')).toBe(false);
        expect(isHidden('quiz-game-screen')).toBe(true);
        expect(el('quiz-answers').children).toHaveLength(0);
        expect(audioPause).toHaveBeenCalled();
        expect(quizAudio?.getAttribute('src')).toBe('');
        expect(vi.getTimerCount()).toBe(0);
    });

    describe('options.signal によるリスナー解除', () => {
        it('signal 指定でもリスナーは通常どおり登録される', async () => {
            const { renderQuizView, stopQuiz } = await import('./quiz.js');
            const controller = new AbortController();
            renderQuizView(container(), { signal: controller.signal });

            el<HTMLButtonElement>('quiz-start-btn').click();

            expect(isHidden('quiz-game-screen')).toBe(false);
            expect(isHidden('quiz-start-screen')).toBe(true);

            stopQuiz();
        });

        it('abort 後は開始・再生ボタンのクリックが一切効かない', async () => {
            const { renderQuizView } = await import('./quiz.js');
            const controller = new AbortController();
            renderQuizView(container(), { signal: controller.signal });

            controller.abort();

            el<HTMLButtonElement>('quiz-start-btn').click();
            el<HTMLButtonElement>('quiz-play-btn').click();

            // リスナーが解除されていれば画面遷移もタイマー起動も起きない。
            expect(isHidden('quiz-start-screen')).toBe(false);
            expect(isHidden('quiz-game-screen')).toBe(true);
            expect(el('quiz-answers').children).toHaveLength(0);
            expect(audioPlay).not.toHaveBeenCalled();
            expect(vi.getTimerCount()).toBe(0);
        });

        it('abort 後は再挑戦ボタンのクリックも効かない', async () => {
            const { renderQuizView } = await import('./quiz.js');
            const controller = new AbortController();
            renderQuizView(container(), { signal: controller.signal });

            // 結果画面が出ている状態を模して、開始画面を隠しておく。
            el('quiz-start-screen').classList.add('hidden');
            el('quiz-final-screen').classList.remove('hidden');

            controller.abort();
            el<HTMLButtonElement>('quiz-retry-btn').click();

            expect(isHidden('quiz-final-screen')).toBe(false);
            expect(isHidden('quiz-start-screen')).toBe(true);
        });
    });
});
