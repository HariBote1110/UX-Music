// このモジュールは、現在再生すべきYouTubeのURLを一時的に保持する役割だけを持つ

let currentUrl = '';

function setUrl(url) {
    currentUrl = url;
}

function getUrl() {
    return currentUrl;
}

// 他のファイルから setUrl と getUrl を使えるようにする
module.exports = {
    setUrl,
    getUrl
};