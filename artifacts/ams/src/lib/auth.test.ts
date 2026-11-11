import { describe, expect, it } from 'vitest';
import { isPublicAuthPath, newPasswordError } from './auth';

describe('newPasswordError', () => {
  it('needs at least 8 characters', () => {
    expect(newPasswordError('short', 'short')).toBe('Password must be at least 8 characters.');
  });
  it('needs both entries to match', () => {
    expect(newPasswordError('longenough1', 'longenough2')).toBe("The passwords don't match.");
  });
  it('accepts a valid matching password', () => {
    expect(newPasswordError('longenough1', 'longenough1')).toBeNull();
  });
});

describe('isPublicAuthPath', () => {
  it('sign-in pages, including password reset, are public', () => {
    for (const p of ['/login', '/register', '/join', '/forgot-password', '/reset-password']) {
      expect(isPublicAuthPath(p)).toBe(true);
    }
  });
  it('app pages are not', () => {
    expect(isPublicAuthPath('/dashboard')).toBe(false);
  });
});
