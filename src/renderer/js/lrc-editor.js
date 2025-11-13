// src/renderer/js/lrc-editor.js

import { state } from './state.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { showView } from './navigation.js';
import { resolveArtworkPath, formatSongTitle } from './ui/utils.js';
import { togglePlayPause, seek, getCurrentTime, getDuration, isPlaying } from './player.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let currentEditorSong = null;
let lyricsLines = []; // { text: string, timestamp: number | null } の配列
let activeLineIndex = -1;
let editorIsSeeking = false;
let historyStack = []; // <<<--- 追加: 操作履歴スタック
let redoStack = [];    // <<<--- 追加: Redo用スタック (今回はUndoのみ実装)

// エディタ要素への参照
const editorElements = {
    view: document.getElementById('lrc-editor-view'),
    artwork: document.getElementById('lrc-editor-artwork'),
    title: document.getElementById('lrc-editor-title'),
    artist: document.getElementById('lrc-editor-artist'),
    helpBtn: document.getElementById('lrc-editor-help-btn'),
    exitBtn: document.getElementById('lrc-editor-exit-btn'),
    saveBtn: document.getElementById('lrc-editor-save-btn'),
    playPauseBtn: document.getElementById('lrc-editor-play-pause-btn'),
    currentTime: document.getElementById('lrc-editor-current-time'),
    progressBar: document.getElementById('lrc-editor-progress-bar'),
    totalDuration: document.getElementById('lrc-editor-total-duration'),
    timestampBtn: document.getElementById('lrc-editor-timestamp-btn'),
    lyricsArea: document.getElementById('lrc-editor-lyrics-area'),
    textarea: document.getElementById('lrc-editor-textarea'),
    loadTextBtn: document.getElementById('lrc-editor-load-text-btn'),
    helpPopup: document.getElementById('lrc-editor-help-popup'),
    helpCloseBtn: document.getElementById('lrc-editor-help-close-btn'),
    undoBtn: document.getElementById('lrc-editor-undo-btn'),         // <<<--- 追加
    insertBlankBtn: document.getElementById('lrc-editor-insert-blank-btn'), // <<<--- 追加
};

let isEditorInitialized = false;

// --- ▼▼▼ 新規追加: 操作履歴を保存する関数 ▼▼▼ ---
function saveHistory() {
    // 状態が変化する場合のみ履歴に追加 (Undo/Redoによるループを防ぐ)
    const currentStateString = JSON.stringify(lyricsLines);
    const lastStateString = historyStack.length > 0 ? JSON.stringify(historyStack[historyStack.length - 1]) : null;

    if (currentStateString !== lastStateString) {
        historyStack.push(JSON.parse(currentStateString)); // ディープコピー
        redoStack = []; // 新しい操作をしたらRedo履歴はクリア
        updateUndoRedoButtons();
    }
}
// --- ▲▲▲ 新規追加 ▲▲▲ ---

// --- ▼▼▼ 新規追加: Undo/Redoボタンの状態を更新する関数 ▼▼▼ ---
function updateUndoRedoButtons() {
    editorElements.undoBtn.disabled = historyStack.length <= 1; // 初期状態を除いて1つ以上履歴があれば有効
    // Redoボタンがあれば有効/無効を切り替える (今回はUndoのみ)
    // editorElements.redoBtn.disabled = redoStack.length === 0;
}
// --- ▲▲▲ 新規追加 ▲▲▲ ---

// --- ▼▼▼ 新規追加: Undo処理 ▼▼▼ ---
function undo() {
    if (historyStack.length <= 1) return; // 初期状態しか残っていない場合は何もしない

    // 現在の状態をRedoスタックへ（任意）
    redoStack.push(JSON.parse(JSON.stringify(lyricsLines)));

    // 最新の履歴（現在の状態）を捨てて、一つ前の状態を取り出す
    historyStack.pop(); // 現在の状態を捨てる
    const previousState = historyStack[historyStack.length - 1]; // 一つ前の状態を取得
    lyricsLines = JSON.parse(JSON.stringify(previousState)); // ディープコピーして復元

    // UIを再描画
    redrawLyricsArea();
    // アクティブ行を復元 (範囲外チェックも行う)
    if (activeLineIndex < 0 || activeLineIndex >= lyricsLines.length) {
        activeLineIndex = lyricsLines.findIndex((_, i) => i === activeLineIndex) > -1 ? activeLineIndex : 0;
    }
    setActiveLine(activeLineIndex >= 0 ? activeLineIndex : 0); // 復元または最初の行へ
    updateUndoRedoButtons();
}
// --- ▲▲▲ 新規追加 ▲▲▲ ---

// Redo処理（今回は実装しないが、構造は以下のようになる）
/*
function redo() {
    if (redoStack.length === 0) return;
    // 現在の状態をUndoスタックへ
    saveHistory(); // saveHistory内でRedoスタックはクリアされるので先に呼ぶ
    // Redoスタックから状態を取り出す
    const nextState = redoStack.pop();
    lyricsLines = nextState;
    // UIを再描画
    redrawLyricsArea();
    setActiveLine(activeLineIndex >= 0 ? activeLineIndex : 0);
    updateUndoRedoButtons();
}
*/

// --- ▼▼▼ 新規追加: UIを再描画する関数 ▼▼▼ ---
function redrawLyricsArea() {
    editorElements.lyricsArea.innerHTML = ''; // 一旦クリア
    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞がありません。</p>';
        return;
    }
    lyricsLines.forEach((lineData, index) => {
        const lineElement = document.createElement('p');
        lineElement.classList.add('lyrics-line');
        lineElement.dataset.index = index;

        const textSpan = document.createElement('span');
        // 空白行は視覚的にわかるように placeholder スタイルを適用（任意）
        if (lineData.text.trim() === '') {
            textSpan.innerHTML = '&nbsp;'; // 非改行スペースを表示
            // lineElement.classList.add('placeholder-line'); // 必要ならCSSでスタイル定義
        } else {
            textSpan.textContent = lineData.text;
        }


        const timeSpan = document.createElement('time');
        timeSpan.classList.add('timestamp');
        timeSpan.textContent = lineData.timestamp !== null ? formatLrcTime(lineData.timestamp) : '--:--.--';

        lineElement.appendChild(textSpan);
        lineElement.appendChild(timeSpan);
        lineElement.addEventListener('click', () => setActiveLine(index));
        editorElements.lyricsArea.appendChild(lineElement);
    });
     // アクティブ行のスタイル復元
    const activeLineEl = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${activeLineIndex}"]`);
    if (activeLineEl) {
        activeLineEl.classList.add('active');
        // 必要ならスクロール位置も復元
        activeLineEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
    } else if (lyricsLines.length > 0) {
        // アクティブ行が見つからない場合は最初の行をアクティブにする
        setActiveLine(0);
    }
}
// --- ▲▲▲ 新規追加 ▲▲▲ ---

// --- ▼▼▼ 新規追加: 空白行を挿入する関数 ▼▼▼ ---
function insertBlankLine() {
    saveHistory(); // 操作履歴を保存
    const blankLine = { text: ' ', timestamp: null }; // textは半角スペース一つにする
    if (activeLineIndex === -1 || lyricsLines.length === 0) {
        // 歌詞がない場合や選択がない場合は末尾に追加
        lyricsLines.push(blankLine);
        activeLineIndex = lyricsLines.length - 1;
    } else {
        // アクティブな行の直後に挿入
        lyricsLines.splice(activeLineIndex + 1, 0, blankLine);
        activeLineIndex += 1; // 新しく挿入した行をアクティブにする
    }
    redrawLyricsArea(); // UIを再描画
    setActiveLine(activeLineIndex); // 新しい行にフォーカス
    updateUndoRedoButtons();
}
// --- ▲▲▲ 新規追加 ▲▲▲ ---


// イベントリスナー初期化に関数を追加
function initLrcEditorListeners() {
    if (isEditorInitialized) return;

    editorElements.exitBtn.addEventListener('click', () => {
        showView(state.activeListView);
    });

    editorElements.helpBtn.addEventListener('click', () => {
        editorElements.helpPopup.classList.remove('hidden');
    });
    editorElements.helpCloseBtn.addEventListener('click', () => {
        editorElements.helpPopup.classList.add('hidden');
    });

    editorElements.loadTextBtn.addEventListener('click', loadTextFromTextarea);
    editorElements.playPauseBtn.addEventListener('click', togglePlayPause);

    editorElements.progressBar.addEventListener('mousedown', () => { editorIsSeeking = true; });
    editorElements.progressBar.addEventListener('mouseup', () => {
        if (editorIsSeeking) {
            seek(parseFloat(editorElements.progressBar.value));
            editorIsSeeking = false;
        }
    });
    editorElements.progressBar.addEventListener('input', () => {
        if (editorIsSeeking) {
            editorElements.currentTime.textContent = formatEditorTime(parseFloat(editorElements.progressBar.value));
        }
    });

    editorElements.timestampBtn.addEventListener('click', addTimestamp);
    editorElements.view.addEventListener('keydown', handleEditorKeyDown);

    editorElements.saveBtn.addEventListener('click', handleSaveLrc);

    // --- ▼▼▼ 新しいボタンのリスナーを追加 ▼▼▼ ---
    editorElements.undoBtn.addEventListener('click', undo);
    editorElements.insertBlankBtn.addEventListener('click', insertBlankLine);
    // --- ▲▲▲ リスナーを追加 ▲▲▲ ---

    isEditorInitialized = true;
    updateUndoRedoButtons(); // 初期状態を設定
}

// startLrcEditor で履歴を初期化
export async function startLrcEditor(song) {
    console.log('[LRC Editor] Starting editor for:', song.title);
    if (!song) return;

    currentEditorSong = song;
    lyricsLines = [];
    activeLineIndex = -1;
    editorIsSeeking = false;
    // --- ▼▼▼ 履歴をクリア ▼▼▼ ---
    historyStack = [];
    redoStack = [];
    // --- ▲▲▲ 履歴をクリア ▲▲▲ ---


    initLrcEditorListeners();

    showView('lrc-editor-view');

    const album = state.albums.get(song.albumKey);
    const artwork = song.artwork || (album ? album.artwork : null);
    editorElements.artwork.src = resolveArtworkPath(artwork, false);
    editorElements.title.textContent = formatSongTitle(song.title);
    editorElements.artist.textContent = song.artist;

    editorElements.lyricsArea.innerHTML = '';
    editorElements.textarea.classList.add('hidden');
    editorElements.loadTextBtn.classList.add('hidden');

    try {
        const lyricsContent = await ipcRenderer.invoke('get-lyrics', song);
        if (lyricsContent && (lyricsContent.type === 'txt' || lyricsContent.type === 'lrc')) { // LRCも読み込めるように
            parseAndDisplayLyrics(lyricsContent.content, lyricsContent.type); // タイプを渡す
        } else {
            editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞テキストが見つかりません。下に貼り付けて読み込んでください。</p>';
            editorElements.textarea.value = '';
            editorElements.textarea.classList.remove('hidden');
            editorElements.loadTextBtn.classList.remove('hidden');
            saveHistory(); // 歌詞がない状態も履歴に保存
        }
    } catch (error) {
        console.error('Error fetching lyrics for editor:', error);
        showNotification('歌詞の読み込み中にエラーが発生しました。');
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞の読み込みエラー</p>';
        saveHistory(); // エラー状態も履歴に保存
    }

    const currentIsPlaying = isPlaying();
    const currentTime = getCurrentTime();
    const duration = getDuration();
    updateLrcEditorControls(currentIsPlaying, currentTime, duration);
    editorElements.progressBar.max = duration || 0;

    editorElements.view.setAttribute('tabindex', '-1');
    editorElements.view.focus();
    updateUndoRedoButtons(); // ボタン状態初期化
}

// 歌詞テキストを解析して表示エリアに描画する関数を修正
// LRC読み込みにも対応
function parseAndDisplayLyrics(textContent, type = 'txt') {
    editorElements.lyricsArea.innerHTML = '';

    if (type === 'lrc') {
        const lines = textContent.split('\n');
        const timeRegex = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/g; // LRCタイムスタンプ正規表現
        lyricsLines = lines.map(line => {
            const text = line.replace(timeRegex, '').trim();
            const matches = [...line.matchAll(timeRegex)];
            let timestamp = null;
            if (matches.length > 0) {
                const match = matches[0]; // 最初のタイムスタンプを採用
                const minutes = parseInt(match[1], 10);
                const seconds = parseInt(match[2], 10);
                // ミリ秒を2桁または3桁で取得し、3桁に正規化
                const milliseconds = parseInt(match[3].padEnd(3, '0'), 10);
                timestamp = minutes * 60 + seconds + milliseconds / 1000;
            }
             // 空行も保持する (text: ' ')
            return { text: text === '' ? ' ' : text, timestamp: timestamp };
        }).sort((a, b) => (a.timestamp ?? Infinity) - (b.timestamp ?? Infinity)); // タイムスタンプ順にソート

    } else { // TXTの場合
        lyricsLines = textContent
            .split('\n')
            // 空行も保持 (text: ' ')、タイムスタンプは null
            .map(line => ({ text: line.trim() === '' ? ' ' : line, timestamp: null }));
    }


    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞が空です。</p>';
        return;
    }

    redrawLyricsArea(); // UI描画関数を呼び出す
    setActiveLine(0);
    saveHistory(); // 初期状態を履歴に追加
}


// テキストエリアから歌詞を読み込む関数を修正
function loadTextFromTextarea() {
    const textContent = editorElements.textarea.value;
    if (textContent.trim() === '') {
        showNotification('テキストエリアに歌詞を入力または貼り付けてください。');
        return;
    }
    // --- ▼▼▼ 修正 ▼▼▼ ---
    // ここで saveHistory を呼ぶ前に lyricsLines を更新する
    lyricsLines = textContent
        .split('\n')
        .map(line => ({ text: line.trim() === '' ? ' ' : line, timestamp: null }));

    saveHistory(); // 変更前の状態ではなく、テキストエリア読み込み後の状態を保存

    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞が空です。</p>';
        return;
    }
    redrawLyricsArea(); // UI再描画
    setActiveLine(0);   // 最初の行を選択
    // saveHistory();   // ここでは呼ばない (上で呼んだため)
    // --- ▲▲▲ 修正 ▲▲▲ ---

    editorElements.textarea.classList.add('hidden');
    editorElements.loadTextBtn.classList.add('hidden');
    editorElements.view.focus();
    updateUndoRedoButtons(); // ボタン状態更新
}


// 指定したインデックスの行をアクティブにする関数 (変更なし)
function setActiveLine(index) {
    if (index < 0 || index >= lyricsLines.length) return;
    activeLineIndex = index;
    editorElements.lyricsArea.querySelectorAll('.lyrics-line.active').forEach(el => {
        el.classList.remove('active');
    });
    const targetLine = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${index}"]`);
    if (targetLine) {
        targetLine.classList.add('active');
        // スクロール処理を redrawLyricsArea に移動したので、ここでは不要かも
        targetLine.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
}

// 現在アクティブな行にタイムスタンプを記録する関数を修正
function addTimestamp() {
    if (activeLineIndex === -1 || activeLineIndex >= lyricsLines.length || !currentEditorSong) return;

    // --- ▼▼▼ 空白行の場合はタイムスタンプを設定しない ▼▼▼ ---
    if (lyricsLines[activeLineIndex].text.trim() === '') {
        showNotification("空白行にはタイムスタンプを設定できません。", 2000); // 少し短めに表示
        // 次の空でない行へ移動する
        let nextIndex = activeLineIndex + 1;
        while (nextIndex < lyricsLines.length && lyricsLines[nextIndex].text.trim() === '') {
            nextIndex++;
        }
        if (nextIndex < lyricsLines.length) {
            setActiveLine(nextIndex);
        }
        return;
    }
    // --- ▲▲▲ 空白行チェック ▲▲▲ ---

    saveHistory(); // ★★★ 操作履歴を保存 ★★★
    const currentTime = getCurrentTime();
    lyricsLines[activeLineIndex].timestamp = currentTime; // 状態を更新

    // UIを更新
    redrawLyricsArea(); // UI全体を再描画してタイムスタンプを表示

    // 次の空でない行を探してアクティブにする
    let nextIndex = activeLineIndex + 1;
    while (nextIndex < lyricsLines.length && lyricsLines[nextIndex].text.trim() === '') {
        nextIndex++;
    }
    if (nextIndex < lyricsLines.length) {
        setActiveLine(nextIndex);
    } else {
        console.log('[LRC Editor] All non-blank lines timestamped.');
        // 最後まで行ったらアクティブを解除するか、最終行に留まる
        // setActiveLine(activeLineIndex); // 最終行に留まる場合
    }
    updateUndoRedoButtons(); // ★★★ ボタン状態更新 ★★★
}


// LRCフォーマット用の時間文字列を生成 (mm:ss.xx) (変更なし)
function formatLrcTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '00:00.00';
    const min = Math.floor(seconds / 60).toString().padStart(2, '0');
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    // ミリ秒を2桁に修正 (LRC標準に合わせて)
    const ms = Math.floor((seconds % 1) * 100).toString().padStart(2, '0');
    return `${min}:${sec}.${ms}`;
}

// エディタ内のキーボードイベントを処理 (変更なし)
function handleEditorKeyDown(event) {
    if (event.target === editorElements.textarea) return;
    // Cmd+Z or Ctrl+Z で Undo
    if ((event.metaKey || event.ctrlKey) && event.key === 'z') {
        event.preventDefault();
        undo();
        return; // 他のキー操作をブロック
    }
     // Cmd+Shift+Z or Ctrl+Y で Redo (今回は実装しない)
     /*
     if ((event.metaKey || event.ctrlKey) && (event.key === 'Y' || (event.shiftKey && event.key === 'z'))) {
         event.preventDefault();
         redo();
         return;
     }
     */
    if (event.key.toUpperCase() === 'T') {
        event.preventDefault();
        addTimestamp();
    }
     if (event.code === 'Space' && !(event.metaKey || event.ctrlKey || event.altKey || event.shiftKey)) { // 修飾キーなしのスペースのみ
         event.preventDefault();
         togglePlayPause();
     }
}

// LRCデータを生成し、メインプロセスに保存を要求する関数 (変更なし)
async function handleSaveLrc() {
    if (!currentEditorSong || lyricsLines.length === 0) return;

    const incompleteLine = lyricsLines.find(line => line.text.trim() !== '' && line.timestamp === null);
    if (incompleteLine) {
        const confirmSave = confirm('まだタイムスタンプが設定されていない行があります。このまま保存しますか？\n（タイムスタンプがない行はLRCファイルに含まれません）');
        if (!confirmSave) return;
    }

    const sortedLines = [...lyricsLines]
        .filter(line => line.timestamp !== null) // タイムスタンプがある行のみ
        .sort((a, b) => a.timestamp - b.timestamp);

    const lrcContent = sortedLines
        .map(line => `[${formatLrcTime(line.timestamp)}]${line.text}`) // 空白行も text: ' ' として保存される
        .join('\n');

    const baseName = path.basename(currentEditorSong.path, path.extname(currentEditorSong.path));
    const lrcFileName = `${baseName}.lrc`;

    editorElements.saveBtn.disabled = true;
    editorElements.saveBtn.textContent = '保存中...';

    try {
        const result = await ipcRenderer.invoke('save-lrc-file', {
            fileName: lrcFileName,
            content: lrcContent
        });

        if (result.success) {
            showNotification(`同期歌詞ファイル「${lrcFileName}」を保存しました。`);
            hideNotification(3000);
            showView(state.activeListView);
        } else {
            showNotification(`エラー: ${result.message || 'LRCファイルの保存に失敗しました。'}`);
            hideNotification(5000);
        }
    } catch (error) {
        console.error('LRC保存IPCエラー:', error);
        showNotification('エラー: LRCファイルの保存中に問題が発生しました。');
        hideNotification(5000);
    } finally {
        editorElements.saveBtn.disabled = false;
        editorElements.saveBtn.textContent = 'LRCを保存';
    }
}

// LRCエディタビューから離れる際のクリーンアップ処理 (変更なし)
export function stopLrcEditing() {
    editorElements.view.removeEventListener('keydown', handleEditorKeyDown);
    currentEditorSong = null;
    console.log('[LRC Editor] Editor stopped.');
}

// player.js からの情報をもとにエディタの再生コントロールUIを更新する (変更なし)
export function updateLrcEditorControls(playing, currentTime, duration) {
    if (!editorElements.view || editorElements.view.classList.contains('hidden')) return;
    editorElements.playPauseBtn.classList.toggle('playing', playing);
    if (!isNaN(currentTime)) {
        editorElements.currentTime.textContent = formatEditorTime(currentTime);
        if (!editorIsSeeking) {
            editorElements.progressBar.value = currentTime;
        }
    }
    if (!isNaN(duration)) {
        const formattedDuration = formatEditorTime(duration);
        if (editorElements.totalDuration.textContent !== formattedDuration) {
             editorElements.totalDuration.textContent = formattedDuration;
        }
        if (editorElements.progressBar.max != duration) {
             editorElements.progressBar.max = duration;
        }
    }
}

// エディタ表示用の時間フォーマット (m:ss) (変更なし)
function formatEditorTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}