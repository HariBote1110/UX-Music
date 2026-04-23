// src/renderer/js/features/lrc-editor.js

import { state } from '../core/state.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { showView } from '../core/navigation.js';
import { resolveArtworkPath, formatSongTitle } from '../ui/utils.js';
import { togglePlayPause, seek, getCurrentTime, getDuration, isPlaying } from './player.js';
import { fetchLyricsForSong, lyricsAutoSync, saveLrcFile } from '../core/api/lyrics.js';

const INTERLUDE_LABEL = '[間奏]';
const TIMELINE_MIN_DURATION_SEC = 30;
const TIMELINE_MIN_CLIP_WIDTH_SEC = 0.35;
const TIMELINE_MIN_GAP_SEC = 0.02;
const TIMELINE_ZOOM_MIN = 1;
const TIMELINE_ZOOM_MAX = 8;
const TIMELINE_ZOOM_DEFAULT = 1;
const TIMELINE_PX_PER_SECOND = 12;
const TIMELINE_RENDER_WIDTH_MAX = 60000;
const LRC_META_LINE_REGEX = /^\[(ar|ti|al|by|offset|re|ve):.*\]$/i;

function getBasename(path) {
    return path.split(/[\\/]/).pop();
}

function getExtname(path) {
    const dotIndex = path.lastIndexOf('.');
    return dotIndex === -1 ? '' : path.substring(dotIndex);
}

function createLyricLine(text, timestamp = null) {
    return {
        text,
        timestamp,
    };
}

function isInterludeText(text) {
    const normalised = (text || '').trim().toLowerCase();
    return normalised === '' || normalised === '[間奏]' || normalised === '[interlude]' || normalised === '(interlude)';
}

function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

function normaliseTimestamp(seconds) {
    if (!Number.isFinite(seconds)) {
        return null;
    }
    return Number.parseFloat(Math.max(0, seconds).toFixed(3));
}

function createHistorySnapshot() {
    return {
        lyricsLines: lyricsLines.map(line => ({
            text: line.text,
            timestamp: line.timestamp,
        })),
        lrcMetadataLines: [...lrcMetadataLines],
    };
}

function restoreHistorySnapshot(snapshot) {
    lyricsLines = Array.isArray(snapshot?.lyricsLines)
        ? snapshot.lyricsLines.map(line => createLyricLine(line?.text || '', typeof line?.timestamp === 'number' ? line.timestamp : null))
        : [];
    lrcMetadataLines = Array.isArray(snapshot?.lrcMetadataLines)
        ? snapshot.lrcMetadataLines.filter(line => typeof line === 'string')
        : [];
}

function snapshotSignature(snapshot) {
    return JSON.stringify(snapshot);
}

function parseLrcTimestamp(match) {
    const minutes = Number.parseInt(match[1], 10);
    const seconds = Number.parseInt(match[2], 10);
    const milliseconds = Number.parseInt(String(match[3]).padEnd(3, '0').slice(0, 3), 10);

    if (!Number.isFinite(minutes) || !Number.isFinite(seconds) || !Number.isFinite(milliseconds)) {
        return null;
    }

    return normaliseTimestamp(minutes * 60 + seconds + milliseconds / 1000);
}

function getTimelineDuration() {
    const duration = Number(getDuration());
    const maxTimestamp = lyricsLines.reduce((max, line) => {
        if (typeof line.timestamp !== 'number') {
            return max;
        }
        return Math.max(max, line.timestamp);
    }, 0);

    const candidate = Math.max(
        TIMELINE_MIN_DURATION_SEC,
        Number.isFinite(duration) ? duration : 0,
        maxTimestamp + 2,
    );

    return Number.isFinite(candidate) && candidate > 0 ? candidate : TIMELINE_MIN_DURATION_SEC;
}

function getAdjacentTimestampInfo(index, direction) {
    if (direction === 0) return null;
    const step = direction > 0 ? 1 : -1;

    for (let i = index + step; i >= 0 && i < lyricsLines.length; i += step) {
        const timestamp = lyricsLines[i]?.timestamp;
        if (typeof timestamp === 'number') {
            return {
                index: i,
                timestamp,
            };
        }
    }

    return null;
}

function getAdjacentTimestamp(index, direction) {
    return getAdjacentTimestampInfo(index, direction)?.timestamp ?? null;
}

function clampTimestampForIndex(index, candidate, duration) {
    const safeDuration = Number.isFinite(duration) && duration > 0 ? duration : getTimelineDuration();
    const prev = getAdjacentTimestamp(index, -1);
    const next = getAdjacentTimestamp(index, 1);

    const min = prev === null ? 0 : prev + TIMELINE_MIN_GAP_SEC;
    const max = next === null ? safeDuration : next - TIMELINE_MIN_GAP_SEC;

    if (max <= min) {
        return min;
    }

    return clamp(candidate, min, max);
}

function chooseRulerStep(duration, zoom) {
    const targetTickCount = clamp(Math.round(10 * zoom), 10, 28);
    const target = duration / targetTickCount;
    const steps = [1, 2, 5, 10, 15, 20, 30, 60, 90, 120, 180, 300];
    return steps.find(step => step >= target) || 300;
}

function formatTimelineTime(seconds) {
    const sec = Math.max(0, Math.floor(seconds));
    const minPart = Math.floor(sec / 60);
    const secPart = String(sec % 60).padStart(2, '0');
    return `${minPart}:${secPart}`;
}

let currentEditorSong = null;
let lyricsLines = [];
let lrcMetadataLines = [];
let activeLineIndex = -1;
let editorIsSeeking = false;
let lastTimestampedLineIndex = -1;
let autoAdvanceArmed = false;
let isAutoSyncRunning = false;
let latestDetectedSegments = [];
let latestDetectedBy = '';
let historyStack = [];
let redoStack = [];
let timelineDragState = null;
let timelineZoom = TIMELINE_ZOOM_DEFAULT;

let editorElements = {};

function refreshEditorElements() {
    editorElements = {
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
        languageSelect: document.getElementById('lrc-editor-language-select'),
        autoSyncBtn: document.getElementById('lrc-editor-auto-sync-btn'),
        showDetectedBtn: document.getElementById('lrc-editor-show-detected-btn'),
        timestampBtn: document.getElementById('lrc-editor-timestamp-btn'),
        timelineScroll: document.getElementById('lrc-editor-timeline-scroll'),
        timelineRuler: document.getElementById('lrc-editor-timeline-ruler'),
        timelineTrack: document.getElementById('lrc-editor-timeline-track'),
        timelinePlayhead: document.getElementById('lrc-editor-timeline-playhead'),
        timelineClips: document.getElementById('lrc-editor-timeline-clips'),
        timelineZoomRange: document.getElementById('lrc-editor-timeline-zoom'),
        timelineZoomLabel: document.getElementById('lrc-editor-timeline-zoom-label'),
        unassignedLines: document.getElementById('lrc-editor-unassigned-lines'),
        lyricsArea: document.getElementById('lrc-editor-lyrics-area'),
        textarea: document.getElementById('lrc-editor-textarea'),
        loadTextBtn: document.getElementById('lrc-editor-load-text-btn'),
        helpPopup: document.getElementById('lrc-editor-help-popup'),
        helpCloseBtn: document.getElementById('lrc-editor-help-close-btn'),
        detectedPopup: document.getElementById('lrc-editor-detected-popup'),
        detectedMeta: document.getElementById('lrc-editor-detected-meta'),
        detectedContent: document.getElementById('lrc-editor-detected-content'),
        detectedCloseBtn: document.getElementById('lrc-editor-detected-close-btn'),
        undoBtn: document.getElementById('lrc-editor-undo-btn'),
        insertInterludeBtn: document.getElementById('lrc-editor-insert-interlude-btn'),
    };

    return Object.values(editorElements).every(Boolean);
}

function ensureEditorElements() {
    if (refreshEditorElements()) {
        return true;
    }

    console.error('[LRC Editor] Required editor elements are missing.');
    showNotification('LRCエディタの初期化に失敗しました。');
    hideNotification(3000);
    return false;
}

let isEditorInitialized = false;

function saveHistory() {
    const snapshot = createHistorySnapshot();
    const snapshotString = snapshotSignature(snapshot);
    const lastSnapshotString = historyStack.length > 0
        ? snapshotSignature(historyStack[historyStack.length - 1])
        : null;

    if (snapshotString !== lastSnapshotString) {
        historyStack.push(snapshot);
        redoStack = [];
        updateUndoRedoButtons();
    }
}

function updateUndoRedoButtons() {
    if (!editorElements.undoBtn) return;
    editorElements.undoBtn.disabled = historyStack.length <= 1;
}

function undo() {
    if (historyStack.length <= 1) return;

    redoStack.push(createHistorySnapshot());
    historyStack.pop();

    const previousState = historyStack[historyStack.length - 1];
    restoreHistorySnapshot(previousState);

    lastTimestampedLineIndex = -1;
    autoAdvanceArmed = false;

    redrawLyricsArea();

    if (lyricsLines.length === 0) {
        activeLineIndex = -1;
    } else if (activeLineIndex < 0 || activeLineIndex >= lyricsLines.length) {
        activeLineIndex = 0;
    }

    if (activeLineIndex >= 0) {
        setActiveLine(activeLineIndex);
    }

    updateUndoRedoButtons();
}

function updateLineTimestampDisplay(index) {
    const lineElement = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${index}"] .timestamp`);
    if (!lineElement) return;

    const timestamp = lyricsLines[index]?.timestamp;
    lineElement.textContent = typeof timestamp === 'number' ? formatLrcTime(timestamp) : '--:--.--';
}

function updateTimelineZoomDisplay() {
    if (editorElements.timelineZoomRange) {
        editorElements.timelineZoomRange.value = String(timelineZoom);
    }
    if (editorElements.timelineZoomLabel) {
        editorElements.timelineZoomLabel.textContent = `${timelineZoom.toFixed(1)}x`;
    }
}

function getTimelineViewportWidth() {
    if (editorElements.timelineScroll && editorElements.timelineScroll.clientWidth > 0) {
        return editorElements.timelineScroll.clientWidth;
    }
    if (editorElements.timelineTrack && editorElements.timelineTrack.clientWidth > 0) {
        return editorElements.timelineTrack.clientWidth;
    }
    return 640;
}

function applyTimelineRenderWidth(duration) {
    const viewportWidth = getTimelineViewportWidth();
    const basedOnDuration = duration * TIMELINE_PX_PER_SECOND * timelineZoom;
    const renderWidth = clamp(Math.ceil(basedOnDuration), viewportWidth, TIMELINE_RENDER_WIDTH_MAX);

    editorElements.timelineRuler.style.width = `${renderWidth}px`;
    editorElements.timelineTrack.style.width = `${renderWidth}px`;
    return renderWidth;
}

function setTimelineZoom(nextZoom) {
    const previousZoom = timelineZoom;
    timelineZoom = clamp(Number.parseFloat(nextZoom) || TIMELINE_ZOOM_DEFAULT, TIMELINE_ZOOM_MIN, TIMELINE_ZOOM_MAX);

    if (Math.abs(previousZoom - timelineZoom) < 0.001) {
        updateTimelineZoomDisplay();
        return;
    }

    const scroll = editorElements.timelineScroll;
    let anchorRatio = 0;
    if (scroll && scroll.scrollWidth > 0) {
        anchorRatio = (scroll.scrollLeft + scroll.clientWidth * 0.5) / scroll.scrollWidth;
    }

    updateTimelineZoomDisplay();
    renderTimeline();

    if (scroll && scroll.scrollWidth > 0) {
        const targetScroll = anchorRatio * scroll.scrollWidth - scroll.clientWidth * 0.5;
        scroll.scrollLeft = clamp(targetScroll, 0, Math.max(0, scroll.scrollWidth - scroll.clientWidth));
    }
}

function handleTimelineZoomInput(event) {
    setTimelineZoom(event?.target?.value);
}

function renderTimelineRuler(duration) {
    if (!editorElements.timelineRuler) return;

    editorElements.timelineRuler.innerHTML = '';
    const step = chooseRulerStep(duration, timelineZoom);

    for (let sec = 0; sec <= duration; sec += step) {
        const tick = document.createElement('div');
        tick.className = 'timeline-ruler-tick';
        tick.style.left = `${(sec / duration) * 100}%`;

        const label = document.createElement('span');
        label.textContent = formatTimelineTime(sec);
        tick.appendChild(label);
        editorElements.timelineRuler.appendChild(tick);
    }

    if (duration % step !== 0) {
        const lastTick = document.createElement('div');
        lastTick.className = 'timeline-ruler-tick';
        lastTick.style.left = '100%';

        const label = document.createElement('span');
        label.textContent = formatTimelineTime(duration);
        lastTick.appendChild(label);
        editorElements.timelineRuler.appendChild(lastTick);
    }
}

function renderTimelineClips(duration) {
    if (!editorElements.timelineClips) return;

    editorElements.timelineClips.innerHTML = '';

    lyricsLines.forEach((line, index) => {
        if (typeof line.timestamp !== 'number') {
            return;
        }

        const start = clamp(line.timestamp, 0, duration);
        const nextInfo = getAdjacentTimestampInfo(index, 1);
        let end = typeof nextInfo?.timestamp === 'number' ? nextInfo.timestamp : duration;

        if (end <= start) {
            end = Math.min(duration, start + TIMELINE_MIN_CLIP_WIDTH_SEC);
        }

        let leftPercent = (start / duration) * 100;
        let widthPercent = Math.max(((end - start) / duration) * 100, 0.8);

        leftPercent = clamp(leftPercent, 0, 99.2);
        const availableWidth = 100 - leftPercent;
        widthPercent = clamp(widthPercent, 0.8, Math.max(availableWidth, 0.8));

        const clip = document.createElement('div');
        clip.className = 'timeline-clip';
        if (index === activeLineIndex) {
            clip.classList.add('active');
        }
        clip.dataset.index = String(index);
        clip.style.left = `${leftPercent}%`;
        clip.style.width = `${widthPercent}%`;
        clip.title = `${formatLrcTime(start)} ${line.text || '(空白)'}`;

        const startHandle = document.createElement('button');
        startHandle.type = 'button';
        startHandle.className = 'timeline-clip-handle start';
        startHandle.title = '開始位置を調整';
        startHandle.addEventListener('mousedown', (event) => {
            beginTimelineClipPointerInteraction(event, index, 'resize-start');
        });

        const endHandle = document.createElement('button');
        endHandle.type = 'button';
        endHandle.className = 'timeline-clip-handle end';
        if (!nextInfo) {
            endHandle.classList.add('disabled');
            endHandle.disabled = true;
            endHandle.title = '末尾クリップは右端調整できません';
        } else {
            endHandle.title = '終了位置を調整';
            endHandle.addEventListener('mousedown', (event) => {
                beginTimelineClipPointerInteraction(event, index, 'resize-end');
            });
        }

        const timeLabel = document.createElement('span');
        timeLabel.className = 'timeline-clip-time';
        timeLabel.textContent = formatLrcTime(start);

        const textLabel = document.createElement('span');
        textLabel.className = 'timeline-clip-text';
        textLabel.textContent = `${index + 1}. ${line.text || '(空白)'}`;

        clip.appendChild(startHandle);
        clip.appendChild(endHandle);
        clip.appendChild(timeLabel);
        clip.appendChild(textLabel);

        clip.addEventListener('mousedown', (event) => {
            beginTimelineClipPointerInteraction(event, index, 'move');
        });

        clip.addEventListener('click', (event) => {
            event.stopPropagation();
            setActiveLine(index, true);
        });

        editorElements.timelineClips.appendChild(clip);
    });
}

function renderUnassignedLines() {
    if (!editorElements.unassignedLines) return;

    editorElements.unassignedLines.innerHTML = '';
    const unassigned = lyricsLines
        .map((line, index) => ({ line, index }))
        .filter(item => typeof item.line.timestamp !== 'number');

    if (unassigned.length === 0) {
        const placeholder = document.createElement('p');
        placeholder.className = 'timeline-unassigned-placeholder';
        placeholder.textContent = '未配置の歌詞行はありません。';
        editorElements.unassignedLines.appendChild(placeholder);
        return;
    }

    unassigned.forEach(({ line, index }) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'timeline-unassigned-item';
        if (index === activeLineIndex) {
            item.classList.add('active');
        }
        item.dataset.index = String(index);
        const text = (line.text || '').trim();
        item.textContent = `${index + 1}. ${text === '' ? '(空白)' : text}`;
        item.title = item.textContent;

        item.addEventListener('click', () => {
            setActiveLine(index, true);
            editorElements.view.focus();
        });

        editorElements.unassignedLines.appendChild(item);
    });
}

function updateTimelinePlayhead(currentTime) {
    if (!editorElements.timelinePlayhead) return;

    const duration = getTimelineDuration();
    const safeCurrentTime = Number.isFinite(currentTime) ? clamp(currentTime, 0, duration) : 0;
    editorElements.timelinePlayhead.style.left = `${(safeCurrentTime / duration) * 100}%`;
}

function renderTimeline() {
    if (!editorElements.timelineTrack) return;

    const duration = getTimelineDuration();
    applyTimelineRenderWidth(duration);
    renderTimelineRuler(duration);
    renderTimelineClips(duration);
    renderUnassignedLines();
    updateTimelinePlayhead(getCurrentTime());
}

function redrawLyricsArea() {
    editorElements.lyricsArea.innerHTML = '';

    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞がありません。</p>';
        renderTimeline();
        return;
    }

    lyricsLines.forEach((lineData, index) => {
        const lineElement = document.createElement('p');
        lineElement.classList.add('lyrics-line');
        lineElement.dataset.index = String(index);

        if (isInterludeText(lineData.text)) {
            lineElement.classList.add('interlude-line');
        }

        const textSpan = document.createElement('span');
        if ((lineData.text || '').trim() === '') {
            textSpan.innerHTML = '&nbsp;';
        } else {
            textSpan.textContent = lineData.text;
        }

        const timeSpan = document.createElement('time');
        timeSpan.classList.add('timestamp');
        timeSpan.textContent = lineData.timestamp !== null ? formatLrcTime(lineData.timestamp) : '--:--.--';

        lineElement.appendChild(textSpan);
        lineElement.appendChild(timeSpan);
        lineElement.addEventListener('click', () => setActiveLine(index, true));
        editorElements.lyricsArea.appendChild(lineElement);
    });

    renderTimeline();

    if (activeLineIndex >= 0 && activeLineIndex < lyricsLines.length) {
        const activeLineEl = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${activeLineIndex}"]`);
        if (activeLineEl) {
            activeLineEl.classList.add('active');
        }
    } else if (lyricsLines.length > 0) {
        setActiveLine(0);
    }
}

function clearTimelineDragState() {
    document.removeEventListener('mousemove', handleTimelineClipDragMove);
    document.removeEventListener('mouseup', endTimelineClipDrag);

    if (timelineDragState?.clipElement && timelineDragState.clipElement.isConnected) {
        timelineDragState.clipElement.classList.remove('dragging');
    }

    timelineDragState = null;
}

function beginTimelineClipPointerInteraction(event, lineIndex, mode) {
    if (event.button !== 0) {
        return;
    }

    if (!editorElements.timelineTrack) {
        return;
    }

    const line = lyricsLines[lineIndex];
    if (!line || typeof line.timestamp !== 'number') {
        return;
    }

    event.preventDefault();
    event.stopPropagation();

    setActiveLine(lineIndex, true, {
        scrollLyric: false,
        scrollTimeline: false,
    });

    const nextInfo = getAdjacentTimestampInfo(lineIndex, 1);
    if (mode === 'resize-end' && !nextInfo) {
        return;
    }

    const followingInfo = nextInfo ? getAdjacentTimestampInfo(nextInfo.index, 1) : null;
    const trackRect = editorElements.timelineTrack.getBoundingClientRect();
    if (trackRect.width <= 0) {
        return;
    }

    timelineDragState = {
        mode,
        index: lineIndex,
        startX: event.clientX,
        originalTimestamp: line.timestamp,
        nextIndex: nextInfo ? nextInfo.index : -1,
        originalNextTimestamp: nextInfo ? nextInfo.timestamp : null,
        followingTimestamp: followingInfo ? followingInfo.timestamp : null,
        segmentDuration: nextInfo ? (nextInfo.timestamp - line.timestamp) : null,
        duration: getTimelineDuration(),
        trackRect,
        savedHistory: false,
        moved: false,
        clipElement: event.currentTarget.closest('.timeline-clip') || event.currentTarget,
    };

    if (timelineDragState.clipElement) {
        timelineDragState.clipElement.classList.add('dragging');
    }

    document.addEventListener('mousemove', handleTimelineClipDragMove);
    document.addEventListener('mouseup', endTimelineClipDrag);
}

function collectTimelineDeltaUpdates(deltaSec) {
    if (!timelineDragState) {
        return [];
    }

    const updates = [];
    const state = timelineDragState;

    if (state.mode === 'move') {
        if (state.nextIndex >= 0 && Number.isFinite(state.segmentDuration) && state.segmentDuration > 0) {
            const prev = getAdjacentTimestamp(state.index, -1);
            const min = prev === null ? 0 : prev + TIMELINE_MIN_GAP_SEC;
            const max = state.followingTimestamp === null
                ? state.duration - state.segmentDuration
                : state.followingTimestamp - TIMELINE_MIN_GAP_SEC - state.segmentDuration;
            const nextStart = max <= min
                ? min
                : clamp(state.originalTimestamp + deltaSec, min, max);
            const nextEnd = nextStart + state.segmentDuration;

            const nextStartValue = normaliseTimestamp(nextStart);
            const nextEndValue = normaliseTimestamp(nextEnd);

            if (nextStartValue !== null && lyricsLines[state.index].timestamp !== nextStartValue) {
                updates.push({ index: state.index, timestamp: nextStartValue });
            }

            if (nextEndValue !== null && lyricsLines[state.nextIndex].timestamp !== nextEndValue) {
                updates.push({ index: state.nextIndex, timestamp: nextEndValue });
            }
            return updates;
        }

        const candidate = state.originalTimestamp + deltaSec;
        const clamped = clampTimestampForIndex(state.index, candidate, state.duration);
        const value = normaliseTimestamp(clamped);
        if (value !== null && lyricsLines[state.index].timestamp !== value) {
            updates.push({ index: state.index, timestamp: value });
        }
        return updates;
    }

    if (state.mode === 'resize-start') {
        const prev = getAdjacentTimestamp(state.index, -1);
        const min = prev === null ? 0 : prev + TIMELINE_MIN_GAP_SEC;
        const max = state.originalNextTimestamp === null
            ? state.duration - TIMELINE_MIN_CLIP_WIDTH_SEC
            : state.originalNextTimestamp - TIMELINE_MIN_CLIP_WIDTH_SEC;
        const nextStart = max <= min
            ? min
            : clamp(state.originalTimestamp + deltaSec, min, max);
        const value = normaliseTimestamp(nextStart);
        if (value !== null && lyricsLines[state.index].timestamp !== value) {
            updates.push({ index: state.index, timestamp: value });
        }
        return updates;
    }

    if (state.mode === 'resize-end') {
        if (state.nextIndex < 0 || state.originalNextTimestamp === null) {
            return updates;
        }

        const currentStart = typeof lyricsLines[state.index]?.timestamp === 'number'
            ? lyricsLines[state.index].timestamp
            : state.originalTimestamp;
        const min = currentStart + TIMELINE_MIN_CLIP_WIDTH_SEC;
        const max = state.followingTimestamp === null
            ? state.duration
            : state.followingTimestamp - TIMELINE_MIN_GAP_SEC;
        const nextEnd = max <= min
            ? min
            : clamp(state.originalNextTimestamp + deltaSec, min, max);
        const value = normaliseTimestamp(nextEnd);
        if (value !== null && lyricsLines[state.nextIndex].timestamp !== value) {
            updates.push({ index: state.nextIndex, timestamp: value });
        }
    }

    return updates;
}

function handleTimelineClipDragMove(event) {
    if (!timelineDragState) {
        return;
    }

    event.preventDefault();

    const deltaPx = event.clientX - timelineDragState.startX;
    const deltaSec = (deltaPx / timelineDragState.trackRect.width) * timelineDragState.duration;
    const updates = collectTimelineDeltaUpdates(deltaSec);

    if (updates.length === 0) {
        return;
    }

    updates.forEach((update) => {
        lyricsLines[update.index].timestamp = update.timestamp;
        updateLineTimestampDisplay(update.index);
    });

    if (!timelineDragState.savedHistory) {
        saveHistory();
        timelineDragState.savedHistory = true;
    }

    timelineDragState.moved = true;
    renderTimelineClips(timelineDragState.duration);
}

function endTimelineClipDrag() {
    if (!timelineDragState) {
        return;
    }

    const moved = timelineDragState.moved;
    clearTimelineDragState();

    if (moved) {
        updateUndoRedoButtons();
    }
}

function handleTimelineTrackClick(event) {
    if (!editorElements.timelineTrack) return;
    if (event.target.closest('.timeline-clip')) return;

    const rect = editorElements.timelineTrack.getBoundingClientRect();
    if (rect.width <= 0) return;

    const duration = getTimelineDuration();
    const ratio = clamp((event.clientX - rect.left) / rect.width, 0, 1);
    const targetTime = ratio * duration;

    seek(targetTime);
    editorElements.currentTime.textContent = formatEditorTime(targetTime);
    editorElements.progressBar.value = targetTime;
    updateTimelinePlayhead(targetTime);
    editorElements.view.focus();
}

function insertInterludeLine() {
    const interludeLine = createLyricLine(INTERLUDE_LABEL, null);

    if (activeLineIndex === -1 || lyricsLines.length === 0) {
        lyricsLines.push(interludeLine);
        activeLineIndex = lyricsLines.length - 1;
    } else {
        lyricsLines.splice(activeLineIndex + 1, 0, interludeLine);
        activeLineIndex += 1;
    }

    lastTimestampedLineIndex = -1;
    autoAdvanceArmed = false;

    redrawLyricsArea();
    setActiveLine(activeLineIndex);
    saveHistory();
    updateUndoRedoButtons();
}

function initLrcEditorListeners() {
    if (!ensureEditorElements()) return false;

    if (!isEditorInitialized) {
        editorElements.exitBtn.addEventListener('click', () => {
            showView(state.activeListView);
        });

        editorElements.helpBtn.addEventListener('click', () => {
            editorElements.helpPopup.classList.remove('hidden');
        });

        editorElements.helpCloseBtn.addEventListener('click', () => {
            editorElements.helpPopup.classList.add('hidden');
        });

        editorElements.showDetectedBtn.addEventListener('click', openDetectedPopup);
        editorElements.detectedCloseBtn.addEventListener('click', closeDetectedPopup);

        editorElements.loadTextBtn.addEventListener('click', loadTextFromTextarea);
        editorElements.playPauseBtn.addEventListener('click', togglePlayPause);

        editorElements.progressBar.addEventListener('mousedown', () => {
            editorIsSeeking = true;
        });

        editorElements.progressBar.addEventListener('mouseup', () => {
            if (editorIsSeeking) {
                seek(Number.parseFloat(editorElements.progressBar.value));
                editorIsSeeking = false;
            }
        });

        editorElements.progressBar.addEventListener('input', () => {
            if (editorIsSeeking) {
                const seekTime = Number.parseFloat(editorElements.progressBar.value);
                editorElements.currentTime.textContent = formatEditorTime(seekTime);
                updateTimelinePlayhead(seekTime);
            }
        });

        editorElements.timelineTrack.addEventListener('click', handleTimelineTrackClick);
        editorElements.timelineZoomRange.addEventListener('input', handleTimelineZoomInput);

        editorElements.timestampBtn.addEventListener('click', addTimestamp);
        editorElements.autoSyncBtn.addEventListener('click', runAutoSync);
        editorElements.saveBtn.addEventListener('click', handleSaveLrc);
        editorElements.undoBtn.addEventListener('click', undo);
        editorElements.insertInterludeBtn.addEventListener('click', insertInterludeLine);

        isEditorInitialized = true;
    }

    editorElements.view.removeEventListener('keydown', handleEditorKeyDown);
    editorElements.view.addEventListener('keydown', handleEditorKeyDown);

    setAutoSyncButtonState(false);
    updateTimelineZoomDisplay();
    updateUndoRedoButtons();
    return true;
}

export async function startLrcEditor(song) {
    if (!song) return;
    console.log('[LRC Editor] Starting editor for:', song.title);

    currentEditorSong = song;
    lyricsLines = [];
    lrcMetadataLines = [];
    activeLineIndex = -1;
    editorIsSeeking = false;
    lastTimestampedLineIndex = -1;
    autoAdvanceArmed = false;
    isAutoSyncRunning = false;
    latestDetectedSegments = [];
    latestDetectedBy = '';
    historyStack = [];
    redoStack = [];
    clearTimelineDragState();

    if (!initLrcEditorListeners()) return;

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
        const lyricsContent = await fetchLyricsForSong(song);
        if (lyricsContent && (lyricsContent.type === 'txt' || lyricsContent.type === 'lrc')) {
            parseAndDisplayLyrics(lyricsContent.content, lyricsContent.type);
        } else {
            editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞テキストが見つかりません。下に貼り付けて読み込んでください。</p>';
            editorElements.textarea.value = '';
            editorElements.textarea.classList.remove('hidden');
            editorElements.loadTextBtn.classList.remove('hidden');
            renderTimeline();
            saveHistory();
        }
    } catch (error) {
        console.error('Error fetching lyrics for editor:', error);
        showNotification('歌詞の読み込み中にエラーが発生しました。');
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞の読み込みエラー</p>';
        renderTimeline();
        saveHistory();
    }

    const currentIsPlaying = isPlaying();
    const currentTime = getCurrentTime();
    const duration = getDuration();

    updateLrcEditorControls(currentIsPlaying, currentTime, duration);
    editorElements.progressBar.max = Number.isFinite(duration) ? duration : 0;

    editorElements.view.setAttribute('tabindex', '-1');
    editorElements.view.focus();

    closeDetectedPopup();
    updateDetectedPreviewUI();
    setAutoSyncButtonState(false);
    updateUndoRedoButtons();
}

function parseAndDisplayLyrics(textContent, type = 'txt') {
    editorElements.lyricsArea.innerHTML = '';
    lastTimestampedLineIndex = -1;
    autoAdvanceArmed = false;

    const normalisedContent = String(textContent || '').replace(/\r\n?/g, '\n');
    lrcMetadataLines = [];

    if (type === 'lrc') {
        const lines = normalisedContent.split('\n');
        lyricsLines = [];

        lines.forEach(rawLine => {
            const line = rawLine.trim();
            const timestampRegex = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/g;
            const matches = [...line.matchAll(timestampRegex)];

            if (matches.length === 0) {
                if (line === '') {
                    lyricsLines.push(createLyricLine('', null));
                    return;
                }

                if (LRC_META_LINE_REGEX.test(line)) {
                    lrcMetadataLines.push(line);
                    return;
                }

                lyricsLines.push(createLyricLine(line, null));
                return;
            }

            const lyricText = line.replace(timestampRegex, '').trim();
            let pushed = 0;

            matches.forEach(match => {
                const timestamp = parseLrcTimestamp(match);
                if (typeof timestamp === 'number') {
                    lyricsLines.push(createLyricLine(lyricText, timestamp));
                    pushed += 1;
                }
            });

            if (pushed === 0) {
                lyricsLines.push(createLyricLine(lyricText, null));
            }
        });
    } else {
        lyricsLines = normalisedContent
            .split('\n')
            .map(line => createLyricLine(line.trim() === '' ? '' : line, null));
    }

    if (lyricsLines.length === 0) {
        editorElements.lyricsArea.innerHTML = '<p class="lyrics-line placeholder">歌詞が空です。</p>';
        renderTimeline();
        saveHistory();
        return;
    }

    redrawLyricsArea();
    setActiveLine(0);
    saveHistory();
}

function loadTextFromTextarea() {
    const textContent = editorElements.textarea.value;
    if (textContent.trim() === '') {
        showNotification('テキストエリアに歌詞を入力または貼り付けてください。');
        return;
    }

    const looksLikeLrc = /\[\d{2}:\d{2}\.\d{2,3}\]/.test(textContent);
    parseAndDisplayLyrics(textContent, looksLikeLrc ? 'lrc' : 'txt');

    editorElements.textarea.classList.add('hidden');
    editorElements.loadTextBtn.classList.add('hidden');
    editorElements.view.focus();
    updateUndoRedoButtons();
}

function setAutoSyncButtonState(running) {
    if (!editorElements.autoSyncBtn) return;

    editorElements.autoSyncBtn.disabled = running;
    editorElements.autoSyncBtn.dataset.running = running ? 'true' : 'false';
    editorElements.autoSyncBtn.textContent = running ? '解析中...' : '自動同期解析';

    if (editorElements.languageSelect) {
        editorElements.languageSelect.disabled = running;
    }

    if (editorElements.showDetectedBtn) {
        editorElements.showDetectedBtn.disabled = running || latestDetectedSegments.length === 0;
    }
}

function formatDetectedSegments(segments) {
    if (!Array.isArray(segments) || segments.length === 0) {
        return '(空)';
    }

    return segments.map((segment, index) => {
        const start = Number.isFinite(segment?.start) ? segment.start : 0;
        const end = Number.isFinite(segment?.end) ? segment.end : start;
        const text = (segment?.text || '').trim();
        const label = text === '' ? '(空白)' : text;
        return `${String(index + 1).padStart(2, '0')}. [${formatLrcTime(start)} - ${formatLrcTime(end)}] ${label}`;
    }).join('\n');
}

function updateDetectedPreviewUI() {
    const hasSegments = latestDetectedSegments.length > 0;

    if (editorElements.showDetectedBtn) {
        editorElements.showDetectedBtn.disabled = isAutoSyncRunning || !hasSegments;
    }

    if (editorElements.detectedMeta) {
        if (!hasSegments) {
            editorElements.detectedMeta.textContent = 'まだ解析結果がありません。';
        } else {
            const source = latestDetectedBy ? latestDetectedBy : 'unknown';
            editorElements.detectedMeta.textContent = `採用候補: ${source} / セグメント数: ${latestDetectedSegments.length}`;
        }
    }

    if (editorElements.detectedContent) {
        editorElements.detectedContent.textContent = formatDetectedSegments(latestDetectedSegments);
    }
}

function openDetectedPopup() {
    if (!editorElements.detectedPopup) return;
    updateDetectedPreviewUI();
    editorElements.detectedPopup.classList.remove('hidden');
}

function closeDetectedPopup() {
    if (!editorElements.detectedPopup) return;
    editorElements.detectedPopup.classList.add('hidden');
}

function applyDetectedPreview(result) {
    latestDetectedBy = typeof result?.detectedBy === 'string' ? result.detectedBy : '';
    latestDetectedSegments = Array.isArray(result?.detectedSegments)
        ? result.detectedSegments.map(segment => ({
            start: Number.isFinite(segment?.start) ? segment.start : 0,
            end: Number.isFinite(segment?.end) ? segment.end : (Number.isFinite(segment?.start) ? segment.start : 0),
            text: typeof segment?.text === 'string' ? segment.text : '',
        }))
        : [];
    updateDetectedPreviewUI();
}

async function runAutoSync() {
    if (isAutoSyncRunning) return;

    if (!currentEditorSong || !currentEditorSong.path) {
        showNotification('同期対象の曲情報が見つかりません。');
        hideNotification(2500);
        return;
    }

    if (lyricsLines.length === 0) {
        showNotification('先に歌詞テキストを読み込んでください。');
        hideNotification(2500);
        return;
    }

    const hasAnyContent = lyricsLines.some(line => (line.text || '').trim() !== '');
    if (!hasAnyContent) {
        showNotification('同期対象の歌詞行がありません。');
        hideNotification(2500);
        return;
    }

    isAutoSyncRunning = true;
    latestDetectedSegments = [];
    latestDetectedBy = '';
    closeDetectedPopup();
    updateDetectedPreviewUI();
    setAutoSyncButtonState(true);

    try {
        const payload = {
            songPath: currentEditorSong.path,
            lines: lyricsLines.map(line => line.text || ''),
            language: editorElements.languageSelect ? editorElements.languageSelect.value : 'auto',
            profile: 'fast',
        };

        const result = await lyricsAutoSync(payload);
        if (!result || result.success !== true) {
            applyDetectedPreview(result);
            showNotification(`自動同期に失敗しました: ${result?.error || '不明なエラー'}`);
            hideNotification(5000);
            return;
        }

        applyDetectedPreview(result);

        const alignedLines = Array.isArray(result.lines) ? result.lines : [];
        if (alignedLines.length === 0) {
            showNotification('自動同期結果が空でした。');
            hideNotification(3500);
            return;
        }

        for (const aligned of alignedLines) {
            if (!Number.isInteger(aligned?.index)) continue;
            if (aligned.index < 0 || aligned.index >= lyricsLines.length) continue;
            if (typeof aligned.timestamp !== 'number' || Number.isNaN(aligned.timestamp)) continue;
            lyricsLines[aligned.index].timestamp = normaliseTimestamp(aligned.timestamp);
        }

        saveHistory();
        redrawLyricsArea();

        if (activeLineIndex >= 0 && activeLineIndex < lyricsLines.length) {
            setActiveLine(activeLineIndex);
        } else if (lyricsLines.length > 0) {
            setActiveLine(0);
        }

        autoAdvanceArmed = false;
        lastTimestampedLineIndex = -1;
        updateUndoRedoButtons();

        const matchedCount = typeof result.matchedCount === 'number' ? result.matchedCount : 0;
        const detectedCount = latestDetectedSegments.length;
        showNotification(`自動同期が完了しました（一致: ${matchedCount}行 / 検知: ${detectedCount}件）`);
        hideNotification(3500);
    } catch (error) {
        console.error('[LRC Editor] Auto sync failed:', error);
        latestDetectedSegments = [];
        latestDetectedBy = '';
        updateDetectedPreviewUI();
        showNotification(`自動同期の実行中にエラーが発生しました: ${error?.message || String(error)}`);
        hideNotification(5000);
    } finally {
        isAutoSyncRunning = false;
        setAutoSyncButtonState(false);
    }
}

function setActiveLine(index, isManual = false, options = {}) {
    const {
        scrollLyric = true,
        scrollTimeline = true,
    } = options;

    if (index < 0 || index >= lyricsLines.length) return;

    activeLineIndex = index;

    if (isManual) {
        autoAdvanceArmed = false;
        lastTimestampedLineIndex = -1;
    }

    editorElements.lyricsArea.querySelectorAll('.lyrics-line.active').forEach(el => {
        el.classList.remove('active');
    });

    editorElements.timelineClips.querySelectorAll('.timeline-clip.active').forEach(el => {
        el.classList.remove('active');
    });

    editorElements.unassignedLines.querySelectorAll('.timeline-unassigned-item.active').forEach(el => {
        el.classList.remove('active');
    });

    const targetLine = editorElements.lyricsArea.querySelector(`.lyrics-line[data-index="${index}"]`);
    if (targetLine) {
        targetLine.classList.add('active');
        if (scrollLyric) {
            targetLine.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
    }

    const targetClip = editorElements.timelineClips.querySelector(`.timeline-clip[data-index="${index}"]`);
    if (targetClip) {
        targetClip.classList.add('active');
        if (scrollTimeline) {
            targetClip.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
        }
    }

    const targetUnassigned = editorElements.unassignedLines.querySelector(`.timeline-unassigned-item[data-index="${index}"]`);
    if (targetUnassigned) {
        targetUnassigned.classList.add('active');
    }
}

function moveActiveLine(step) {
    if (lyricsLines.length === 0) return;

    const currentIndex = activeLineIndex < 0 ? 0 : activeLineIndex;
    const nextIndex = Math.max(0, Math.min(lyricsLines.length - 1, currentIndex + step));
    setActiveLine(nextIndex, true);
}

function addTimestamp() {
    if (activeLineIndex === -1 || activeLineIndex >= lyricsLines.length || !currentEditorSong) return;

    const findNextStampableIndex = (startIndex) => {
        return startIndex < lyricsLines.length ? startIndex : -1;
    };

    let targetIndex = activeLineIndex;
    if (autoAdvanceArmed && lastTimestampedLineIndex === activeLineIndex) {
        const nextIndex = findNextStampableIndex(activeLineIndex + 1);
        if (nextIndex !== -1) {
            targetIndex = nextIndex;
        } else {
            showNotification('次にタイムスタンプを付ける行がありません。');
            hideNotification(2000);
        }
    }

    const currentTime = getCurrentTime();
    const timelineDuration = getTimelineDuration();
    const timestamp = normaliseTimestamp(clampTimestampForIndex(targetIndex, currentTime, timelineDuration));

    if (timestamp !== null) {
        lyricsLines[targetIndex].timestamp = timestamp;
    }

    redrawLyricsArea();
    setActiveLine(targetIndex);
    saveHistory();

    lastTimestampedLineIndex = targetIndex;
    autoAdvanceArmed = true;
    updateUndoRedoButtons();
}

function formatLrcTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '00:00.00';

    const min = Math.floor(seconds / 60).toString().padStart(2, '0');
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    const ms = Math.floor((seconds % 1) * 100).toString().padStart(2, '0');

    return `${min}:${sec}.${ms}`;
}

function handleEditorKeyDown(event) {
    if (event.target === editorElements.textarea) return;

    if ((event.metaKey || event.ctrlKey) && event.key === 'z') {
        event.preventDefault();
        undo();
        return;
    }

    if (event.key.toUpperCase() === 'T') {
        event.preventDefault();
        addTimestamp();
        return;
    }

    if (event.key.toUpperCase() === 'I') {
        event.preventDefault();
        insertInterludeLine();
        return;
    }

    if (event.key === 'ArrowUp') {
        event.preventDefault();
        moveActiveLine(-1);
        return;
    }

    if (event.key === 'ArrowDown') {
        event.preventDefault();
        moveActiveLine(1);
        return;
    }

    if (event.code === 'Space' && !(event.metaKey || event.ctrlKey || event.altKey || event.shiftKey)) {
        event.preventDefault();
        togglePlayPause();
    }
}

async function handleSaveLrc() {
    if (!currentEditorSong || lyricsLines.length === 0) return;

    const incompleteLine = lyricsLines.find(line => line.text.trim() !== '' && line.timestamp === null);
    if (incompleteLine) {
        const confirmSave = confirm('まだタイムスタンプが設定されていない行があります。このまま保存しますか？\n（タイムスタンプがない行はLRCファイルに含まれません）');
        if (!confirmSave) return;
    }

    const sortedLines = [...lyricsLines]
        .filter(line => typeof line.timestamp === 'number')
        .sort((a, b) => a.timestamp - b.timestamp);

    const bodyLines = sortedLines.map(line => `[${formatLrcTime(line.timestamp)}]${line.text}`);
    const lrcContent = [...lrcMetadataLines, ...bodyLines].join('\n');

    const baseName = getBasename(currentEditorSong.path).replace(getExtname(currentEditorSong.path), '');
    const lrcFileName = `${baseName}.lrc`;

    editorElements.saveBtn.disabled = true;
    editorElements.saveBtn.textContent = '保存中...';

    try {
        const result = await saveLrcFile({
            fileName: lrcFileName,
            content: lrcContent,
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

export function stopLrcEditing() {
    if (editorElements.view) {
        editorElements.view.removeEventListener('keydown', handleEditorKeyDown);
    }
    clearTimelineDragState();
    currentEditorSong = null;
    console.log('[LRC Editor] Editor stopped.');
}

export function updateLrcEditorControls(playing, currentTime, duration) {
    if (!editorElements.view || editorElements.view.classList.contains('hidden')) return;

    editorElements.playPauseBtn.classList.toggle('playing', playing);

    if (!isNaN(currentTime)) {
        editorElements.currentTime.textContent = formatEditorTime(currentTime);
        if (!editorIsSeeking) {
            editorElements.progressBar.value = currentTime;
        }
        updateTimelinePlayhead(currentTime);
    }

    if (!isNaN(duration)) {
        const formattedDuration = formatEditorTime(duration);
        if (editorElements.totalDuration.textContent !== formattedDuration) {
            editorElements.totalDuration.textContent = formattedDuration;
        }

        if (editorElements.progressBar.max != duration) {
            editorElements.progressBar.max = duration;
            renderTimeline();
        }
    }
}

function formatEditorTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';

    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}
