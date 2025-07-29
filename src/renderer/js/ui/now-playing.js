import { elements } from '../state.js';
import { setEqualizerColorFromArtwork } from '../player.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let artworksDir = null;

// アートワークのパスを解決するヘルパー関数
async function resolveArtworkPath(artworkFileName) {
    if (!artworkFileName) return './assets/default_artwork.png';
    if (artworkFileName.startsWith('data:image')) return artworkFileName;
    if (artworkFileName.startsWith('http')) return artworkFileName;
    
    if (!artworksDir) {
        artworksDir = await ipcRenderer.invoke('get-artworks-dir');
    }
    return `file://${path.join(artworksDir, artworkFileName)}`;
}

// DOM要素の表示を切り替えるヘルパー関数
function switchVisibleElement(container, elementToShow) {
    // コンテナ内のすべての子要素を非表示にする
    for (const child of container.children) {
        child.style.display = 'none';
    }
    // 指定された要素だけを表示する
    if (elementToShow) {
        elementToShow.style.display = 'block';
    }
}

// updateNowPlayingView関数
export async function updateNowPlayingView(song) {
    const { 
        nowPlayingArtworkContainer, 
        nowPlayingTitle, 
        nowPlayingArtist,
        hubLinkContainer 
    } = elements;
    
    // プレーヤー要素とアートワーク用img要素への参照を取得
    const localPlayer = document.getElementById('main-player');
    const ytPlayerWrapper = document.getElementById('youtube-player-container');
    
    // アートワーク用img要素がなければ作成してコンテナに追加
    let artworkImg = nowPlayingArtworkContainer.querySelector('img');
    if (!artworkImg) {
        artworkImg = document.createElement('img');
        nowPlayingArtworkContainer.appendChild(artworkImg);
    }
    
    // ちらつき（FOUC）を防ぐため、srcをセットする前に一旦画像を非表示にする
    artworkImg.style.display = 'none';

    // ハブリンクコンテナをクリア
    hubLinkContainer.innerHTML = '';
    
    // --- 曲のタイプに応じて表示を切り替え ---

    // 曲情報がない場合
    if (!song) {
        nowPlayingArtworkContainer.classList.remove('video-mode');
        switchVisibleElement(nowPlayingArtworkContainer, artworkImg);
        artworkImg.src = './assets/default_artwork.png';
        
    // YouTubeストリーミングの場合
    } else if (song.type === 'youtube') {
        nowPlayingArtworkContainer.classList.add('video-mode');
        switchVisibleElement(nowPlayingArtworkContainer, ytPlayerWrapper);
        // YouTubeのサムネイルを裏で読み込み、色抽出に使用
        artworkImg.src = song.artwork;

    // ローカルの映像ファイルの場合
    } else if (song.hasVideo) {
        nowPlayingArtworkContainer.classList.add('video-mode');
        switchVisibleElement(nowPlayingArtworkContainer, localPlayer);
        // 映像ファイルのアートワークメタデータを色抽出に使用
        artworkImg.src = await resolveArtworkPath(song.artwork);

    // 通常のローカル音声ファイルの場合
    } else {
        nowPlayingArtworkContainer.classList.remove('video-mode');
        switchVisibleElement(nowPlayingArtworkContainer, artworkImg);
        artworkImg.src = await resolveArtworkPath(song.artwork);
    }

    // --- 色の設定とUI更新 ---

    // 画像の読み込み完了を待って色を設定するイベントリスナー
    const onArtworkLoad = () => {
        setEqualizerColorFromArtwork();
        // イベントリスナーを一度実行したら削除してメモリリークを防ぐ
        artworkImg.removeEventListener('load', onArtworkLoad);
    };
    artworkImg.addEventListener('load', onArtworkLoad);

    // ブラウザにキャッシュされている場合は 'load' イベントが発火しないことがあるため、手動で呼び出し
    if (artworkImg.complete && artworkImg.src) {
       onArtworkLoad();
    }
    
    // ハブリンクボタンの表示
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    // タイトルとアーティスト名の表示更新
    const titleSpan = nowPlayingTitle.querySelector('.marquee-content span');
    if (titleSpan) {
        titleSpan.textContent = song ? song.title : '曲を選択してください';
    }

    const artistSpan = nowPlayingArtist.querySelector('.marquee-content span');
    if (artistSpan) {
        artistSpan.textContent = song ? song.artist : '';
    }
}