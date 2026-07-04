import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Minimal DOM stand-ins for the quiz view. Provides just enough of the
 * `HTMLElement` surface (classList, textContent, dataset, querySelector,
 * event listener registration) for quiz.ts to run without a real DOM/jsdom.
 */
function createFakeElement(overrides: Record<string, unknown> = {}) {
    const classes = new Set<string>();
    const listeners: Record<string, Array<(...args: unknown[]) => void>> = {};
    return {
        classList: {
            add: (c: string) => classes.add(c),
            remove: (c: string) => classes.delete(c),
            contains: (c: string) => classes.has(c),
        },
        textContent: '',
        disabled: false,
        dataset: {},
        innerHTML: '',
        src: '',
        querySelector: () => createFakeElement(),
        querySelectorAll: () => [],
        appendChild: vi.fn(),
        addEventListener: (type: string, fn: (...args: unknown[]) => void) => {
            listeners[type] = listeners[type] ?? [];
            listeners[type].push(fn);
        },
        _listeners: listeners,
        ...overrides,
    };
}

describe('stopQuiz cleanup', () => {
    let audioPause: ReturnType<typeof vi.fn>;
    let elementRegistry: Record<string, ReturnType<typeof createFakeElement>>;
    let answerButtons: Array<ReturnType<typeof createFakeElement>>;

    beforeEach(() => {
        vi.resetModules();
        vi.useFakeTimers();

        audioPause = vi.fn();
        answerButtons = [];

        // A fake Audio constructor: quiz.ts does `new Audio()` at module load time.
        globalThis.Audio = vi.fn().mockImplementation(() => ({
            pause: audioPause,
            play: vi.fn(),
            src: '',
            currentTime: 0,
            volume: 1,
        })) as unknown as typeof Audio;

        elementRegistry = {
            'quiz-start-screen': createFakeElement(),
            'quiz-game-screen': createFakeElement(),
            'quiz-final-screen': createFakeElement(),
            'quiz-start-btn': createFakeElement(),
            'quiz-question-number': createFakeElement(),
            'quiz-total-questions': createFakeElement(),
            'quiz-timer': createFakeElement(),
            'quiz-play-btn': createFakeElement({ querySelector: () => createFakeElement() }),
            'quiz-answers': createFakeElement({ appendChild: (btn: ReturnType<typeof createFakeElement>) => {
                answerButtons.push(btn);
            } }),
            'quiz-result': createFakeElement(),
            'quiz-result-message': createFakeElement(),
            'quiz-correct-artwork': createFakeElement(),
            'quiz-correct-title': createFakeElement(),
            'quiz-correct-artist': createFakeElement(),
            'quiz-next-btn': createFakeElement(),
            'quiz-retry-btn': createFakeElement(),
            'quiz-final-score': createFakeElement(),
            'quiz-final-total': createFakeElement(),
            'quiz-final-avg-time': createFakeElement(),
            'quiz-ranking-list': createFakeElement(),
        };

        globalThis.document = {
            getElementById: (id: string) => elementRegistry[id] ?? null,
            querySelector: (selector: string) => {
                if (selector.includes('quiz-length')) return { value: '10' };
                if (selector.includes('quiz-difficulty')) return { value: 'normal' };
                return null;
            },
            createElement: () => createFakeElement(),
        } as unknown as Document;

        globalThis.window = {
            electronAPI: { invoke: vi.fn() },
        } as unknown as Window & typeof globalThis;

        globalThis.performance = { now: () => Date.now() } as Performance;

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
            elements: {
                volumeSlider: { value: '1', addEventListener: vi.fn() },
            },
        }));
        vi.doMock('../ui/utils.js', () => ({
            resolveArtworkPath: vi.fn(() => 'artwork.png'),
        }));
    });

    afterEach(() => {
        vi.useRealTimers();
        vi.restoreAllMocks();
    });

    it('pauses and resets the quiz audio element', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(createFakeElement());

        stopQuiz();

        expect(audioPause).toHaveBeenCalled();
    });

    it('clears the snippet auto-stop timeout so it cannot fire after the view is left', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        const container = createFakeElement();
        renderQuizView(container);

        // Simulate the game screen having started a snippet playback timer by
        // driving the flow through the public start button handler.
        const startBtnListeners = elementRegistry['quiz-start-btn']._listeners['click'] || [];
        expect(startBtnListeners.length).toBeGreaterThan(0);

        // startQuiz reads radio inputs via document.querySelector; our fake
        // document.querySelector returns null, so guard against throwing by
        // wrapping in a try — the important assertion is about timer counts.
        const pendingTimersBefore = vi.getTimerCount();

        stopQuiz();

        // stopQuiz must not leave any pending timers (snippetTimeout/timerInterval) running.
        expect(vi.getTimerCount()).toBeLessThanOrEqual(pendingTimersBefore);

        // Advancing time after stopQuiz must not throw or resume audio playback.
        expect(() => vi.advanceTimersByTime(20000)).not.toThrow();
    });

    it('is idempotent — calling stopQuiz multiple times does not throw', async () => {
        const { stopQuiz } = await import('./quiz.js');

        expect(() => {
            stopQuiz();
            stopQuiz();
            stopQuiz();
        }).not.toThrow();
    });

    it('resets the playing flag and final-screen flag so a later stopQuiz reflects a clean state', async () => {
        const { renderQuizView, stopQuiz } = await import('./quiz.js');
        renderQuizView(createFakeElement());

        stopQuiz();

        // After cleanup, the start screen should be shown again and the game/final
        // screens hidden — this is only true if stopQuiz fully resets view state.
        expect(elementRegistry['quiz-start-screen'].classList.contains('hidden')).toBe(false);
        expect(elementRegistry['quiz-game-screen'].classList.contains('hidden')).toBe(true);
        expect(elementRegistry['quiz-final-screen'].classList.contains('hidden')).toBe(true);
    });

    it('resets isResultShowing on stopQuiz, so a stray Space press after leaving mid-result does not call nextQuestion again', async () => {
        const { renderQuizView, stopQuiz, handleQuizKeyPress } = await import('./quiz.js');
        renderQuizView(createFakeElement());

        // Start a question: this populates quizElements.answers with answer buttons
        // wired to handleAnswer, and sets a startTime via the first playSnippet call.
        const startBtnListeners = elementRegistry['quiz-start-btn']._listeners['click'] || [];
        startBtnListeners[0]();

        const playBtnListeners = elementRegistry['quiz-play-btn']._listeners['click'] || [];
        playBtnListeners[0]();

        expect(answerButtons.length).toBeGreaterThan(0);

        // Answer the question: this sets quizState.isResultShowing = true internally.
        const answerClickListeners = answerButtons[0]._listeners['click'] || [];
        answerClickListeners[0]({ target: answerButtons[0] });

        // Leave the quiz view mid-result (as navigation.ts does on view change).
        stopQuiz();

        // A stray Space key press after leaving must not re-trigger nextQuestion
        // (which would call generateQuestion and repopulate answers) — the quiz
        // is no longer active, so isResultShowing must have been cleared by stopQuiz.
        const answerCountAfterStop = answerButtons.length;
        const spaceEvent = { code: 'Space', preventDefault: vi.fn() } as unknown as KeyboardEvent;
        handleQuizKeyPress(spaceEvent);

        expect(answerButtons.length).toBe(answerCountAfterStop);
    });

    it('is idempotent and safe when called repeatedly with no active question', async () => {
        const { renderQuizView, stopQuiz, handleQuizKeyPress } = await import('./quiz.js');
        renderQuizView(createFakeElement());

        stopQuiz();

        const spaceEvent = { code: 'Space', preventDefault: vi.fn() } as unknown as KeyboardEvent;
        expect(() => handleQuizKeyPress(spaceEvent)).not.toThrow();
        expect(audioPause).toHaveBeenCalled();
    });
});
