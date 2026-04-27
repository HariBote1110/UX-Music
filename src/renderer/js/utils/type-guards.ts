/** Narrow `unknown` JSON-like values to a plain object record. */
export function readRecord(value: unknown): Record<string, unknown> {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

export function youtubeUrlFromPayload(payload: unknown): string {
  if (typeof payload === 'string') return payload.trim();
  const rec = readRecord(payload);
  const url = rec.url;
  return typeof url === 'string' ? url.trim() : '';
}
