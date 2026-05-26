import fs from 'fs';

function assert(condition, message) {
    if (!condition) {
        console.error('FAIL: ' + message);
        process.exit(1);
    }
}

const html = fs.readFileSync('MusicCenterhommagesample.html', 'utf8');

console.log('Running UI Structure Tests...');

// 1. 再生コントロール（btn-play等）がasideではなくheaderに存在するか
const headerMatch = html.match(/<header[^>]*>([\s\S]*?)<\/header>/i);
const asideMatch = html.match(/<aside[^>]*>([\s\S]*?)<\/aside>/i);

if (headerMatch && asideMatch) {
    const headerContent = headerMatch[1];
    const asideContent = asideMatch[1];

    assert(
        headerContent.includes('id="btn-play"') && headerContent.includes('id="btn-next"'),
        'Play controls must be placed inside the header, not in the sidebar'
    );
    assert(
        !asideContent.includes('id="btn-play"'),
        'Play controls must NOT be in the sidebar'
    );
} else {
    assert(false, 'Header or Aside tags not found');
}

// 2. テーブル（ソートヘッダ）が左右の余白を持たずに広がる構造になっているか
const playlistViewMatch = html.match(/<div id="view-playlists-container"[^>]*>([\s\S]*?)<div id="playlists-grid"/i);
const albumViewMatch = html.match(/<div id="view-albums-container"[^>]*>([\s\S]*?)<div id="albums-grid"/i);

assert(
    playlistViewMatch && !playlistViewMatch[0].includes('px-8') && playlistViewMatch[1].includes('class="w-full text-left text-xs border-collapse'),
    'Playlist view container should NOT have px-8 padding, and must contain the sort header table'
);

assert(
    albumViewMatch && !albumViewMatch[0].includes('px-8') && albumViewMatch[1].includes('class="w-full text-left text-xs border-collapse'),
    'Album view container should NOT have px-8 padding, and must contain the sort header table'
);

// 3. タイトルと件数・新規作成ボタンの縦並び/配置構造
const mainHeaderMatch = html.match(/<div id="view-title-area"[^>]*>([\s\S]*?)<\/div>/i);
assert(
    html.includes('id="view-title-area"'),
    'Should have a designated view-title-area for vertical layout of title and count'
);

console.log('All tests passed!');
process.exit(0);
