/**
 * テスト用のシンプルな Node.js サイドカー
 * kalam.dylib なしで通信の往復テストのみを行う
 */

const readline = require('readline');

function sendResponse(id, type, payload, error = null) {
    const response = { id, type, payload };
    if (error) response.error = error;
    console.log(JSON.stringify(response));
}

console.error('[Test-Sidecar] Started');

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false,
});

rl.on('line', (line) => {
    try {
        const req = JSON.parse(line);
        console.error(`[Test-Sidecar] Received: ${req.type}`);

        switch (req.type) {
            case 'init':
                sendResponse(req.id, 'init-success', { message: 'Test sidecar initialized!' });
                break;
            case 'echo':
                sendResponse(req.id, 'echo-result', req.payload);
                break;
            default:
                sendResponse(req.id, 'error', null, `Unknown command: ${req.type}`);
        }
    } catch (err) {
        console.error('[Test-Sidecar] Parse error:', err.message);
        sendResponse('', 'parse-error', null, 'Invalid JSON');
    }
});

rl.on('close', () => {
    console.error('[Test-Sidecar] Exiting');
    process.exit(0);
});
