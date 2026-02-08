import { elements } from '../core/state.js'; // ★★★ 修正箇所 ★★★

let onOkCallback = null;
let modalRequiresInput = true;
let defaultModalDescription = '';

export function initModal() {
    const descEl = document.querySelector('#modal p');
    defaultModalDescription = descEl ? descEl.textContent : '';

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
    showModalAdvanced({
        title,
        placeholder,
        onOk,
        requireInput: true
    });
}

export function showModalAdvanced({
    title,
    message = null,
    placeholder = '',
    onOk,
    requireInput = true,
    okText = 'OK',
    cancelText = 'キャンセル'
}) {
    elements.modalTitle.textContent = title;
    onOkCallback = onOk;
    modalRequiresInput = requireInput;

    const descEl = document.querySelector('#modal p');
    if (descEl) {
        descEl.textContent = message || defaultModalDescription;
    }

    elements.modalInput.placeholder = placeholder;
    elements.modalInput.classList.toggle('hidden', !requireInput);
    elements.modalOkBtn.textContent = okText;
    elements.modalCancelBtn.textContent = cancelText;

    elements.modalInput.value = '';
    elements.modalOverlay.classList.remove('hidden');
    if (requireInput) {
        elements.modalInput.focus();
    } else {
        elements.modalOkBtn.focus();
    }
}

// --- 内部関数 ---
function hideModal() {
    elements.modalOverlay.classList.add('hidden');
    elements.modalInput.classList.remove('hidden');
    elements.modalOkBtn.textContent = 'OK';
    elements.modalCancelBtn.textContent = 'キャンセル';
    const descEl = document.querySelector('#modal p');
    if (descEl) {
        descEl.textContent = defaultModalDescription;
    }
    modalRequiresInput = true;
    onOkCallback = null;
}

function handleOkClick() {
    const value = elements.modalInput.value;
    if (modalRequiresInput && !value) {
        return;
    }
    if (onOkCallback) {
        onOkCallback(value);
    }
    hideModal();
}
