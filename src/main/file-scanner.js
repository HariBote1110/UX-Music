const path = require('path');
const fs = require('fs');

function sanitize(name) {
    if (typeof name !== 'string') return '_';
    let sanitizedName = name.replace(/[\\/:*?"<>|]/g, '_');
    sanitizedName = sanitizedName.replace(/[. ]+$/, '');
    return sanitizedName || '_';
}

const supportedExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a'];

async function scanDirectory(dirPath) {
    let files = [];
    const items = await fs.promises.readdir(dirPath, { withFileTypes: true });
    for (const item of items) {
        const fullPath = path.join(dirPath, item.name);
        if (item.isDirectory()) {
            files = files.concat(await scanDirectory(fullPath));
        } else if (supportedExtensions.includes(path.extname(item.name).toLowerCase())) {
            files.push(fullPath);
        }
    }
    return files;
}

async function parseFiles(filePaths) {
    const musicMetadata = await import('music-metadata');
    
    const songs = [];
    for (const filePath of filePaths) {
        try {
            const stats = fs.statSync(filePath);
            const metadata = await musicMetadata.parseFile(filePath);
            const common = metadata.common;
            let artwork = null;
            if (common.picture && common.picture.length > 0) {
                const pic = common.picture[0];
                if (pic.format) { 
                    artwork = `data:${pic.format};base64,${pic.data.toString('base64')}`;
                }
            }
            songs.push({
                path: filePath,
                title: common.title || path.basename(filePath),
                artist: common.artist || 'Unknown Artist',
                albumartist: common.albumartist,
                album: common.album || 'Unknown Album',
                artwork: artwork,
                duration: metadata.format.duration,
                year: common.year,
                fileSize: stats.size,
                type: 'local'
            });
        } catch (error) {
            console.error(`Error parsing metadata for ${filePath}:`, error.message);
        }
    }
    return songs;
}

async function scanPaths(paths) {
    let allFiles = [];
    for (const p of paths) {
        try {
            const stats = await fs.promises.stat(p);
            if (stats.isDirectory()) {
                allFiles = allFiles.concat(await scanDirectory(p));
            } else if (supportedExtensions.includes(path.extname(p).toLowerCase())) {
                allFiles.push(p);
            }
        } catch (error) {
            console.error(`Cannot access path ${p}:`, error.message);
        }
    }
    return allFiles;
}

module.exports = { scanPaths, parseFiles, sanitize };