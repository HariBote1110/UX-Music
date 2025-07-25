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
    };

    const forward = (level, ...args) => {
        // 元のコンソール出力も実行する
        originalConsole[level](...args);

        // すべてのウィンドウにログを送信
        BrowserWindow.getAllWindows().forEach(win => {
            if (win && !win.isDestroyed() && win.webContents) {
                win.webContents.send('log-message', { level, args });
            }
        });
    };

    console.log = (...args) => forward('log', ...args);
    console.warn = (...args) => forward('warn', ...args);
    console.error = (...args) => forward('error', ...args);
    console.info = (...args) => forward('info', ...args);
}

module.exports = { initialize };