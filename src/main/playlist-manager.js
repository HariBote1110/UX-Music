// uxmusic/src/main/playlist-manager.js

const path = require('path');
const fs = require('fs');
const { app } = require('electron');
const DataStore = require('./data-store');

const playlistsDir = path.join(app.getPath('userData'), 'Playlists');
const playlistOrderStore = new DataStore('playlist-order.json');

try {
    if (!fs.existsSync(playlistsDir)) {
        fs.mkdirSync(playlistsDir, { recursive: true });
        console.log(`[Playlist Manager] Created playlists directory at: ${playlistsDir}`);
    }
} catch (error) {
    console.error(`[Playlist Manager] Failed to create playlists directory on initial load:`, error);
}

function renamePlaylist(oldName, newName) {
    if (!oldName || !newName) {
        return { success: false, message: '名前が空です。' };
    }
    if (oldName === newName) {
        return { success: true };
    }

    const oldPath = path.join(playlistsDir, `${oldName}.m3u8`);
    const newPath = path.join(playlistsDir, `${newName}.m3u8`);

    if (!fs.existsSync(oldPath)) {
        return { success: false, message: '元のプレイリストが見つかりません。' };
    }
    if (fs.existsSync(newPath)) {
        return { success: false, message: 'その名前のプレイリストは既に存在します。' };
    }

    try {
        fs.renameSync(oldPath, newPath);
        const savedOrder = playlistOrderStore.load().order || [];
        const newOrder = savedOrder.map(name => (name === oldName ? newName : name));
        playlistOrderStore.save({ order: newOrder });
        return { success: true };
    } catch (error) {
        console.error(`Failed to rename playlist from ${oldName} to ${newName}:`, error);
        return { success: false, message: error.message };
    }
}

function getAllPlaylists() {
    try {
        const files = fs.readdirSync(playlistsDir);
        const playlistNames = files
            .filter(file => file.endsWith('.m3u8'))
            .map(file => path.basename(file, '.m3u8'));

        const savedOrder = playlistOrderStore.load().order || [];
        
        const orderedPlaylists = savedOrder.filter(name => playlistNames.includes(name));
        const newPlaylists = playlistNames.filter(name => !savedOrder.includes(name));
        
        return [...orderedPlaylists, ...newPlaylists.sort()];
    } catch (error) {
        console.error(`[Playlist Manager] Failed to get all playlists:`, error);
        return [];
    }
}

function createPlaylist(name) {
    if (!name) return { success: false, message: 'Playlist name is empty.' };
    const playlistPath = path.join(playlistsDir, `${name}.m3u8`);
    if (fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist already exists.' };
    }
    try {
        fs.writeFileSync(playlistPath, '#EXTM3U\n');
        return { success: true, name };
    } catch (error) {
        console.error('Failed to create playlist:', error);
        return { success: false, message: error.message };
    }
}

function deletePlaylist(name) {
    if (!name) return { success: false, message: 'Playlist name is empty.' };
    const playlistPath = path.join(playlistsDir, `${name}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.' };
    }
    try {
        fs.unlinkSync(playlistPath);
        const savedOrder = playlistOrderStore.load().order || [];
        const newOrder = savedOrder.filter(pName => pName !== name);
        playlistOrderStore.save({ order: newOrder });
        return { success: true };
    } catch (error) {
        console.error(`Failed to delete playlist ${name}:`, error);
        return { success: false, message: error.message };
    }
}

function addSongToPlaylist(playlistName, song) {
    if (!playlistName || !song || !song.path) return { success: false };

    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.' };
    }

    try {
        const duration = Math.round(song.duration || -1);
        const title = `${song.artist} - ${song.title}`;
        const extinf = `#EXTINF:${duration},${title}\n`;
        const songPathEntry = `${song.path}\n`;

        const content = fs.readFileSync(playlistPath, 'utf-8');
        if (content.includes(song.path)) {
            return { success: true, message: 'Song already in playlist.' };
        }

        fs.appendFileSync(playlistPath, extinf + songPathEntry);
        return { success: true };
    } catch (error) {
        console.error(`Failed to add song to ${playlistName}:`, error);
        return { success: false, message: error.message };
    }
}

// ▼▼▼ ここからが修正箇所です ▼▼▼
/**
 * 複数の曲をプレイリストに追加する
 * @param {string} playlistName - プレイリスト名
 * @param {Array<object>} songs - 追加する曲オブジェクトの配列
 * @returns {object} - { success: boolean, addedCount: number }
 */
function addSongsToPlaylist(playlistName, songs) {
    if (!playlistName || !Array.isArray(songs) || songs.length === 0) {
        return { success: false, addedCount: 0 };
    }

    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.', addedCount: 0 };
    }

    try {
        const content = fs.readFileSync(playlistPath, 'utf-8');
        let newContent = '';
        let addedCount = 0;

        songs.forEach(song => {
            if (song && song.path && !content.includes(song.path)) {
                const duration = Math.round(song.duration || -1);
                const title = `${song.artist} - ${song.title}`;
                const extinf = `#EXTINF:${duration},${title}\n`;
                const songPathEntry = `${song.path}\n`;
                newContent += extinf + songPathEntry;
                addedCount++;
            }
        });

        if (addedCount > 0) {
            fs.appendFileSync(playlistPath, newContent);
        }

        return { success: true, addedCount };
    } catch (error) {
        console.error(`Failed to add songs to ${playlistName}:`, error);
        return { success: false, message: error.message, addedCount: 0 };
    }
}
// ▲▲▲ ここまでが修正箇所です ▲▲▲

function getPlaylistSongs(playlistName) {
    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        console.error(`Playlist file not found: ${playlistPath}`);
        return [];
    }

    try {
        const content = fs.readFileSync(playlistPath, 'utf-8');
        const lines = content.split('\n');
        const songPaths = lines.filter(line => line.trim() !== '' && !line.startsWith('#'));
        return songPaths;
    } catch (error) {
        console.error(`Failed to read playlist ${playlistName}:`, error);
        return [];
    }
}

function removeSongFromPlaylist(playlistName, songPathToRemove) {
    if (!playlistName || !songPathToRemove) return { success: false };

    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.' };
    }

    try {
        const content = fs.readFileSync(playlistPath, 'utf-8');
        const lines = content.split('\n');
        const newLines = [];
        let songIndex = -1;

        lines.forEach((line, index) => {
            if (line.trim() === songPathToRemove.trim()) {
                songIndex = index;
            }
        });

        if (songIndex > -1) {
            for (let i = 0; i < lines.length; i++) {
                if (i !== songIndex && i !== songIndex - 1) {
                    newLines.push(lines[i]);
                }
            }
            fs.writeFileSync(playlistPath, newLines.join('\n'));
            return { success: true };
        } else {
            return { success: false, message: 'Song not found in playlist.' };
        }
    } catch (error) {
        console.error(`Failed to remove song from ${playlistName}:`, error);
        return { success: false, message: error.message };
    }
}

function updateSongOrderInPlaylist(playlistName, newSongPaths) {
    if (!playlistName || !Array.isArray(newSongPaths)) return { success: false };

    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.' };
    }

    try {
        const content = fs.readFileSync(playlistPath, 'utf-8');
        const lines = content.split('\n');
        
        const songInfoMap = new Map();
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].startsWith('#EXTINF')) {
                const pathLine = lines[i + 1];
                if (pathLine && pathLine.trim() !== '') {
                    songInfoMap.set(pathLine.trim(), lines[i]);
                }
            }
        }

        let newContent = '#EXTM3U\n';
        newSongPaths.forEach(songPath => {
            const extinf = songInfoMap.get(songPath.trim());
            if (extinf) {
                newContent += `${extinf}\n${songPath}\n`;
            }
        });

        fs.writeFileSync(playlistPath, newContent);
        return { success: true };

    } catch (error) {
        console.error(`Failed to update song order in ${playlistName}:`, error);
        return { success: false, message: error.message };
    }
}

module.exports = {
    getAllPlaylists,
    createPlaylist,
    getPlaylistSongs,
    addSongToPlaylist,
    addSongsToPlaylist, // ▼▼▼ 修正点: エクスポートに追加 ▼▼▼
    removeSongFromPlaylist,
    deletePlaylist,
    updateSongOrderInPlaylist,
    renamePlaylist,
};