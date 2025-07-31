// uxmusic/src/renderer/js/virtual-scroller.js

export class VirtualScroller {
    constructor({ element, data, renderItem, itemHeight, buffer = 10 }) { // onScrollCallback を削除
        if (!element || !data || !renderItem || !itemHeight) {
            throw new Error("VirtualScroller: Missing required constructor options.");
        }

        this.container = element;
        this.data = data;
        this.renderItem = renderItem;
        this.itemHeight = itemHeight;
        this.buffer = buffer;

        this.container.style.position = 'relative';
        this.container.style.overflowY = 'auto';

        this.sizer = document.createElement('div');
        this.sizer.style.position = 'absolute';
        this.sizer.style.top = '0';
        this.sizer.style.left = '0';
        this.sizer.style.width = '1px';
        this.sizer.style.height = `${this.data.length * this.itemHeight}px`;
        this.container.appendChild(this.sizer);
        
        this.renderedItems = new Map();
        
        this.onScroll = this.onScroll.bind(this);
        this.container.addEventListener('scroll', this.onScroll, { passive: true });
        
        requestAnimationFrame(() => {
            this.render();
        });
    }

    onScroll() {
        if (!this.scrollTimeout) {
            this.scrollTimeout = requestAnimationFrame(() => {
                this.render();
                // onScrollCallback(); // ▼▼▼ この行を削除 ▼▼▼
                this.scrollTimeout = null;
            });
        }
    }

    render() {
        const scrollTop = this.container.scrollTop;
        const containerHeight = this.container.clientHeight;

        const startIndex = Math.max(0, Math.floor(scrollTop / this.itemHeight) - this.buffer);
        const endIndex = Math.min(this.data.length - 1, Math.ceil((scrollTop + containerHeight) / this.itemHeight) + this.buffer);

        const visibleIndexes = new Set();
        for (let i = startIndex; i <= endIndex; i++) {
            visibleIndexes.add(i);
            if (!this.renderedItems.has(i)) {
                const itemData = this.data[i];
                const element = this.renderItem(itemData, i);
                element.style.position = 'absolute';
                element.style.top = `${i * this.itemHeight}px`;
                element.style.left = '0';
                element.style.right = '0';
                element.style.height = `${this.itemHeight}px`;
                
                this.container.appendChild(element);
                this.renderedItems.set(i, element);
            }
        }
        
        for (const [index, element] of this.renderedItems.entries()) {
            if (!visibleIndexes.has(index)) {
                element.remove();
                this.renderedItems.delete(index);
            }
        }
    }

    updateData(newData) {
        this.data = newData;
        this.sizer.style.height = `${this.data.length * this.itemHeight}px`;
        for (const element of this.renderedItems.values()) {
            element.remove();
        }
        this.renderedItems.clear();

        requestAnimationFrame(() => this.render());
    }

    destroy() {
        this.container.removeEventListener('scroll', this.onScroll);
        this.container.innerHTML = '';
        if (this.scrollTimeout) {
            cancelAnimationFrame(this.scrollTimeout);
        }
    }
}