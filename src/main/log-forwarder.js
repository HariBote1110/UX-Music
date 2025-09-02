const { BrowserWindow } = require('electron');

/**
 * メインプロセスのconsole.logなどをオーバーライドし、
 * レンダラープロセスのDevToolsコンソールにログを転送する。
 */
function initialize() {
    const originalConsole = {
        log: console.log,
        warn: console.warn,
        error: console.error,
        info: console.info,
        debug: console.debug, // debugも対象に追加
    };

    const forward = (level, ...args) => {
        // 元のコンソール出力も実行する
        originalConsole[level](...args);

        // すべてのウィンドウにログを送信
        // ▼▼▼ ここからが修正箇所です ▼▼▼
        const focusedWindow = BrowserWindow.getFocusedWindow();
        const targetWindows = focusedWindow ? [focusedWindow] : BrowserWindow.getAllWindows();
        
        targetWindows.forEach(win => {
            if (win && !win.isDestroyed() && win.webContents && !win.webContents.isCrashed()) {
                win.webContents.send('log-message', { level, args });
            }
        });
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
    };

    console.log = (...args) => forward('log', ...args);
    console.warn = (...args) => forward('warn', ...args);
    console.error = (...args) => forward('error', ...args);
    console.info = (...args) => forward('info', ...args);
    console.debug = (...args) => forward('debug', ...args); // debugも転送
}

module.exports = { initialize };