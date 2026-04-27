import { describe, expect, it } from 'vitest';
import { errorMessage, readRecord, youtubeUrlFromPayload } from './type-guards.js';

describe('readRecord', () => {
  it('returns empty object for primitives', () => {
    expect(readRecord(null)).toEqual({});
    expect(readRecord(undefined)).toEqual({});
    expect(readRecord(42)).toEqual({});
    expect(readRecord('x')).toEqual({});
  });

  it('returns plain objects', () => {
    expect(readRecord({ a: 1 })).toEqual({ a: 1 });
  });

  it('does not treat arrays as records', () => {
    expect(readRecord([1, 2])).toEqual({});
  });
});

describe('youtubeUrlFromPayload', () => {
  it('trims string payloads', () => {
    expect(youtubeUrlFromPayload('  https://example.com  ')).toBe('https://example.com');
  });

  it('reads url from object', () => {
    expect(youtubeUrlFromPayload({ url: ' https://x.test ' })).toBe('https://x.test');
  });

  it('returns empty string when missing', () => {
    expect(youtubeUrlFromPayload({})).toBe('');
  });
});

describe('errorMessage', () => {
  it('uses Error.message', () => {
    expect(errorMessage(new Error('x'))).toBe('x');
  });

  it('stringifies non-errors', () => {
    expect(errorMessage(new String('x'))).toBe('x');
  });
});
