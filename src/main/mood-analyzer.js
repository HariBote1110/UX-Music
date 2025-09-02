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
 * 1曲を分析して、合致するシチュエーションのIDを返す (減点ロジック対応版)
 * @param {object} song - 曲オブジェクト
 * @param {object[]} activePatterns - 現在有効なパターン
 * @returns {string[]} - 合致したパターンのIDの配列
 */
function analyzeSong(song, activePatterns) {
    if (!song || activePatterns.length === 0) return [];

    const matchedIds = new Set();
    const songTitleLower = (song.title || '').toLowerCase();
    const songGenreLower = (song.genre || '').toLowerCase();

    activePatterns.forEach(pattern => {
        let totalScore = 0;
        const requiredComponentsFound = new Set();

        // 加算スコアの計算
        if (pattern.components) {
            for (const compKey in pattern.components) {
                const component = pattern.components[compKey];
                let componentMatched = false;

                if (compKey === 'bpm' && component.bpm_range && typeof song.bpm === 'number') {
                    if (song.bpm >= component.bpm_range[0] && song.bpm <= component.bpm_range[1]) {
                        componentMatched = true;
                    }
                } else if (compKey === 'title' && component.phrases?.length) {
                    if (component.phrases.some(phrase => songTitleLower.includes(phrase.toLowerCase()))) {
                        componentMatched = true;
                    }
                } else if (compKey === 'genre' && component.phrases?.length && songGenreLower) {
                    if (component.phrases.some(phrase => songGenreLower.includes(phrase.toLowerCase()))) {
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
        
        // 減点スコアの計算
        if (pattern.exclude) {
            for (const compKey in pattern.exclude) {
                const component = pattern.exclude[compKey];
                if (compKey === 'title' && component.phrases?.length) {
                    if (component.phrases.some(phrase => songTitleLower.includes(phrase.toLowerCase()))) {
                        totalScore += component.score || 0; // スコアは負の値のはず
                    }
                }
            }
        }

        const meetsRequired = !pattern.required || pattern.required.length === requiredComponentsFound.size;

        if (meetsRequired && totalScore >= (pattern.minScore || 1)) {
            matchedIds.add(pattern.id);
        }
    });

    return [...matchedIds];
}

/**
 * ライブラリ全体を分析し、現在時刻・季節に合ったプレイリストを作成する
 * @param {object[]} library - ライブラリの全曲
 * @returns {object}
 */
function createSituationPlaylists(library) {
    loadPatterns();

    const now = new Date();
    const currentTime = now.toTimeString().slice(0, 5); // "HH:MM"
    const currentDate = (now.getMonth() + 1).toString().padStart(2, '0') + '-' + now.getDate().toString().padStart(2, '0'); // "MM-DD"
    
    // 現在の時刻と季節に合致するパターン、または時間・季節指定のないパターンを抽出
    const activePatterns = moodPatterns.filter(p => {
        const isTimeMatch = !p.time_range || (currentTime >= p.time_range[0] && currentTime <= p.time_range[1]);
        const isDateMatch = !p.date_range || (currentDate >= p.date_range[0] && currentDate <= p.date_range[1]);
        
        // 時間も季節も指定がないパターンは常に有効
        if (!p.time_range && !p.date_range) return true;
        // 時間または季節のどちらかが指定されていて、それがマッチすれば有効
        return isTimeMatch && isDateMatch;
    });

    console.log(`[Mood Analyzer] ${activePatterns.length} active patterns for current time/season.`);

    const situationMap = {};
    activePatterns.forEach(p => {
        situationMap[p.id] = { id: p.id, name: p.name, songs: [] };
    });

    library.forEach(song => {
        const situations = analyzeSong(song, activePatterns);
        situations.forEach(situationId => {
            if (situationMap[situationId]) {
                situationMap[situationId].songs.push(song);
            }
        });
    });

    return Object.fromEntries(
      Object.entries(situationMap).filter(([id, playlist]) => playlist.songs.length > 0)
    );
}

module.exports = { createSituationPlaylists };