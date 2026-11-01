import { QueryClient } from '@tanstack/react-query';

/**
 * Shared QueryClient. Lives in its own module so AuthContext can clear the
 * cache when the signed-in user changes (cached rows are scoped by agency, not
 * by user, so a different login in the same tab must never see them).
 */
export const queryClient = new QueryClient();
