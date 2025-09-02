const fs = require('fs');
const path = require('path');

let moodPatterns = [];
let patternsLoaded = false;

function loadPatterns() {
    if (patternsLoaded) return;
    try {
        const patternsPath = path.join(__dirname, 'mood-patterns.json');
        if (fs.existsSync(patternsPath)) {
            moodPatterns = JSON.parse(fs.readFileSync(patternsPath, 'utf-8'));
            console.log(`[Mood Analyzer] Loaded ${moodPatterns.length} mood patterns.`);
        } else {
            console.warn('[Mood Analyzer] mood-patterns.json not found.');
        }
    } catch (error) {
        console.error('[Mood Analyzer] Failed to load mood patterns:', error);
    }
    patternsLoaded = true;
}

/**
 * 1曲を分析して、合致するシチュエーションのIDを返す (XS-Blockerロジック版)
 * @param {object} song - 曲オブジェクト (bpm, title を含む)
 * @returns {string[]} - 合致したパターンのIDの配列
 */
function analyzeSong(song) {
    if (!song || moodPatterns.length === 0) return [];

    const matchedIds = new Set();
    const songTitleLower = (song.title || '').toLowerCase();

    moodPatterns.forEach(pattern => {
        let totalScore = 0;
        const requiredComponentsFound = new Set();

        if (pattern.components) {
            for (const compKey in pattern.components) {
                const component = pattern.components[compKey];
                let componentMatched = false;

                // BPMコンポーネントの判定
                if (compKey === 'bpm' && component.bpm_range && typeof song.bpm === 'number') {
                    if (song.bpm >= component.bpm_range[0] && song.bpm <= component.bpm_range[1]) {
                        componentMatched = true;
                    }
                }
                // タイトルキーワードの判定
                else if (compKey === 'title' && component.phrases?.length) {
                    if (component.phrases.some(phrase => songTitleLower.includes(phrase.toLowerCase()))) {
                        componentMatched = true;
                    }
                }

                if (componentMatched) {
                    totalScore += component.score || 0;
                    if (pattern.required?.includes(compKey)) {
                        requiredComponentsFound.add(compKey);
                    }
                }
            }
        }

        // 必須コンポーネントの条件をチェック
        const meetsRequired = !pattern.required || pattern.required.length === requiredComponentsFound.size;

        // 最終スコアが閾値を超えているかチェック
        if (meetsRequired && totalScore >= (pattern.minScore || 1)) {
            matchedIds.add(pattern.id);
        }
    });

    return [...matchedIds];
}

/**
 * ライブラリ全体を分析し、シチュエーションごとの曲リストを作成する
 * @param {object[]} library - ライブラリの全曲
 * @returns {object} - { morning_chill: { id: "...", name: "...", songs: [...] }, ... }
 */
function createSituationPlaylists(library) {
    loadPatterns();

    const situationMap = {};
    moodPatterns.forEach(p => {
        situationMap[p.id] = { id: p.id, name: p.name, songs: [] };
    });

    library.forEach(song => {
        const situations = analyzeSong(song);
        situations.forEach(situationId => {
            if (situationMap[situationId]) {
                situationMap[situationId].songs.push(song);
            }
        });
    });

    // 曲が1曲もないプレイリストは除外する
    return Object.fromEntries(
      Object.entries(situationMap).filter(([id, playlist]) => playlist.songs.length > 0)
    );
}

module.exports = { createSituationPlaylists };