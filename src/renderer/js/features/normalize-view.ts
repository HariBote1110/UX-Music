// src/renderer/js/features/normalize-view.ts — mainContent 描画用
import { getNormalizeViewHtml } from './normalize-view-html.js';

const electronAPI = window.electronAPI;

const normalizeFiles = new Map();
let commonBasePath = null;
const outputSettings = {
    mode: 'overwrite',
    path: null
};

let jobProcessedCount = 0;
let jobTotalCount = 0;
let currentJob = '';

let normalizeIpcHandlerRegistered = false;

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
    if (!tbody || !selectAllCheckbox) return;

    tbody.innerHTML = '';

    if (normalizeFiles.size === 0) {
        const analyseBtn = document.getElementById('normalize-analyze-btn') as HTMLButtonElement | null;
        const applyBtn = document.getElementById('normalize-apply-btn') as HTMLButtonElement | null;
        if (analyseBtn) analyseBtn.disabled = true;
        if (applyBtn) applyBtn.disabled = true;
        (selectAllCheckbox as HTMLInputElement).checked = false;
        (selectAllCheckbox as HTMLInputElement).indeterminate = false;
        return;
    }

    let canApply = true;
    let selectedCount = 0;
    let hasUnanalysedSelected = false;

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
            if (file.status === 'pending') hasUnanalysedSelected = true;
            if (file.status !== 'analysed' && file.status !== 'done') canApply = false;
        }
    }

    tbody.querySelectorAll('.normalize-select-item').forEach(checkbox => {
        checkbox.addEventListener('change', (e) => {
            const target = e.target as HTMLInputElement | null;
            const fileId = target?.dataset.id;
            const file = normalizeFiles.get(fileId);
            if (file) {
                file.selected = target?.checked;
                updateFileList();
            }
        });
    });

    if (selectedCount === 0) {
        (selectAllCheckbox as HTMLInputElement).checked = false;
        (selectAllCheckbox as HTMLInputElement).indeterminate = false;
    } else if (selectedCount === normalizeFiles.size) {
        (selectAllCheckbox as HTMLInputElement).checked = true;
        (selectAllCheckbox as HTMLInputElement).indeterminate = false;
    } else {
        (selectAllCheckbox as HTMLInputElement).checked = false;
        (selectAllCheckbox as HTMLInputElement).indeterminate = true;
    }

    const analyseEl = document.getElementById('normalize-analyze-btn') as HTMLButtonElement | null;
    if (analyseEl) analyseEl.disabled = !hasUnanalysedSelected;

    const applyButtonDisabled = !(selectedCount > 0 && canApply && (outputSettings.mode === 'overwrite' || (outputSettings.mode === 'folder' && outputSettings.path)));
    const applyEl = document.getElementById('normalize-apply-btn') as HTMLButtonElement | null;
    if (applyEl) applyEl.disabled = applyButtonDisabled;
}

async function addFiles(filePaths, preAnalysedData = {}) {
    const slider = document.getElementById('target-lufs-slider') as HTMLInputElement | null;
    const targetLufs = parseFloat(slider ? slider.value : '-18');
    for (const filePath of filePaths) {
        const fileName = getBasename(filePath);
        if (fileName.startsWith('._') || fileName === '.DS_Store') {
            continue;
        }

        const id = self.crypto.randomUUID();
        const existingEntry = preAnalysedData[filePath];
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
    const progressBar = document.getElementById('normalize-progress-bar') as HTMLProgressElement | null;
    const progressLabel = document.getElementById('normalize-progress-label');
    const progressContainer = document.getElementById('normalize-progress-container');

    if (!progressBar || !progressLabel || !progressContainer) return;

    if (processed >= total) {
        progressContainer.classList.add('hidden');
        return;
    }

    progressContainer.classList.remove('hidden');
    progressBar.value = processed;
    progressBar.max = total;
    progressLabel.textContent = `${label} (${processed} / ${total})...`;
}

function registerNormalizeIpcHandlerOnce() {
    if (normalizeIpcHandlerRegistered) return;
    normalizeIpcHandlerRegistered = true;

    electronAPI.on('normalize-worker-result', ((...args: unknown[]) => {
        const { type, id, result } = args[0] as { type: string; id: string; result: any };
        const file = normalizeFiles.get(id);
        if (!file) return;

        if (type === 'analysis-result') {
            if (result.success) {
                file.currentLufs = result.loudness;
                file.truePeak = result.truePeak;
                file.status = 'analysed';
            } else {
                file.status = 'error';
                console.error(`Analysis Error for ${file.name}:`, result.error);
            }
            if (currentJob !== 'analyze') {
                jobTotalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending').length;
                jobProcessedCount = 0;
                currentJob = 'analyze';
            }
        } else if (type === 'normalize-result') {
            if (result.success) {
                file.status = 'done';
                if (result.outputPath) {
                    file.name = getBasename(result.outputPath);
                }
            } else {
                file.status = 'error';
                if (result.error) console.error(`Normalize Error for ${file.name}:`, result.error);
            }

            if (currentJob !== 'normalize') {
                jobTotalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analysed').length;
                jobProcessedCount = 0;
                currentJob = 'normalize';
            }
        }

        jobProcessedCount++;
        updateFileList();
        updateProgress(jobProcessedCount, jobTotalCount, currentJob === 'analyze' ? '解析中' : '適用中');
        electronAPI.send('normalize-worker-finished-file');
    }) as (...args: unknown[]) => void);
}

/**
 * ノーマライズビューを mainContent に描画する
 * @param {HTMLElement} container
 * @param {{ signal?: AbortSignal }} [options]
 */
export function renderNormalizeView(container: HTMLElement, options: { signal?: AbortSignal } = {}) {
    const { signal } = options;
    registerNormalizeIpcHandlerOnce();

    // 再表示時に前回の状態をリセットする
    normalizeFiles.clear();

    container.innerHTML = `<div class="normalize-view-inner" id="normalize-view">${getNormalizeViewHtml()}</div>`;

    const dropZone = document.getElementById('normalize-drop-zone');
    if (!dropZone) return;

    if (signal) {
        dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.add('drag-over'); }, { signal });
        dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.remove('drag-over'); }, { signal });
        dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            dropZone.classList.remove('drag-over');
            const files = Array.from((e as DragEvent).dataTransfer!.files).map(f => (f as any).path as string);
            addFiles(files);
        }, { signal });
    } else {
        dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.add('drag-over'); });
        dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); dropZone.classList.remove('drag-over'); });
        dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            dropZone.classList.remove('drag-over');
            const files = Array.from((e as DragEvent).dataTransfer!.files).map(f => (f as any).path as string);
            addFiles(files);
        });
    }

    const bind = (id, event, fn) => {
        const el = document.getElementById(id);
        if (!el) return;
        if (signal) el.addEventListener(event, fn, { signal });
        else el.addEventListener(event, fn);
    };

    bind('normalize-add-files-btn', 'click', async () => {
        const filePaths = await electronAPI.invoke('select-files-for-normalize') as string[];
        if (filePaths.length > 0) addFiles(filePaths);
    });
    bind('normalize-add-folder-btn', 'click', async () => {
        const filePaths = await electronAPI.invoke('select-folder-for-normalize') as string[];
        if (filePaths.length > 0) addFiles(filePaths);
    });
    bind('normalize-load-library-btn', 'click', async () => {
        const library = await electronAPI.invoke('get-library-for-normalize') as any[];
        const loudnessData = await electronAPI.invoke('get-all-loudness-data');
        const filePaths = library.map((song: any) => song.path);
        addFiles(filePaths, loudnessData);
    });

    bind('normalize-select-all', 'change', (e: Event) => {
        const isChecked = (e.target as HTMLInputElement).checked;
        for (const file of normalizeFiles.values()) {
            file.selected = isChecked;
        }
        updateFileList();
    });

    const lufsSlider = document.getElementById('target-lufs-slider') as HTMLInputElement | null;
    const lufsValue = document.getElementById('target-lufs-value');
    if (lufsSlider && lufsValue) {
        const onInput = () => {
            const newLufs = parseFloat(lufsSlider.value);
            lufsValue.textContent = `${newLufs.toFixed(1)} LUFS`;
            for (const file of normalizeFiles.values()) {
                file.targetLufs = newLufs;
            }
            if (normalizeFiles.size > 0) updateFileList();
        };
        if (signal) lufsSlider.addEventListener('input', onInput, { signal });
        else lufsSlider.addEventListener('input', onInput);
    }

    const outputFolderContainer = document.getElementById('output-folder-container');
    const backupContainer = document.getElementById('backup-container');
    document.querySelectorAll('input[name="output-mode"]').forEach(radio => {
        const onMode = (e: Event) => {
            const val = (e.target as HTMLInputElement).value;
            outputSettings.mode = val;
            if (val === 'folder') {
                outputFolderContainer?.classList.remove('hidden');
                backupContainer?.classList.add('hidden');
            } else {
                outputFolderContainer?.classList.add('hidden');
                backupContainer?.classList.remove('hidden');
            }
            updateFileList();
        };
        if (signal) radio.addEventListener('change', onMode, { signal });
        else radio.addEventListener('change', onMode);
    });

    bind('select-output-folder-btn', 'click', async () => {
        const selectedPath = await electronAPI.invoke('select-normalize-output-folder') as string | null;
        if (selectedPath) {
            outputSettings.path = selectedPath;
            const pathEl = document.getElementById('output-folder-path');
            if (pathEl) pathEl.textContent = selectedPath;
            updateFileList();
        }
    });

    bind('normalize-analyze-btn', 'click', () => {
        const filesToAnalyse = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending');
        if (filesToAnalyse.length === 0) return;
        electronAPI.send('start-normalize-job', { jobType: 'analyze', files: filesToAnalyse });
        updateProgress(0, filesToAnalyse.length, '解析中');
    });

    bind('normalize-apply-btn', 'click', () => {
        const filesToNormalise = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analysed');
        if (filesToNormalise.length === 0) return;

        const lufsSliderEl = document.getElementById('target-lufs-slider') as HTMLInputElement | null;
        const containsMp3 = filesToNormalise.some(f => getExtname(f.path).toLowerCase() === '.mp3');
        const losslessFormats = ['.wav', '.flac'];
        const clippingFiles = filesToNormalise.filter(f => {
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
            confirmed = confirm(
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
            confirmed = confirm(
                '警告: リストにMP3ファイルが含まれています。\n\n' +
                'MP3の音量調整は再エンコードを伴うため、音質がわずかに劣化する可能性があります。\n' +
                'この操作は元に戻せません（バックアップ作成時を除く）。\n\n' +
                '続行しますか？'
            );
        }

        if (confirmed) {
            const targetLufs = parseFloat(lufsSliderEl ? lufsSliderEl.value : '-18');
            const filesWithGain = filesToNormalise.map(f => {
                let gain = targetLufs - f.currentLufs;
                const ext = getExtname(f.path).toLowerCase();

                if (preventClipping && losslessFormats.includes(ext) && typeof f.truePeak === 'number') {
                    const newPeak = f.truePeak + gain;
                    if (newPeak > 0) {
                        gain -= newPeak;
                    }
                }
                return { ...f, gain };
            });

            const backupToggle = document.getElementById('backup-toggle') as HTMLInputElement | null;
            const backup = outputSettings.mode === 'overwrite'
                ? (backupToggle ? backupToggle.checked : false)
                : false;
            electronAPI.send('start-normalize-job', {
                jobType: 'normalize',
                files: filesWithGain,
                options: {
                    backup,
                    output: outputSettings,
                    basePath: commonBasePath
                }
            });
            updateProgress(0, filesToNormalise.length, '適用中');
        }
    });

    // 既存データがあれば初期表示に反映する
    updateFileList();
}
