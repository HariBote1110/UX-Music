export function buildSafeMediaPathURL(path: string): string {
    if (typeof path !== 'string' || path.trim() === '') return '';
    const relativePath = path
        .replace(/\\/g, '/')
        .replace(/^\/+/, '');
    const safePath = relativePath
        .split('/')
        .map(segment => encodeURIComponent(segment))
        .join('/');
    return `/safe-media/${safePath}`;
}
