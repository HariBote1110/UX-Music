// src/renderer/js/quiz.js
import { state, elements } from './state.js';
import { resolveArtworkPath } from './ui/utils.js';
const electronAPI = window.electronAPI;

let quizElements = {};

const quizState = {
    totalQuestions: 10,
    difficulty: 'normal',
    currentQuestionIndex: -1,
    score: 0,
    correctAnswer: null,
    isPlayingSnippet: false,
    snippetTimeout: null,
    quizAudio: new Audio(),
    startTime: 0,
    answerTimes: [],
    timerInterval: null,
    isResultShowing: false,
    isFinalScreenShowing: false,
};

const SNIPPET_DURATION = 10000;
const CHOICES_COUNT = 4;

function getQuizSongs() {
    const allSongs = state.library.filter(song => song.type === 'local' && song.duration > 15);
    const uniqueSongsMap = new Map();
    allSongs.forEach(song => {
        const key = `${song.artist.toLowerCase()}|${song.title.toLowerCase()}`;
        if (!uniqueSongsMap.has(key)) {
            uniqueSongsMap.set(key, song);
        }
    });

    const uniqueSongs = Array.from(uniqueSongsMap.values());
    const playCounts = state.playCounts;

    if (quizState.difficulty === 'easy') {
        return uniqueSongs.filter(s => (playCounts[s.path]?.count || 0) > 5).sort((a, b) => (playCounts[b.path]?.count || 0) - (playCounts[a.path]?.count || 0));
    } else if (quizState.difficulty === 'hard') {
        return uniqueSongs.filter(s => (playCounts[s.path]?.count || 0) <= 5).sort((a, b) => (playCounts[a.path]?.count || 0) - (playCounts[b.path]?.count || 0));
    }
    return uniqueSongs;
}

function generateQuestion() {
    quizState.isPlayingSnippet = false;
    quizState.isResultShowing = false;
    quizState.startTime = 0;
    clearTimeout(quizState.snippetTimeout);
    clearInterval(quizState.timerInterval);
    quizState.quizAudio.pause();

    const availableSongs = getQuizSongs();
    if (availableSongs.length < CHOICES_COUNT) {
        quizElements.gameScreen.innerHTML = `<p>クイズを作成するには、この難易度で4曲以上のユニークな曲が必要です。</p><button id="quiz-back-btn" class="header-button">戻る</button>`;
        document.getElementById('quiz-back-btn').addEventListener('click', stopQuiz);
        return;
    }

    quizElements.result.classList.add('hidden');
    quizElements.answers.innerHTML = '';
    quizElements.timer.textContent = '0.000s';

    const songPool = quizState.difficulty === 'normal' ? availableSongs : availableSongs.slice(0, 100);

    const correctIndex = Math.floor(Math.random() * songPool.length);
    quizState.correctAnswer = songPool[correctIndex];

    const choices = new Set([quizState.correctAnswer]);
    while (choices.size < CHOICES_COUNT) {
        const randomIndex = Math.floor(Math.random() * availableSongs.length);
        choices.add(availableSongs[randomIndex]);
    }

    const shuffledChoices = Array.from(choices).sort(() => Math.random() - 0.5);

    shuffledChoices.forEach(song => {
        const button = document.createElement('button');
        button.className = 'answer-btn';
        button.textContent = song.title;
        button.dataset.songId = song.id;
        button.addEventListener('click', handleAnswer);
        quizElements.answers.appendChild(button);
    });

    quizState.currentQuestionIndex++;
    quizElements.questionNumber.textContent = quizState.currentQuestionIndex + 1;

    const safePath = quizState.correctAnswer.path.replace(/\\/g, '/').replace(/#/g, '%23');
    quizState.quizAudio.src = `file://${safePath}`;
    quizElements.playBtn.disabled = false;
    quizElements.playBtn.querySelector('img').src = './assets/icons/play.svg';
}

function playSnippet() {
    if (quizState.isPlayingSnippet || !quizState.correctAnswer) return;

    const mainPlayer = document.getElementById('main-player');
    if (mainPlayer && !mainPlayer.paused) {
        mainPlayer.pause();
    }

    quizState.quizAudio.volume = elements.volumeSlider.value;
    quizState.isPlayingSnippet = true;
    quizElements.playBtn.disabled = true;

    quizState.quizAudio.currentTime = 0;
    quizState.quizAudio.play();
    quizElements.playBtn.querySelector('img').src = './assets/icons/pause.svg';

    if (!quizState.startTime) {
        quizState.startTime = performance.now();
        quizState.timerInterval = setInterval(() => {
            const elapsedTime = (performance.now() - quizState.startTime) / 1000;
            quizElements.timer.textContent = `${elapsedTime.toFixed(3)}s`;
        }, 100);
    }

    quizState.snippetTimeout = setTimeout(() => {
        if (quizState.isPlayingSnippet) {
            quizState.quizAudio.pause();
            quizState.isPlayingSnippet = false;
        }
    }, SNIPPET_DURATION);
}

function handleAnswer(event) {
    if (!quizState.startTime) return;

    const answerTime = (performance.now() - quizState.startTime) / 1000;
    quizState.answerTimes.push(answerTime);
    quizElements.timer.textContent = `${answerTime.toFixed(3)}s`;

    clearTimeout(quizState.snippetTimeout);
    clearInterval(quizState.timerInterval);
    quizState.quizAudio.pause();
    quizState.isPlayingSnippet = false;
    quizState.isResultShowing = true;

    const selectedId = event.target.dataset.songId;
    const isCorrect = selectedId === quizState.correctAnswer.id;

    if (isCorrect) {
        quizState.score++;
        quizElements.resultMessage.textContent = '正解！';
        quizElements.resultMessage.className = 'correct';
    } else {
        quizElements.resultMessage.textContent = '残念！';
        quizElements.resultMessage.className = 'incorrect';
    }

    quizElements.answers.querySelectorAll('.answer-btn').forEach(btn => {
        btn.disabled = true;
        if (btn.dataset.songId === quizState.correctAnswer.id) btn.classList.add('correct');
        else if (btn.dataset.songId === selectedId) btn.classList.add('incorrect');
    });

    showResult();
}

function showResult() {
    const song = quizState.correctAnswer;
    const album = state.albums.get(song.albumKey);
    const artwork = song.artwork || (album ? album.artwork : null);

    quizElements.correctArtwork.src = resolveArtworkPath(artwork, true);
    quizElements.correctTitle.textContent = song.title;
    quizElements.correctArtist.textContent = song.artist;
    quizElements.result.classList.remove('hidden');

    if (quizState.currentQuestionIndex + 1 >= quizState.totalQuestions) {
        quizElements.nextBtn.textContent = '結果を見る';
    } else {
        quizElements.nextBtn.textContent = '次の問題へ';
    }
}

async function showFinalScreen() {
    quizState.isFinalScreenShowing = true;
    quizElements.gameScreen.classList.add('hidden');
    quizElements.finalScreen.classList.remove('hidden');

    const avgTime = quizState.answerTimes.reduce((a, b) => a + b, 0) / quizState.answerTimes.length;
    const finalAvgTime = isNaN(avgTime) ? 0 : avgTime;

    quizElements.finalScore.textContent = quizState.score;
    quizElements.finalTotal.textContent = quizState.totalQuestions;
    quizElements.finalAvgTime.textContent = finalAvgTime.toFixed(3);

    const scoreData = {
        score: quizState.score,
        avgTime: finalAvgTime,
        date: new Date().toISOString()
    };
    await electronAPI.invoke('save-quiz-score', scoreData);

    const scores = await electronAPI.invoke('get-quiz-scores');
    quizElements.rankingList.innerHTML = '';
    scores.slice(0, 5).forEach(s => {
        const li = document.createElement('li');
        li.innerHTML = `<span class="rank-score">${s.score}問正解</span><span class="rank-time">${s.avgTime.toFixed(3)}s</span>`;
        quizElements.rankingList.appendChild(li);
    });
}

function nextQuestion() {
    if (quizState.currentQuestionIndex + 1 >= quizState.totalQuestions) {
        showFinalScreen();
    } else {
        generateQuestion();
    }
}

function startQuiz() {
    quizState.totalQuestions = parseInt(document.querySelector('input[name="quiz-length"]:checked').value);
    quizState.difficulty = document.querySelector('input[name="quiz-difficulty"]:checked').value;
    quizState.currentQuestionIndex = -1;
    quizState.score = 0;
    quizState.answerTimes = [];
    quizState.startTime = 0;
    quizState.isFinalScreenShowing = false;

    quizElements.startScreen.classList.add('hidden');
    quizElements.finalScreen.classList.add('hidden');
    quizElements.gameScreen.classList.remove('hidden');
    quizElements.totalQuestions.textContent = quizState.totalQuestions;

    generateQuestion();
}

export function initQuiz() {
    quizElements = {
        startScreen: document.getElementById('quiz-start-screen'),
        gameScreen: document.getElementById('quiz-game-screen'),
        finalScreen: document.getElementById('quiz-final-screen'),
        startBtn: document.getElementById('quiz-start-btn'),
        questionNumber: document.getElementById('quiz-question-number'),
        totalQuestions: document.getElementById('quiz-total-questions'),
        timer: document.getElementById('quiz-timer'),
        playBtn: document.getElementById('quiz-play-btn'),
        answers: document.getElementById('quiz-answers'),
        result: document.getElementById('quiz-result'),
        resultMessage: document.getElementById('quiz-result-message'),
        correctArtwork: document.getElementById('quiz-correct-artwork'),
        correctTitle: document.getElementById('quiz-correct-title'),
        correctArtist: document.getElementById('quiz-correct-artist'),
        nextBtn: document.getElementById('quiz-next-btn'),
        retryBtn: document.getElementById('quiz-retry-btn'),
        finalScore: document.getElementById('quiz-final-score'),
        finalTotal: document.getElementById('quiz-final-total'),
        finalAvgTime: document.getElementById('quiz-final-avg-time'),
        rankingList: document.getElementById('quiz-ranking-list'),
    };

    quizElements.startBtn.addEventListener('click', startQuiz);
    quizElements.playBtn.addEventListener('click', playSnippet);
    quizElements.nextBtn.addEventListener('click', nextQuestion);
    quizElements.retryBtn.addEventListener('click', () => {
        quizElements.finalScreen.classList.add('hidden');
        quizElements.startScreen.classList.remove('hidden');
        quizState.isFinalScreenShowing = false;
    });

    elements.volumeSlider.addEventListener('input', () => {
        if (quizState.quizAudio) {
            quizState.quizAudio.volume = elements.volumeSlider.value;
        }
    });
}

export function handleQuizKeyPress(e) {
    if (e.code === 'Space') {
        e.preventDefault();
        if (quizState.isFinalScreenShowing) {
            return;
        }
        if (quizState.isResultShowing) {
            nextQuestion();
        } else if (!quizElements.playBtn.disabled) {
            playSnippet();
        }
    }
}

export function stopQuiz() {
    if (quizState.quizAudio) {
        quizState.quizAudio.pause();
        quizState.quizAudio.src = "";
    }
    clearTimeout(quizState.snippetTimeout);
    clearInterval(quizState.timerInterval);
    quizState.isPlayingSnippet = false;
    quizState.isFinalScreenShowing = false;

    if (quizElements.startScreen) {
        quizElements.startScreen.classList.remove('hidden');
        quizElements.gameScreen.classList.add('hidden');
        quizElements.finalScreen.classList.add('hidden');
    }
}