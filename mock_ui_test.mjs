import fs from 'fs';

function assert(condition, message) {
    if (!condition) {
        console.error('FAIL: ' + message);
        process.exit(1);
    }
}

const html = fs.readFileSync('MusicCenterhommagesample.html', 'utf8');

console.log('Running UI Structure Tests...');

// 1. 再生コントロールがサイドバー領域（またはトップバー以外）に移動しているか
// 現状のHTMLでは、トップヘッダー <header> の中に id="btn-play" などがある。
// 修正後は <aside> の中、あるいはそれに準ずるサイドバーのトップ領域に配置されるべき。
const headerMatch = html.match(/<header[^>]*>([\s\S]*?)<\/header>/i);
const asideMatch = html.match(/<aside[^>]*>([\s\S]*?)<\/aside>/i);

if (headerMatch && asideMatch) {
    const headerContent = headerMatch[1];
    const asideContent = asideMatch[1];

    assert(
        !headerContent.includes('id="btn-play"'),
        'Playback controls (btn-play) should NOT be in the top header'
    );
    assert(
        asideContent.includes('id="btn-play"'),
        'Playback controls (btn-play) should be in the sidebar (aside)'
    );
} else {
    assert(false, 'Header or Aside tags not found');
}

// 2. プレイリストビューとアルバムビューに、ソート用のテーブルヘッダ領域が存在するか
const playlistViewMatch = html.match(/<div id="view-playlists-container"[^>]*>([\s\S]*?)<div id="playlists-grid"/i);
const albumViewMatch = html.match(/<div id="view-albums-container"[^>]*>([\s\S]*?)<div id="albums-grid"/i);

assert(
    playlistViewMatch && playlistViewMatch[1].includes('class="w-full text-left text-xs border-collapse'),
    'Playlist view must contain a sort header table structure'
);

assert(
    albumViewMatch && albumViewMatch[1].includes('class="w-full text-left text-xs border-collapse'),
    'Album view must contain a sort header table structure'
);

console.log('All tests passed!');
process.exit(0);
