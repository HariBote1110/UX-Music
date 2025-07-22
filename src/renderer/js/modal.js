import { elements } from './state.js';

let onOkCallback = null;

// ★★★ バグ修正: 引数を削除し、state.jsから直接elementsを読み込む ★★★
export function initModal() {
    // --- イベントリスナー ---
    elements.modalCancelBtn.addEventListener('click', hideModal);
    elements.modalOkBtn.addEventListener('click', handleOkClick);
    elements.modalOverlay.addEventListener('click', (event) => {
        if (event.target === elements.modalOverlay) {
            hideModal();
        }
    });
}

// --- 公開関数 ---
export function showModal({ title, placeholder, onOk }) {
    // ★★★ modalTitleの参照を修正 ★★★
    elements.modalTitle.textContent = title;
    elements.modalInput.placeholder = placeholder;
    onOkCallback = onOk;

    elements.modalInput.value = '';
    elements.modalOverlay.classList.remove('hidden');
    elements.modalInput.focus();
}

// --- 内部関数 ---
function hideModal() {
    elements.modalOverlay.classList.add('hidden');
    onOkCallback = null;
}

function handleOkClick() {
    const value = elements.modalInput.value;
    if (value && onOkCallback) {
        onOkCallback(value);
    }
    hideModal();
}