/**
 * 指定されたコンポーネントファイルを読み込み、ターゲット要素に挿入します。
 * @param {string} targetId - 挿入先の親要素のID
 * @param {string} filePath - HTMLファイルのパス
 */
async function loadComponent(targetId, filePath) {
    try {
        const response = await fetch(filePath);
        if (!response.ok) throw new Error(`Failed to load ${filePath}`);
        const html = await response.text();
        const targetElement = document.getElementById(targetId);
        if (targetElement) {
            targetElement.innerHTML = html;
        } else {
            console.error(`Target element #${targetId} not found.`);
        }
    } catch (error) {
        console.error(`Error loading component ${filePath}:`, error);
    }
}

/**
 * 全ての分割されたビューコンポーネントを読み込みます。
 */
export async function loadAllComponents() {
    const components = [
        { id: 'lrc-editor-view', path: './components/lrc-editor.html' },
        { id: 'normalize-view', path: './components/normalize.html' },
        { id: 'quiz-view', path: './components/quiz.html' },
        { id: 'mtp-transfer-view', path: './components/mtp-transfer.html' },
    ];

    // 全ての読み込みが完了するまで待機
    await Promise.all(components.map(c => loadComponent(c.id, c.path)));
}