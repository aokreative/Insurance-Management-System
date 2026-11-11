export const MIN_PASSWORD_LENGTH = 8;

/** Pages a signed-out visitor may stay on (the auth context does not bounce them to /login). */
const PUBLIC_AUTH_PATHS = ['/login', '/register', '/join', '/forgot-password', '/reset-password'];

export function isPublicAuthPath(path: string): boolean {
  return PUBLIC_AUTH_PATHS.includes(path);
}

/** Validation for choosing a new password; null when it is acceptable. */
export function newPasswordError(password: string, confirm: string): string | null {
  if (password.length < MIN_PASSWORD_LENGTH) return `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`;
  if (password !== confirm) return "The passwords don't match.";
  return null;
}
