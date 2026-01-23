// src/sidecars/cd-rip/index.js
const { spawn, exec } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');
const https = require('https');
const readline = require('readline');
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPath = require('ffmpeg-static');

ffmpeg.setFfmpegPath(ffmpegPath);

// Utility: Sanitize filename
function sanitize(name) {
    if (typeof name !== 'string') return '_';
    let sanitizedName = name.replace(/[\\/:*?"<>|]/g, '_');
    sanitizedName = sanitizedName.replace(/[. ]+$/, '');
    return sanitizedName || '_';
}

// Configuration
let CDPARANOIA_PATH = path.join(__dirname, '../../main/bin/macos/cdparanoia');
let userDataPath = '';

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

rl.on('line', (line) => {
    try {
        const req = JSON.parse(line);
        handleRequest(req);
    } catch (e) {
        sendError(null, 'INVALID_JSON', e.message);
    }
});

async function handleRequest(req) {
    const { id, type, payload } = req;

    try {
        switch (type) {
            case 'init':
                userDataPath = payload.userDataPath;
                if (payload.cdparanoiaPath) CDPARANOIA_PATH = payload.cdparanoiaPath;
                sendResponse(id, 'init-success', { ok: true });
                break;

            case 'scan':
                const tracks = await getTrackList();
                sendResponse(id, 'scan-result', { success: true, tracks });
                break;

            case 'search-toc':
                const tocReleases = await searchByTOC(payload);
                sendResponse(id, 'search-result', { success: true, releases: tocReleases });
                break;

            case 'search-text':
                const textReleases = await searchByText(payload);
                sendResponse(id, 'search-result', { success: true, releases: textReleases });
                break;

            case 'apply-metadata':
                const metadataResult = await applyMetadata(payload);
                sendResponse(id, 'metadata-result', metadataResult);
                break;

            case 'start-rip':
                await startRip(id, payload);
                // Final response is sent inside startRip
                break;

            default:
                sendError(id, 'UNKNOWN_TYPE', `Unknown request type: ${type}`);
        }
    } catch (e) {
        sendError(id, 'EXECUTION_ERROR', e.message);
    }
}

function sendResponse(id, type, payload) {
    console.log(JSON.stringify({ id, type, payload }));
}

function sendError(id, code, message) {
    console.log(JSON.stringify({ id, error: message, code }));
}

function sendEvent(type, payload) {
    console.log(JSON.stringify({ type, payload, isEvent: true }));
}

// --- MusicBrainz API Helpers ---

function queryMusicBrainz(url) {
    return new Promise((resolve, reject) => {
        const client = url.startsWith('https') ? https : http;
        const options = {
            headers: { 'User-Agent': 'UXMusic/0.1.0 ( contact@example.com )' }
        };
        client.get(url, options, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                if (res.statusCode === 200) {
                    try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('Invalid JSON')); }
                } else if (res.statusCode === 404) {
                    resolve(null);
                } else {
                    resolve(null);
                }
            });
        }).on('error', reject);
    });
}

async function getCoverArtUrl(releaseId) {
    try {
        const data = await queryMusicBrainz(`https://coverartarchive.org/release/${releaseId}`);
        if (data && data.images) {
            const front = data.images.find(img => img.front) || data.images[0];
            return front ? front.image.replace(/^http:/, 'https:') : null;
        }
    } catch (e) { }
    return null;
}

// --- CD Operations ---

function getTrackList() {
    return new Promise((resolve) => {
        const child = spawn(CDPARANOIA_PATH, ['-Q']);
        let output = '';
        child.stderr.on('data', (data) => output += data.toString());
        child.stdout.on('data', (data) => output += data.toString());
        child.on('close', (code) => {
            const tracks = [];
            const lines = output.split('\n');
            const trackRegex = /^\s*(\d+)\.\s+(\d+)/;
            lines.forEach(line => {
                const match = line.match(trackRegex);
                if (match) {
                    tracks.push({
                        number: parseInt(match[1]),
                        title: `Track ${match[1]}`,
                        artist: 'Unknown Artist',
                        sectors: parseInt(match[2])
                    });
                }
            });
            resolve(tracks);
        });
    });
}

async function searchByTOC(tracks) {
    let currentOffset = 150;
    const offsets = [];
    tracks.forEach(t => {
        offsets.push(currentOffset);
        currentOffset += t.sectors;
    });
    const tocQuery = [1, tracks.length, currentOffset, ...offsets].join('+');
    const url = `https://musicbrainz.org/ws/2/discid/-?toc=${tocQuery}&fmt=json`;
    const data = await queryMusicBrainz(url);
    return data && data.releases ? data.releases : [];
}

async function searchByText(query) {
    const url = `https://musicbrainz.org/ws/2/release/?query=${encodeURIComponent(query)}&fmt=json&limit=15`;
    const data = await queryMusicBrainz(url);
    return data && data.releases ? data.releases : [];
}

async function applyMetadata({ tracks, releaseId }) {
    const detailUrl = `https://musicbrainz.org/ws/2/release/${releaseId}?inc=artist-credits+recordings&fmt=json`;
    const [release, artworkUrl] = await Promise.all([
        queryMusicBrainz(detailUrl),
        getCoverArtUrl(releaseId)
    ]);

    if (!release || !release.media || !release.media[0].tracks) {
        return { success: false, message: 'Invalid release data' };
    }

    const mbTracks = release.media[0].tracks;
    const albumTitle = release.title;
    const albumArtist = release['artist-credit']?.[0]?.name || 'Unknown Artist';

    const result = tracks.map((t, index) => {
        const mbTrack = mbTracks.find(m => parseInt(m.position) === t.number) || mbTracks[index];
        if (mbTrack) {
            return {
                ...t,
                title: mbTrack.title,
                artist: mbTrack.recording['artist-credit']?.[0]?.name || albumArtist,
                album: albumTitle
            };
        }
        return t;
    });

    return { success: true, tracks: result, album: albumTitle, artist: albumArtist, artwork: artworkUrl };
}

async function startRip(id, { tracksToRip, options, libraryPath }) {
    const outputDir = path.join(libraryPath, 'CD Rips');
    if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

    let tempArtworkPath = null;
    if (options.artworkUrl) {
        // Simple download for artwork
        tempArtworkPath = path.join(userDataPath, `temp_artwork_${Date.now()}.jpg`);
        await new Promise((resolve) => {
            const file = fs.createWriteStream(tempArtworkPath);
            https.get(options.artworkUrl, (res) => {
                res.pipe(file);
                file.on('finish', () => { file.close(); resolve(); });
            }).on('error', () => resolve());
        });
    }

    for (const track of tracksToRip) {
        try {
            await ripAndConvert(track, outputDir, options, tempArtworkPath);
            sendEvent('rip-progress', { status: 'completed', track: track.number });
        } catch (e) {
            sendEvent('rip-progress', { status: 'error', track: track.number, error: e.message });
        }
    }

    if (tempArtworkPath && fs.existsSync(tempArtworkPath)) fs.unlinkSync(tempArtworkPath);
    sendResponse(id, 'rip-complete', { count: tracksToRip.length, outputDir });
}

function ripAndConvert(track, outputDir, options, tempArtworkPath) {
    return new Promise(async (resolve, reject) => {
        const { number, title, artist, album } = track;
        const { format, bitrate } = options;
        const safeTitle = sanitize(title);
        const safeArtist = sanitize(artist);
        const tempWav = path.join(userDataPath, `rip_${Date.now()}_track${number}.wav`);
        const artistDir = path.join(outputDir, safeArtist);
        if (!fs.existsSync(artistDir)) fs.mkdirSync(artistDir, { recursive: true });

        const extMap = { flac: 'flac', wav: 'wav', mp3: 'mp3', aac: 'm4a', alac: 'm4a' };
        const ext = extMap[format] || 'm4a';
        const finalPath = path.join(artistDir, `${String(number).padStart(2, '0')} - ${safeTitle}.${ext}`);

        // 1. Rip to Wav
        sendEvent('rip-progress', { status: 'ripping', track: number, percent: 0 });
        const ripper = spawn(CDPARANOIA_PATH, ['-w', String(number), tempWav]);

        ripper.on('close', (code) => {
            if (code !== 0) return reject(new Error(`cdparanoia failed with code ${code}`));

            // 2. Encode
            sendEvent('rip-progress', { status: 'encoding', track: number });
            let command = ffmpeg(tempWav);

            if (format === 'flac') command.audioCodec('flac');
            else if (format === 'alac') command.audioCodec('alac');
            else if (format === 'wav') command.audioCodec('pcm_s16le');
            else if (format === 'mp3') command.audioCodec('libmp3lame').audioBitrate(bitrate || '320k');
            else if (format === 'aac') command.audioCodec('aac').audioBitrate(bitrate || '320k');

            command.outputOptions('-metadata', `title=${title}`, '-metadata', `artist=${artist}`, '-metadata', `album=${album}`, '-metadata', `track=${number}`);

            if (tempArtworkPath && format !== 'wav') {
                command.input(tempArtworkPath).outputOptions('-map', '0:0', '-map', '1:0', '-c:v', 'copy', '-disposition:v', 'attached_pic');
            }

            command.save(finalPath)
                .on('end', () => {
                    if (fs.existsSync(tempWav)) fs.unlinkSync(tempWav);
                    resolve();
                })
                .on('error', (err) => {
                    if (fs.existsSync(tempWav)) fs.unlinkSync(tempWav);
                    reject(err);
                });
        });
    });
}
