/**
 * history-analyzer.js
 * 再生履歴データを基に、パーソナライズされたプレイリストを生成する
 */

const PLAYLIST_SIZE = 20; // 各プレイリストの最大曲数

/**
 * 再生履歴からプレイリストを生成するメイン関数
 * @param {object} playCounts - playcounts.json の内容
 * @param {object[]} library - library.json の内容
 * @returns {object} - 生成されたプレイリストのオブジェクト
 */
function createHistoryPlaylists(playCounts, library) {
    if (!playCounts || Object.keys(playCounts).length === 0) {
        return {};
    }

    const now = new Date();
    const libraryMap = new Map(library.map(song => [song.path, song]));
    
    // 全ての曲の再生データをスコアリングしやすいように変換
    const allSongStats = Object.entries(playCounts).map(([path, data]) => {
        const song = libraryMap.get(path);
        if (!song) return null;
        
        return {
            song,
            count: data.count,
            // 履歴から最新の再生日時を取得（なければ大昔の日時）
            lastPlayed: data.history?.length ? new Date(data.history[data.history.length - 1]) : new Date(0),
            history: data.history?.map(iso => new Date(iso)) || []
        };
    }).filter(Boolean); // 曲が見つからなかったものは除外

    const playlists = {
        recent_favorites: createRecentFavorites(allSongStats, now),
        past_favorites: createPastFavorites(allSongStats, now),
        all_time_favorites: createAllTimeFavorites(allSongStats)
    };
    
    // 曲が1曲もないプレイリストは最終結果から除外する
    return Object.fromEntries(
        Object.entries(playlists).filter(([id, playlist]) => playlist.songs.length > 0)
    );
}

/**
 * 「最近のお気に入り」を生成
 * @param {object[]} allSongStats - 全曲の再生統計データ
 * @param {Date} now - 現在日時
 * @returns {{id: string, name: string, songs: object[]}}
 */
function createRecentFavorites(allSongStats, now) {
    const twoWeeksAgo = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000);

    const recentSongs = allSongStats
        .map(stats => {
            const recentPlays = stats.history.filter(d => d >= twoWeeksAgo).length;
            // 直近の再生回数を重視してスコアリング
            const score = recentPlays * 2 + stats.count * 0.5;
            return { ...stats, score };
        })
        .filter(stats => stats.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, PLAYLIST_SIZE);
        
    return {
        id: 'recent_favorites',
        name: '最近のお気に入り',
        songs: recentSongs.map(s => s.song)
    };
}

/**
 * 「ちょっと前のお気に入り」を生成
 * @param {object[]} allSongStats - 全曲の再生統計データ
 * @param {Date} now - 現在日時
 * @returns {{id: string, name: string, songs: object[]}}
 */
function createPastFavorites(allSongStats, now) {
    const twoWeeksAgo = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000);
    const threeMonthsAgo = new Date(now.getTime() - 90 * 24 * 60 * 60 * 1000);

    const pastSongs = allSongStats
        .map(stats => {
            const recentPlays = stats.history.filter(d => d >= twoWeeksAgo).length;
            const pastPlays = stats.history.filter(d => d < twoWeeksAgo && d >= threeMonthsAgo).length;
            
            // 最近は聴いていないが、少し前によく聴いた曲を評価
            const score = pastPlays - recentPlays * 2;
            return { ...stats, score };
        })
        .filter(stats => stats.score > 2) // スコアが一定以上のものに絞る
        .sort((a, b) => b.score - a.score)
        .slice(0, PLAYLIST_SIZE);
        
    return {
        id: 'past_favorites',
        name: 'ちょっと前のお気に入り',
        songs: pastSongs.map(s => s.song)
    };
}

/**
 * 「変わらない愛曲」を生成
 * @param {object[]} allSongStats - 全曲の再生統計データ
 * @returns {{id: string, name: string, songs: object[]}}
 */
function createAllTimeFavorites(allSongStats) {
    // 総再生回数が多い順にソート
    const timelessSongs = allSongStats
        .filter(stats => stats.count > 5) // 最低再生回数のフィルタ
        .sort((a, b) => b.count - a.count)
        .slice(0, PLAYLIST_SIZE);

    return {
        id: 'all_time_favorites',
        name: '変わらない愛曲',
        songs: timelessSongs.map(s => s.song)
    };
}


module.exports = { createHistoryPlaylists };