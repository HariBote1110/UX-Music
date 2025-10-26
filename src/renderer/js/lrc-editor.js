import { state } from './state.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { showView } from './navigation.js';
import { resolveArtworkPath, formatSongTitle } from './ui/utils.js'; // ★★★ formatSongTitle を追加 ★★★
import { togglePlayPause, seek, getCurrentTime, getDuration, isPlaying } from './player.js';
const { ipcRenderer } = require('electron');
const path = require('path'); // ★★★ path を require ★★★

let currentEditorSong = null;
let lyricsLines = []; // { text: string, timestamp: number | null } の配列
let activeLineIndex = -1;
let editorIsSeeking = false;

// エディタ要素への参照 (変更なし)
const editorElements = {
    view: document.getElementById('lrc-editor-view'),
    artwork: document.getElementById('lrc-editor-artwork'),
    title: document.getElementById('lrc-editor-title'),
    artist: document.getElementById('lrc-editor-artist'),
    helpBtn: document.getElementById('lrc-editor-help-btn'),
    exitBtn: document.getElementById('lrc-editor-exit-btn'),
    saveBtn: document.getElementById('lrc-editor-save-btn'), // ★★★ 保存ボタン ★★★
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
};

let isEditorInitialized = false;

// イベントリスナーの初期化
function initLrcEditorListeners() {
    if (isEditorInitialized) return;

    editorElements.exitBtn.addEventListener('click', () => {
        // TODO: 変更が未保存の場合の警告を検討
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

    // --- ▼▼▼ 保存ボタンのリスナーを追加 ▼▼▼ ---
    editorElements.saveBtn.addEventListener('click', handleSaveLrc);
    // --- ▲▲▲ リスナーを追加 ▲▲▲ ---

    isEditorInitialized = true;
}

/**
 * 同期歌詞エディタを開始する関数
 */
export async function startLrcEditor(song) {
    console.log('[LRC Editor] Starting editor for:', song.title);
    if (!song) return;

    currentEditorSong = song;
    lyricsLines = [];
    activeLineIndex = -1;
    editorIsSeeking = false;

    initLrcEditorListeners();

    showView('lrc-editor-view');

    const album = state.albums.get(song.albumKey);
    const artwork = song.artwork || (album ? album.artwork : null);
    editorElements.artwork.src = resolveArtworkPath(artwork, false);
    // ★★★ formatSongTitle を使用 ★★★
    editorElements.title.textContent = formatSongTitle(song.title);
    editorElements.artist.textContent = song.artist;

    editorElements.lyricsArea.innerHTML = '';
    editorElements.textarea.classList.add('hidden');
    editorElements.loadTextBtn.classList.add('hidden');

    try {
        const lyricsContent = await ipcRenderer.invoke('get-lyrics', song);
        if (lyricsContent && lyricsContent.type === 'txt') {
            parseAndDisplayLyrics(lyricsContent.content);
        } else {
            editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞テキストが見つかりません。下に貼り付けて読み込んでください。</p>';
            editorElements.textarea.value = '';
            editorElements.textarea.classList.remove('hidden');
            editorElements.loadTextBtn.classList.remove('hidden');
        }
    } catch (error) {
        console.error('Error fetching lyrics for editor:', error);
        showNotification('歌詞の読み込み中にエラーが発生しました。');
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞の読み込みエラー</p>';
    }

    const currentIsPlaying = isPlaying();
    const currentTime = getCurrentTime();
    const duration = getDuration();
    updateLrcEditorControls(currentIsPlaying, currentTime, duration);
    editorElements.progressBar.max = duration || 0;

     editorElements.view.setAttribute('tabindex', '-1');
     editorElements.view.focus();
}

/**
 * 歌詞テキストを解析して表示エリアに描画する
 */
function parseAndDisplayLyrics(textContent) {
    editorElements.lyricsArea.innerHTML = '';
    lyricsLines = textContent
        .split('\n')
        // ★★★ trim() を削除し、行頭行末の空白も保持するように変更 ★★★
        .filter(line => line.trim() !== '') // 空行のみ除外
        .map(line => ({ text: line, timestamp: null }));

    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞が空です。</p>';
        return;
    }

    lyricsLines.forEach((lineData, index) => {
        const lineElement = document.createElement('p');
        lineElement.classList.add('lyrics-line');
        lineElement.dataset.index = index;

        const textSpan = document.createElement('span');
        textSpan.textContent = lineData.text; // 空白もそのまま表示

        const timeSpan = document.createElement('time');
        timeSpan.classList.add('timestamp');
        timeSpan.textContent = '--:--.--';

        lineElement.appendChild(textSpan);
        lineElement.appendChild(timeSpan);
        lineElement.addEventListener('click', () => setActiveLine(index));
        editorElements.lyricsArea.appendChild(lineElement);
    });
    setActiveLine(0);
}

/**
 * テキストエリアから歌詞を読み込む
 */
function loadTextFromTextarea() {
    const textContent = editorElements.textarea.value;
    if (textContent.trim() === '') {
        showNotification('テキストエリアに歌詞を入力または貼り付けてください。');
        return;
    }
    parseAndDisplayLyrics(textContent);
    editorElements.textarea.classList.add('hidden');
    editorElements.loadTextBtn.classList.add('hidden');
    editorElements.view.focus();
}

/**
 * 指定したインデックスの行をアクティブにする
 */
function setActiveLine(index) {
    if (index < 0 || index >= lyricsLines.length) return;
    activeLineIndex = index;
    editorElements.lyricsArea.querySelectorAll('.lyrics-line.active').forEach(el => {
        el.classList.remove('active');
    });
    const targetLine = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${index}"]`);
    if (targetLine) {
        targetLine.classList.add('active');
        targetLine.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
}

/**
 * 現在アクティブな行にタイムスタンプを記録する
 */
function addTimestamp() {
    if (activeLineIndex === -1 || activeLineIndex >= lyricsLines.length || !currentEditorSong) return;
    const currentTime = getCurrentTime();
    lyricsLines[activeLineIndex].timestamp = currentTime;
    const targetLine = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${activeLineIndex}"]`);
    if (targetLine) {
        const timeSpan = targetLine.querySelector('.timestamp');
        if (timeSpan) {
            timeSpan.textContent = formatLrcTime(currentTime);
        }
    }
    if (activeLineIndex + 1 < lyricsLines.length) {
        setActiveLine(activeLineIndex + 1);
    } else {
        console.log('[LRC Editor] All lines timestamped.');
        // Optionally move focus to save button or provide visual feedback
    }
}

/**
 * LRCフォーマット用の時間文字列を生成 (mm:ss.xx)
 */
function formatLrcTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '00:00.00';
    const min = Math.floor(seconds / 60).toString().padStart(2, '0');
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    const ms = Math.floor((seconds % 1) * 100).toString().padStart(2, '0');
    return `${min}:${sec}.${ms}`;
}

/**
 * エディタ内のキーボードイベントを処理
 */
function handleEditorKeyDown(event) {
    if (event.target === editorElements.textarea) return;
    if (event.key.toUpperCase() === 'T') {
        event.preventDefault();
        addTimestamp();
    }
    // 他のショートカット（Spaceで再生/停止など）も追加可能
     if (event.code === 'Space') {
         event.preventDefault();
         togglePlayPause();
     }
}

// --- ▼▼▼ 保存処理を追加 ▼▼▼ ---
/**
 * LRCデータを生成し、メインプロセスに保存を要求する
 */
async function handleSaveLrc() {
    if (!currentEditorSong || lyricsLines.length === 0) return;

    // すべての行にタイムスタンプがあるか確認
    const incompleteLine = lyricsLines.find(line => line.timestamp === null);
    if (incompleteLine) {
        const confirmSave = confirm('まだタイムスタンプが設定されていない行があります。このまま保存しますか？\n（タイムスタンプがない行はLRCファイルに含まれません）');
        if (!confirmSave) return;
    }

    // タイムスタンプでソート (念のため)
    const sortedLines = [...lyricsLines]
        .filter(line => line.timestamp !== null) // タイムスタンプがある行のみ
        .sort((a, b) => a.timestamp - b.timestamp);

    // LRCフォーマット文字列を生成
    const lrcContent = sortedLines
        .map(line => `[${formatLrcTime(line.timestamp)}]${line.text}`)
        .join('\n');

    // ファイル名を決定 (曲名と同じにする)
    // sanitize 関数をメインプロセスから呼べないので、ファイルパスからベース名を取得
    const baseName = path.basename(currentEditorSong.path, path.extname(currentEditorSong.path));
    const lrcFileName = `${baseName}.lrc`; // ★★★ ファイル名 ★★★

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
            // 保存後、エディタを閉じるか、編集を続けるか選べるようにしても良い
            showView(state.activeListView); // 保存したらリストビューに戻る
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
// --- ▲▲▲ 保存処理を追加 ▲▲▲ ---

/**
 * LRCエディタビューから離れる際のクリーンアップ処理
 */
export function stopLrcEditing() {
    editorElements.view.removeEventListener('keydown', handleEditorKeyDown);
    // 再生を停止させる (任意)
    // if (isPlaying()) {
    //     togglePlayPause();
    // }
    currentEditorSong = null;
    console.log('[LRC Editor] Editor stopped.');
}

/**
 * player.js からの情報をもとにエディタの再生コントロールUIを更新する
 */
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

/**
 * エディタ表示用の時間フォーマット (m:ss)
 */
function formatEditorTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}