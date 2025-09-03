const fs = require('fs');
const path = require('path');

let moodPatterns = [];
let patternsLoaded = false;

function loadPatterns() {
    if (patternsLoaded) return;
    try {
        const patternsPath = path.join(__dirname, 'mood-patterns.json');
        moodPatterns = JSON.parse(fs.readFileSync(patternsPath, 'utf-8'));
    } catch (error) {
        console.error('[Mood Analyzer] Failed to load mood patterns:', error);
    }
    patternsLoaded = true;
}

function analyzeSong(song, activePatterns) {
    if (!song || activePatterns.length === 0) return [];
    const matchedIds = new Set();
    const songTitleLower = (song.title || '').toLowerCase();
    const songGenreLower = (song.genre || '').toLowerCase();

    activePatterns.forEach(pattern => {
        let totalScore = 0;
        const requiredComponentsFound = new Set();

        const components = { ...pattern.components, ...pattern.exclude };

        for (const compKey in components) {
            const component = components[compKey];
            let componentMatched = false;

            if (compKey === 'bpm' && component.bpm_range && typeof song.bpm === 'number') {
                if (song.bpm >= component.bpm_range[0] && song.bpm <= component.bpm_range[1]) componentMatched = true;
            } else if (compKey === 'title' && component.phrases?.length) {
                if (component.phrases.some(p => songTitleLower.includes(p.toLowerCase()))) componentMatched = true;
            } else if (compKey === 'genre' && component.phrases?.length && songGenreLower) {
                if (component.phrases.some(p => songGenreLower.includes(p.toLowerCase()))) componentMatched = true;
            } else if (compKey === 'energy' && component.energy_range && typeof song.energy === 'number') {
                if (song.energy >= component.energy_range[0] && song.energy <= component.energy_range[1]) componentMatched = true;
            }

            if (componentMatched) {
                totalScore += component.score || 0;
                if (pattern.required?.includes(compKey)) requiredComponentsFound.add(compKey);
            }
        }

        const meetsRequired = !pattern.required || pattern.required.length === requiredComponentsFound.size;
        if (meetsRequired && totalScore >= (pattern.minScore || 1)) {
            matchedIds.add(pattern.id);
        }
    });
    return [...matchedIds];
}

function createSituationPlaylists(library) {
    loadPatterns();
    const now = new Date();
    const currentTime = now.toTimeString().slice(0, 5);
    const currentDate = (now.getMonth() + 1).toString().padStart(2, '0') + '-' + now.getDate().toString().padStart(2, '0');
    
    const activePatterns = moodPatterns.filter(p => {
        const isTimeMatch = !p.time_range || (p.time_range[0] > p.time_range[1] ? (currentTime >= p.time_range[0] || currentTime <= p.time_range[1]) : (currentTime >= p.time_range[0] && currentTime <= p.time_range[1]));
        const isDateMatch = !p.date_range || (p.date_range[0] > p.date_range[1] ? (currentDate >= p.date_range[0] || currentDate <= p.date_range[1]) : (currentDate >= p.date_range[0] && currentDate <= p.date_range[1]));
        return (!p.time_range && !p.date_range) || (isTimeMatch && isDateMatch);
    });

    const situationMap = {};
    activePatterns.forEach(p => {
        situationMap[p.id] = { id: p.id, name: p.name, songs: [] };
    });

    library.forEach(song => {
        const situations = analyzeSong(song, activePatterns);
        situations.forEach(id => situationMap[id]?.songs.push(song));
    });

    return Object.fromEntries(Object.entries(situationMap).filter(([_, p]) => p.songs.length > 0));
}

module.exports = { createSituationPlaylists };