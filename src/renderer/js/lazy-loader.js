let observer;

const LAZY_LOAD_OFFSET = '200px'; // 画面に入る200px手前から読み込みを開始

/**
 * IntersectionObserverを初期化します。
 * @param {HTMLElement} root - スクロールイベントのルート要素 (例: .main-content)
 */
export function initLazyLoader(root) {
    if (observer) {
        observer.disconnect(); // 既存のObserverがあれば切断
    }

    const options = {
        root: root,
        rootMargin: `0px 0px ${LAZY_LOAD_OFFSET} 0px`,
        threshold: 0
    };

    observer = new IntersectionObserver((entries, self) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const img = entry.target;
                const src = img.dataset.src;
                if (src) {
                    img.src = src;
                }
                img.classList.remove('lazy-load');
                // 一度読み込んだ要素は監視対象から外す
                self.unobserve(img);
            }
        });
    }, options);
}

/**
 * 新しく追加された遅延読み込み対象の画像を監視します。
 * @param {HTMLElement} container - 監視対象の画像を含む親要素
 */
export function observeNewImages(container) {
    if (!observer) {
        console.error('Lazy loader is not initialized.');
        return;
    }
    const images = container.querySelectorAll('img.lazy-load');
    images.forEach(img => observer.observe(img));
}