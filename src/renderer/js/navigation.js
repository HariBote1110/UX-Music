import { elements } from './state.js';

let onNavigateCallback = () => {};

export function initNavigation(onNavigate) {
    onNavigateCallback = onNavigate;

    elements.navLinks.forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            handleNavigation(link);
        });
    });
}

function handleNavigation(clickedLink) {
    elements.navLinks.forEach(l => l.classList.remove('active'));
    clickedLink.classList.add('active');
    
    const viewId = clickedLink.dataset.view;
    elements.views.forEach(view => {
        view.classList.toggle('hidden', view.id !== viewId);
    });

    onNavigateCallback(viewId);
}