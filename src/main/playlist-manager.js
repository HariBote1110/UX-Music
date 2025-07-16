const path = require('path');
const fs = require('fs');
const { app } = require('electron');

const playlistsDir = path.join(app.getPath('userData'), 'Playlists');

if (!fs.existsSync(playlistsDir)) {
    fs.mkdirSync(playlistsDir, { recursive: true });
}

function getAllPlaylists() {
    const files = fs.readdirSync(playlistsDir);
    return files
        .filter(file => file.endsWith('.m3u8'))
        .map(file => path.basename(file, '.m3u8'));
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

// ★★★ この関数に処理を実装 ★★★
function addSongToPlaylist(playlistName, song) {
    if (!playlistName || !song || !song.path) return { success: false };

    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        return { success: false, message: 'Playlist not found.' };
    }

    try {
        // m3u8形式のメタ情報行を作成
        const duration = Math.round(song.duration || -1);
        const title = `${song.artist} - ${song.title}`;
        const extinf = `#EXTINF:${duration},${title}\n`;
        const songPathEntry = `${song.path}\n`;

        // 既存のファイル内容を読み込み、既に追加済みかチェック
        const content = fs.readFileSync(playlistPath, 'utf-8');
        if (content.includes(song.path)) {
            return { success: true, message: 'Song already in playlist.' };
        }

        // ファイルの末尾に追記
        fs.appendFileSync(playlistPath, extinf + songPathEntry);
        return { success: true };
    } catch (error) {
        console.error(`Failed to add song to ${playlistName}:`, error);
        return { success: false, message: error.message };
    }
}

// ★★★ この関数に処理を実装 ★★★
function getPlaylistSongs(playlistName) {
    const playlistPath = path.join(playlistsDir, `${playlistName}.m3u8`);
    if (!fs.existsSync(playlistPath)) {
        console.error(`Playlist file not found: ${playlistPath}`);
        return [];
    }

    try {
        const content = fs.readFileSync(playlistPath, 'utf-8');
        const lines = content.split('\n');

        // #で始まる行と空行を除外し、ファイルのフルパスだけを抽出する
        const songPaths = lines.filter(line => line.trim() !== '' && !line.startsWith('#'));
        
        return songPaths;
    } catch (error) {
        console.error(`Failed to read playlist ${playlistName}:`, error);
        return [];
    }
}

// ★★★ 以下の関数をファイル末尾に追加 ★★★
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

        // 削除対象の曲のパスが何行目にあるかを探す
        lines.forEach((line, index) => {
            if (line.trim() === songPathToRemove.trim()) {
                songIndex = index;
            }
        });

        if (songIndex > -1) {
            // 曲のパスとその直前の情報行(#EXTINF)を除外して新しい配列を作成
            for (let i = 0; i < lines.length; i++) {
                // songIndex(パスの行) と songIndex-1(情報行) 以外を newLines に追加
                if (i !== songIndex && i !== songIndex - 1) {
                    newLines.push(lines[i]);
                }
            }
            // 新しい内容でファイルを上書き
            fs.writeFileSync(playlistPath, newLines.join('\n'));
            return { success: true };
        } else {
            // 曲が見つからなかった場合
            return { success: false, message: 'Song not found in playlist.' };
        }
    } catch (error) {
        console.error(`Failed to remove song from ${playlistName}:`, error);
        return { success: false, message: error.message };
    }
}

module.exports = {
    getAllPlaylists,
    createPlaylist,
    getPlaylistSongs,
    addSongToPlaylist,
    removeSongFromPlaylist // ★★★ エクスポートに追加 ★★★
};