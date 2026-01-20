// src/renderer/js/normalize-view.js
import { state, elements } from './state.js';
import { showView } from './navigation.js';
const electronAPI = window.electronAPI;

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

    let canAnalyze = false;
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
            if (file.status !== 'analyzed') canApply = false;
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

    const applyButtonDisabled = !(selectedCount > 0 && canApply && (outputSettings.mode === 'overwrite' || (outputSettings.mode === 'folder' && outputSettings.path)));
    document.getElementById('normalize-apply-btn').disabled = applyButtonDisabled;
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
        const existingLoudness = preAnalyzedData[filePath];

        normalizeFiles.set(id, {
            id,
            path: filePath,
            name: fileName,
            status: typeof existingLoudness === 'number' ? 'analyzed' : 'pending',
            currentLufs: typeof existingLoudness === 'number' ? existingLoudness : null,
            truePeak: null,
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
    elements.normalizeViewBtn.addEventListener('click', () => {
        elements.mainContent.classList.add('hidden');
        elements.normalizeView.classList.remove('hidden');
        elements.navLinks.forEach(l => l.classList.remove('active'));
    });

    document.querySelectorAll('.nav-link').forEach(link => {
        link.addEventListener('click', () => {
            elements.mainContent.classList.remove('hidden');
            elements.normalizeView.classList.add('hidden');
        });
    });

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
        const filePaths = await electronAPI.invoke('select-files-for-normalize');
        if (filePaths.length > 0) addFiles(filePaths);
    });

    document.getElementById('normalize-add-folder-btn').addEventListener('click', async () => {
        const filePaths = await electronAPI.invoke('select-folder-for-normalize');
        if (filePaths.length > 0) addFiles(filePaths);
    });

    document.getElementById('normalize-load-library-btn').addEventListener('click', async () => {
        const library = await electronAPI.invoke('get-library-for-normalize');
        const loudnessData = await electronAPI.invoke('get-all-loudness-data');
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
        const selectedPath = await electronAPI.invoke('select-normalize-output-folder');
        if (selectedPath) {
            outputSettings.path = selectedPath;
            document.getElementById('output-folder-path').textContent = selectedPath;
            updateFileList();
        }
    });

    document.getElementById('normalize-analyze-btn').addEventListener('click', () => {
        const filesToAnalyze = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending');
        if (filesToAnalyze.length === 0) return;
        electronAPI.send('start-normalize-job', { jobType: 'analyze', files: filesToAnalyze });
        updateProgress(0, filesToAnalyze.length, '解析中');
    });

    document.getElementById('normalize-apply-btn').addEventListener('click', () => {
        const filesToNormalize = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analyzed');
        if (filesToNormalize.length === 0) return;

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

            const backup = outputSettings.mode === 'overwrite' ? document.getElementById('backup-toggle').checked : false;
            electronAPI.send('start-normalize-job', {
                jobType: 'normalize',
                files: filesWithGain,
                options: {
                    backup,
                    output: outputSettings,
                    basePath: commonBasePath
                }
            });
            updateProgress(0, filesToNormalize.length, '適用中');
        }
    });

    let processedCount = 0;
    let totalCount = 0;
    let currentJob = '';

    electronAPI.on('normalize-worker-result', (event, { type, id, result }) => {
        const file = normalizeFiles.get(id);
        if (!file) return;

        if (type === 'analysis-result') {
            if (result.success) {
                file.currentLufs = result.loudness;
                file.truePeak = result.truePeak;
                file.status = 'analyzed';
            } else {
                file.status = 'error';
                console.error(`Analysis Error for ${file.name}:`, result.error);
            }
            if (currentJob !== 'analyze') {
                totalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'pending').length;
                processedCount = 0;
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
                totalCount = [...normalizeFiles.values()].filter(f => f.selected && f.status === 'analyzed').length;
                processedCount = 0;
                currentJob = 'normalize';
            }
        }

        processedCount++;
        updateFileList();
        updateProgress(processedCount, totalCount, currentJob === 'analyze' ? '解析中' : '適用中');
        electronAPI.send('normalize-worker-finished-file');
    });
}