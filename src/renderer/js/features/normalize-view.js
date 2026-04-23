// src/renderer/js/features/normalize-view.js
import { showNotification, hideNotification } from '../ui/notification.js';
import { normalizeAPI } from '../core/api/normalize.js';

// モジュールスコープで変数を宣言（グローバルリーク防止）
const normalizeFiles = new Map();
let commonBasePath = null;
const outputSettings = {
    mode: 'overwrite', // 'overwrite' or 'folder'
    path: null
};

const LS_NORMALIZE_NAME_MIN = 'ux-music-normalize-name-min-px';
const LS_NORMALIZE_WRAP = 'ux-music-normalize-wrap-names';

function clampNormalizeNameMin(px) {
    const n = parseInt(String(px), 10);
    if (Number.isNaN(n)) return 160;
    return Math.max(80, Math.min(420, n));
}

function payloadSucceeded(result) {
    if (!result || typeof result !== 'object') return false;
    if (result.success === true) return true;
    if (result.Success === true) return true;
    return false;
}

/**
 * Wails の WebView では window.confirm() がサイレントに false を返すことがある。
 * カスタム HTML モーダルで確認ダイアログを表示し、Promise<boolean> を返す。
 */
function wailsConfirm(message) {
    return new Promise((resolve) => {
        const overlay = document.createElement('div');
        overlay.style.cssText = [
            'position:fixed', 'inset:0', 'background:rgba(0,0,0,0.6)',
            'z-index:9999', 'display:flex', 'align-items:center', 'justify-content:center',
        ].join(';');

        const box = document.createElement('div');
        box.style.cssText = [
            'background:#1e1e2e', 'color:#cdd6f4', 'padding:28px 32px',
            'border-radius:10px', 'max-width:440px', 'width:90%',
            'box-shadow:0 8px 32px rgba(0,0,0,.6)', 'font-size:14px', 'line-height:1.6',
        ].join(';');

        const msgEl = document.createElement('p');
        msgEl.style.cssText = 'margin:0 0 20px 0; white-space:pre-wrap;';
        msgEl.textContent = message;

        const btnRow = document.createElement('div');
        btnRow.style.cssText = 'display:flex; gap:10px; justify-content:flex-end;';

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'キャンセル';
        cancelBtn.style.cssText = [
            'padding:8px 20px', 'border-radius:6px', 'border:1px solid #555',
            'background:transparent', 'color:#cdd6f4', 'cursor:pointer', 'font-size:14px',
        ].join(';');

        const okBtn = document.createElement('button');
        okBtn.textContent = 'OK';
        okBtn.style.cssText = [
            'padding:8px 20px', 'border-radius:6px', 'border:none',
            'background:#89b4fa', 'color:#1e1e2e', 'cursor:pointer',
            'font-size:14px', 'font-weight:bold',
        ].join(';');

        const close = (result) => {
            document.body.removeChild(overlay);
            resolve(result);
        };
        cancelBtn.onclick = () => close(false);
        okBtn.onclick = () => close(true);

        // ESC キーでキャンセル
        const onKey = (e) => {
            if (e.key === 'Escape') { document.removeEventListener('keydown', onKey); close(false); }
            if (e.key === 'Enter') { document.removeEventListener('keydown', onKey); close(true); }
        };
        document.addEventListener('keydown', onKey);

        btnRow.appendChild(cancelBtn);
        btnRow.appendChild(okBtn);
        box.appendChild(msgEl);
        box.appendChild(btnRow);
        overlay.appendChild(box);
        document.body.appendChild(overlay);
        okBtn.focus();
    });
}

function applyNormaliseTableLayoutPrefs() {
    const root = document.getElementById('normalize-view');
    const slider = document.getElementById('normalize-name-col-slider');
    if (!root) return;
    const minPx = slider ? clampNormalizeNameMin(slider.value) : 160;
    root.style.setProperty('--normalize-name-column-min', `${minPx}px`);
    const wrapCb = document.getElementById('normalize-wrap-names');
    const wrap = Boolean(wrapCb?.checked);
    root.classList.toggle('normalize-wrap-filenames', wrap);
}

function restoreNormaliseTableLayoutControls() {
    const slider = document.getElementById('normalize-name-col-slider');
    const valueLabel = document.getElementById('normalize-name-col-value');
    const wrapCb = document.getElementById('normalize-wrap-names');
    if (slider) {
        try {
            const raw = localStorage.getItem(LS_NORMALIZE_NAME_MIN);
            if (raw != null && raw !== '') {
                slider.value = String(clampNormalizeNameMin(raw));
            }
        } catch { /* ignore */ }
    }
    if (valueLabel && slider) {
        valueLabel.textContent = `${clampNormalizeNameMin(slider.value)} px`;
    }
    if (wrapCb) {
        try {
            wrapCb.checked = localStorage.getItem(LS_NORMALIZE_WRAP) === '1';
        } catch { /* ignore */ }
    }
    applyNormaliseTableLayoutPrefs();
}

function getBasename(path) {
    return path.split(/[\\/]/).pop();
}

function getExtname(path) {
    const dotIndex = path.lastIndexOf('.');
    return dotIndex === -1 ? '' : path.substring(dotIndex);
}

function getDirname(path) {
    const lastIndex = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return lastIndex === -1 ? '' : path.substring(0, lastIndex);
}

function findCommonBasePath(filePaths) {
    if (filePaths.length === 0) return null;
    if (filePaths.length === 1) return getDirname(filePaths[0]);

    const a1 = filePaths[0].split(/[\\/]/);
    const a2 = filePaths[filePaths.length - 1].split(/[\\/]/);
    const L = a1.length;
    let i = 0;
    while (i < L && a1[i] === a2[i]) {
        i++;
    }
    return a1.slice(0, i).join('/');
}

function updateFileList() {
    const tbody = document.getElementById('normalize-file-list');
    const selectAllCheckbox = document.getElementById('normalize-select-all');
    tbody.innerHTML = '';

    if (normalizeFiles.size === 0) {
        document.getElementById('normalize-analyze-btn').disabled = true;
        document.getElementById('normalize-apply-btn').disabled = true;
        selectAllCheckbox.checked = false;
        selectAllCheckbox.indeterminate = false;
        return;
    }

    let canApply = true;
    let selectedCount = 0;
    let hasUnanalyzedSelected = false;

    for (const [id, file] of normalizeFiles.entries()) {
        const row = document.createElement('tr');
        const diff = typeof file.currentLufs === 'number' ? (file.targetLufs - file.currentLufs).toFixed(2) : '-';

        row.innerHTML = `
            <td><input type="checkbox" class="normalize-select-item" data-id="${id}" ${file.selected ? 'checked' : ''}></td>
            <td>${file.name}</td>
            <td>${typeof file.currentLufs === 'number' ? file.currentLufs.toFixed(2) + ' LUFS' : '-'}</td>
            <td>${diff} dB</td>
            <td class="status-${file.status}">${file.status}</td>
        `;
        tbody.appendChild(row);

        if (file.selected) {
            selectedCount++;
            if (file.status === 'pending') hasUnanalyzedSelected = true;
            if (file.status !== 'analysed' && file.status !== 'done') canApply = false;
        }
    }

    // Add event listeners to new checkboxes
    tbody.querySelectorAll('.normalize-select-item').forEach(checkbox => {
        checkbox.addEventListener('change', (e) => {
            const fileId = e.target.dataset.id;
            const file = normalizeFiles.get(fileId);
            if (file) {
                file.selected = e.target.checked;
                updateFileList();
            }
        });
    });

    if (selectedCount === 0) {
        selectAllCheckbox.checked = false;
        selectAllCheckbox.indeterminate = false;
    } else if (selectedCount === normalizeFiles.size) {
        selectAllCheckbox.checked = true;
        selectAllCheckbox.indeterminate = false;
    } else {
        selectAllCheckbox.checked = false;
        selectAllCheckbox.indeterminate = true;
    }

    document.getElementById('normalize-analyze-btn').disabled = !hasUnanalyzedSelected;

    // 出力先未選択で disabled にすると、ブラウザはクリックを発火しないためユーザーに何も起きないように見える。
    // フォルダ出力の検証は適用ボタンのクリック内で行う。
    const applyButtonDisabled = !(selectedCount > 0 && canApply);
    const applyBtn = document.getElementById('normalize-apply-btn');
    applyBtn.disabled = applyButtonDisabled;
    if (outputSettings.mode === 'folder' && !outputSettings.path) {
        applyBtn.title = '別フォルダへ書き出す場合は「フォルダを選択」で出力先を指定してから押してください。';
    } else {
        applyBtn.title = '';
    }
}

async function addFiles(filePaths, preAnalyzedData = {}) {
    const targetLufs = parseFloat(document.getElementById('target-lufs-slider').value);
    for (const filePath of filePaths) {
        // ▼▼▼ 修正: macOSの隠しファイル・リソースフォーク(._)を除外 ▼▼▼
        const fileName = getBasename(filePath);
        if (fileName.startsWith('._') || fileName === '.DS_Store') {
            continue;
        }
        // ▲▲▲ 修正ここまで ▲▲▲

        const id = self.crypto.randomUUID();
        const existingEntry = preAnalyzedData[filePath];
        // Support both legacy float64 and current {loudness, truePeak} formats
        const existingLoudness = typeof existingEntry === 'number'
            ? existingEntry
            : (existingEntry && typeof existingEntry.loudness === 'number' ? existingEntry.loudness : null);
        const existingTruePeak = existingEntry && typeof existingEntry.truePeak === 'number'
            ? existingEntry.truePeak
            : null;

        normalizeFiles.set(id, {
            id,
            path: filePath,
            name: fileName,
            status: existingLoudness !== null ? 'analysed' : 'pending',
            currentLufs: existingLoudness,
            truePeak: existingTruePeak,
            targetLufs: targetLufs,
            selected: true,
        });
    }

    const allPaths = [...normalizeFiles.values()].map(f => f.path);
    commonBasePath = findCommonBasePath(allPaths);

    updateFileList();
}

function updateProgress(processed, total, label) {
    const progressBar = document.getElementById('normalize-progress-bar');
    const progressLabel = document.getElementById('normalize-progress-label');
    const progressContainer = document.getElementById('normalize-progress-container');

    if (processed >= total) {
        progressContainer.classList.add('hidden');
        return;
    }

    progressContainer.classList.remove('hidden');
    progressBar.value = processed;
    progressBar.max = total;
    progressLabel.textContent = `${label} (${processed} / ${total})...`;
}

export function initNormalizeView() {
    restoreNormaliseTableLayoutControls();

    const dropZone = document.getElementById('normalize-drop-zone');
    dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.add('drag-over'); });
    dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.remove('drag-over'); });
    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        e.stopPropagation();
        dropZone.classList.remove('drag-over');
        const files = Array.from(e.dataTransfer.files).map(f => f.path);
        addFiles(files);
    });

    document.getElementById('normalize-add-files-btn').addEventListener('click', async () => {
        const filePaths = await normalizeAPI.selectFiles();
        if (filePaths.length > 0) addFiles(filePaths);
    });

    document.getElementById('normalize-add-folder-btn').addEventListener('click', async () => {
        const filePaths = await normalizeAPI.selectFolder();
        if (filePaths.length > 0) addFiles(filePaths);
    });

    document.getElementById('normalize-load-library-btn').addEventListener('click', async () => {
        const library = await normalizeAPI.getLibrary();
        const loudnessData = await normalizeAPI.getAllLoudness();
        const filePaths = library.map(song => song.path);
        addFiles(filePaths, loudnessData);
    });

    document.getElementById('normalize-select-all').addEventListener('change', (e) => {
        const isChecked = e.target.checked;
        for (const file of normalizeFiles.values()) {
            file.selected = isChecked;
        }
        updateFileList();
    });

    const lufsSlider = document.getElementById('target-lufs-slider');
    const lufsValue = document.getElementById('target-lufs-value');
    lufsSlider.addEventListener('input', () => {
        const newLufs = parseFloat(lufsSlider.value);
        lufsValue.textContent = `${newLufs.toFixed(1)} LUFS`;
        for (const file of normalizeFiles.values()) {
            file.targetLufs = newLufs;
        }
        if (normalizeFiles.size > 0) updateFileList();
    });

    const nameColSlider = document.getElementById('normalize-name-col-slider');
    const nameColValue = document.getElementById('normalize-name-col-value');
    const wrapNames = document.getElementById('normalize-wrap-names');
    if (nameColSlider && nameColValue) {
        nameColSlider.addEventListener('input', () => {
            const v = clampNormalizeNameMin(nameColSlider.value);
            nameColValue.textContent = `${v} px`;
            try {
                localStorage.setItem(LS_NORMALIZE_NAME_MIN, String(v));
            } catch { /* ignore */ }
            applyNormaliseTableLayoutPrefs();
        });
    }
    if (wrapNames) {
        wrapNames.addEventListener('change', () => {
            try {
                localStorage.setItem(LS_NORMALIZE_WRAP, wrapNames.checked ? '1' : '0');
            } catch { /* ignore */ }
            applyNormaliseTableLayoutPrefs();
        });
    }

    const outputFolderContainer = document.getElementById('output-folder-container');
    const backupContainer = document.getElementById('backup-container');
    document.querySelectorAll('input[name="output-mode"]').forEach(radio => {
        radio.addEventListener('change', (e) => {
            outputSettings.mode = e.target.value;
            if (e.target.value === 'folder') {
                outputFolderContainer.classList.remove('hidden');
                backupContainer.classList.add('hidden');
            } else {
                outputFolderContainer.classList.add('hidden');
                backupContainer.classList.remove('hidden');
            }
            updateFileList(); // Update button states
        });
    });

    document.getElementById('select-output-folder-btn').addEventListener('click', async () => {
        const selectedPath = await normalizeAPI.selectOutputFolder();
        if (selectedPath) {
            outputSettings.path = selectedPath;
            document.getElementById('output-folder-path').textContent = selectedPath;
            updateFileList();
        }
    });

    document.getElementById('normalize-analyze-btn').addEventListener('click', () => {
        const filesToAnalyze = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending');
        if (filesToAnalyze.length === 0) return;
        normalizeAPI.startJob('analyze', filesToAnalyze, {});
        updateProgress(0, filesToAnalyze.length, '解析中');
    });

    document.getElementById('normalize-apply-btn').addEventListener('click', async () => {
        console.log('[Normalize][Apply] click fired');
        const filesToNormalize = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analysed');
        if (filesToNormalize.length === 0) {
            showNotification('適用できるのは「解析済み」でチェックが入っている行だけです。');
            hideNotification(5000);
            return;
        }

        if (outputSettings.mode === 'folder') {
            const outPath = typeof outputSettings.path === 'string' ? outputSettings.path.trim() : '';
            if (!outPath) {
                showNotification('「別のフォルダ」で書き出す場合は、先に「フォルダを選択」で出力先を指定してください。');
                hideNotification(6000);
                return;
            }
        }

        const containsMp3 = filesToNormalize.some(f => getExtname(f.path).toLowerCase() === '.mp3');
        const losslessFormats = ['.wav', '.flac'];
        const clippingFiles = filesToNormalize.filter(f => {
            const ext = getExtname(f.path).toLowerCase();
            if (losslessFormats.includes(ext) && typeof f.truePeak === 'number' && typeof f.currentLufs === 'number') {
                const gain = f.targetLufs - f.currentLufs;
                return f.truePeak + gain > 0;
            }
            return false;
        });

        let confirmed = true;
        let preventClipping = false;

        if (clippingFiles.length > 0) {
            // window.confirm() は Wails WebView でサイレントに false を返すことがあるため
            // カスタムモーダルを使用する
            confirmed = await wailsConfirm(
                `警告: ${clippingFiles.length}個のWAV/FLACファイルで音割れ（クリッピング）が発生する可能性があります。\n\n` +
                'これらのファイルの音量をクリッピングしない最大限の音量に自動で調整しますか？\n\n' +
                '「OK」を押すと自動調整して続行します。\n' +
                '「キャンセル」を押すと処理を中止します。'
            );
            if (confirmed) {
                preventClipping = true;
            }
        }

        if (confirmed && containsMp3 && outputSettings.mode === 'overwrite') {
            confirmed = await wailsConfirm(
                '警告: リストにMP3ファイルが含まれています。\n\n' +
                'MP3の音量調整は再エンコードを伴うため、音質がわずかに劣化する可能性があります。\n' +
                'この操作は元に戻せません（バックアップ作成時を除く）。\n\n' +
                '続行しますか？'
            );
        }

        if (confirmed) {
            const targetLufs = parseFloat(lufsSlider.value);
            const filesWithGain = filesToNormalize.map(f => {
                let gain = targetLufs - f.currentLufs;
                const ext = getExtname(f.path).toLowerCase();

                if (preventClipping && losslessFormats.includes(ext) && typeof f.truePeak === 'number') {
                    const newPeak = f.truePeak + gain;
                    if (newPeak > 0) {
                        gain -= newPeak; // クリッピング分だけゲインを下げる
                    }
                }
                return { ...f, gain };
            });

            const jobFiles = filesWithGain.map((f) => ({
                id: f.id,
                path: f.path,
                gain: Number(f.gain),
            }));

            console.log('[Normalize][Apply] sending job, files:', jobFiles.length, 'mode:', outputSettings.mode);
            const backup = outputSettings.mode === 'overwrite' ? document.getElementById('backup-toggle').checked : false;
            normalizeAPI.startJob('normalize', jobFiles, {
                backup,
                output: { mode: outputSettings.mode, path: outputSettings.path || '' },
                basePath: commonBasePath || '',
            });
            updateProgress(0, filesToNormalize.length, '適用中');
        }
    });

    let processedCount = 0;
    let totalCount = 0;
    let currentJob = '';

    // 既存リスナーを解除してから再登録（initNormalizeView が複数回呼ばれても積み上がらない）
    if (initNormalizeView._unsubWorker) initNormalizeView._unsubWorker();
    if (initNormalizeView._unsubFinished) initNormalizeView._unsubFinished();

    initNormalizeView._unsubWorker = normalizeAPI.onWorkerResult((...evArgs) => {
        const row = evArgs.length && typeof evArgs[0] === 'object' && evArgs[0] !== null ? evArgs[0] : {};
        let type = row.type;
        let id = row.id;
        let result = row.result;
        if (type === undefined && evArgs.length >= 3) {
            type = evArgs[0];
            id = evArgs[1];
            result = evArgs[2];
        }
        if (typeof result === 'string') {
            try {
                result = JSON.parse(result);
            } catch {
                /* leave as string */
            }
        }

        let file = id ? normalizeFiles.get(id) : undefined;
        const rowPath = typeof row.path === 'string' ? row.path : '';
        if (!file && rowPath) {
            for (const f of normalizeFiles.values()) {
                if (f.path === rowPath) {
                    file = f;
                    break;
                }
            }
        }
        if (!file) {
            console.warn('[Normalize] result for unknown id/path:', id, rowPath, type);
            return;
        }

        if (type === 'analysis-result') {
            if (currentJob !== 'analyse') {
                totalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending').length;
                processedCount = 0;
                currentJob = 'analyse';
            }
            if (payloadSucceeded(result)) {
                file.currentLufs = result.loudness;
                file.truePeak = result.truePeak;
                file.status = 'analysed';
            } else {
                file.status = 'error';
                console.error(`Analysis Error for ${file.name}:`, result && (result.error || result.Error));
            }
        } else if (type === 'normalize-result') {
            if (currentJob !== 'normalize') {
                totalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analysed').length;
                processedCount = 0;
                currentJob = 'normalize';
            }
            if (payloadSucceeded(result)) {
                file.status = 'done';
                if (result.outputPath) {
                    file.name = getBasename(result.outputPath);
                }
            } else {
                file.status = 'error';
                const errMsg = (result && (result.error || result.Error)) || '';
                if (errMsg) console.error(`Normalize Error for ${file.name}:`, errMsg);
            }
        }

        processedCount++;
        updateFileList();
        updateProgress(processedCount, totalCount, currentJob === 'analyse' ? '解析中' : '適用中');
    });

    initNormalizeView._unsubFinished = normalizeAPI.onJobFinished((...evArgs) => {
        const info = evArgs.length && typeof evArgs[0] === 'object' && evArgs[0] !== null ? evArgs[0] : {};
        const scheduled = typeof info.scheduled === 'number' ? info.scheduled : undefined;
        if (scheduled === 0 && info.jobType === 'normalize') {
            showNotification('適用ジョブをサーバーが受け取れませんでした。ターミナルの [Normalize] ログを確認するか、ファイルを入れ直してください。');
            hideNotification(6000);
        }
        const progressContainer = document.getElementById('normalize-progress-container');
        if (progressContainer) {
            progressContainer.classList.add('hidden');
        }
    });
}