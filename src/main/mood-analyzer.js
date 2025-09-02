// src/main/mood-analyzer.js

const fs = require('fs');
const path = require('path');

let moodPatterns = [];
// ▼▼▼ 修正点: パターンが読み込まれたかどうかのフラグを追加 ▼▼▼
let patternsLoaded = false;

function loadPatterns() {
    // ▼▼▼ 修正点: 既に読み込み済みの場合は何もしない ▼▼▼
    if (patternsLoaded) return;

    try {
        const patternsPath = path.join(__dirname, 'mood-patterns.json');
        if (fs.existsSync(patternsPath)) {
            const rawData = fs.readFileSync(patternsPath);
            moodPatterns = JSON.parse(rawData);
            console.log(`[Mood Analyzer] Loaded ${moodPatterns.length} mood patterns.`);
        } else {
            console.warn('[Mood Analyzer] mood-patterns.json not found. Situation playlists will be empty.');
            moodPatterns = [];
        }
    } catch (error) {
        console.error('[Mood Analyzer] Failed to load or parse mood patterns:', error);
        moodPatterns = [];
    }
    // ▼▼▼ 修正点: 読み込み完了フラグを立てる ▼▼▼
    patternsLoaded = true;
}

/**
 * 1曲を分析して、合致するシチュエーションのIDを返す
 * @param {object} song - 曲オブジェクト (BPM, title を含む)
 * @returns {string[]} - 合致したパターンのIDの配列 (例: ["workout", "night_drive"])
 */
function analyzeSong(song) {
    if (!song || moodPatterns.length === 0) return [];

    const matchedIds = new Set();
    const songTitleLower = song.title ? song.title.toLowerCase() : '';

    for (const pattern of moodPatterns) {
        let matched = false;
        
        if (pattern.bpm_range && song.bpm) {
            if (song.bpm >= pattern.bpm_range[0] && song.bpm <= pattern.bpm_range[1]) {
                matched = true;
            }
        }
        
        if (!matched && pattern.title_phrases) {
            if (pattern.title_phrases.some(phrase => songTitleLower.includes(phrase))) {
                matched = true;
            }
        }

        if (matched) {
            matchedIds.add(pattern.id);
        }
    }
    return [...matchedIds];
}

/**
 * ライブラリ全体を分析し、シチュエーションごとの曲リストを作成する
 * @param {object[]} library - ライブラリの全曲
 * @returns {object} - { morning: { name: "...", songs: [...] }, ... }
 */
function createSituationPlaylists(library) {
    loadPatterns(); // ▼▼▼ 修正点: 呼び出された時に初めてパターンを読み込む ▼▼▼

    const situationMap = {};
    for (const pattern of moodPatterns) {
        situationMap[pattern.id] = {
            name: pattern.name,
            songs: []
        };
    }

    for (const song of library) {
        const situations = analyzeSong(song);
        for (const situationId of situations) {
            if (situationMap[situationId]) {
                situationMap[situationId].songs.push(song);
            }
        }
    }
    
    const filteredSituationMap = Object.entries(situationMap)
        .filter(([id, playlist]) => playlist.songs.length > 0)
        .reduce((acc, [id, playlist]) => {
            acc[id] = playlist;
            return acc;
        }, {});
        
    return filteredSituationMap;
}

// ▼▼▼ 修正点: モジュール読み込み時の直接呼び出しを削除 ▼▼▼
// loadPatterns();

module.exports = { createSituationPlaylists, getMoodPatterns: () => moodPatterns };