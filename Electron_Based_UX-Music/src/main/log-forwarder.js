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
        debug: console.debug,
    };

    const forward = (level, ...args) => {
        // 元のコンソール出力（VSCodeターミナルなど）も実行する
        originalConsole[level](...args);

        // すべてのウィンドウのDevToolsにログを送信する
        BrowserWindow.getAllWindows().forEach(win => {
            if (win && !win.isDestroyed() && win.webContents && !win.webContents.isCrashed()) {
                win.webContents.send('log-message', { level, args });
            }
        });
    };

    console.log = (...args) => forward('log', ...args);
    console.warn = (...args) => forward('warn', ...args);
    console.error = (...args) => forward('error', ...args);
    console.info = (...args) => forward('info', ...args);
    console.debug = (...args) => forward('debug', ...args);
}

module.exports = { initialize };