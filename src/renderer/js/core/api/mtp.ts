// src/renderer/js/core/api/mtp.ts
// MTP操作のWailsバインドラッパー

import { getWailsApp } from '../bridge.js';

export async function mtpBrowseDirectory(opts: { storageId: number; fullPath: string }): Promise<Record<string, unknown>> {
    const app = getWailsApp();
    if (!app) return { error: 'Wails not available' };
    try {
        const result = await app.MTPWalk({
            storageId: opts.storageId,
            fullPath: opts.fullPath,
            recursive: false,
            skipDisallowedFiles: true,
            skipHiddenFiles: false,
        });
        return (result as Record<string, unknown>) ?? {};
    } catch (err) {
        return { error: (err as Error).message };
    }
}

export async function mtpSelectDownloadFolder(): Promise<string | null> {
    const app = getWailsApp();
    if (!app) return null;
    try {
        return await app.SelectMTPDownloadFolder() as string | null;
    } catch {
        return null;
    }
}

export async function mtpDownloadFiles(opts: { storageId: number; sources: string[]; destination: string }): Promise<Record<string, unknown>> {
    const app = getWailsApp();
    if (!app) return { error: 'Wails not available' };
    try {
        await app.MTPDownloadFiles({
            storageId: opts.storageId,
            sources: opts.sources,
            destination: opts.destination,
        });
        return {};
    } catch (err) {
        return { error: (err as Error).message };
    }
}

export async function mtpDeleteFiles(opts: { storageId: number; files: string[] }): Promise<Record<string, unknown>> {
    const app = getWailsApp();
    if (!app) return { error: 'Wails not available' };
    try {
        await app.MTPDeleteFile({
            storageId: opts.storageId,
            files: opts.files,
        });
        return {};
    } catch (err) {
        return { error: (err as Error).message };
    }
}
