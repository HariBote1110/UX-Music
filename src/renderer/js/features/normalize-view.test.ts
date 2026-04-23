import { describe, expect, it } from 'vitest';
import { getNormalizeViewHtml, NORMALIZE_VIEW_REQUIRED_ELEMENT_IDS } from './normalize-view-html.js';

describe('getNormalizeViewHtml', () => {
    it('includes required element ids for the normalize workflow', () => {
        const html = getNormalizeViewHtml();
        for (const id of NORMALIZE_VIEW_REQUIRED_ELEMENT_IDS) {
            expect(html).toContain(`id="${id}"`);
        }
    });
});
