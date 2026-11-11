import React, { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react';
import { supabase } from '@/lib/supabase';
import { queryClient } from '@/lib/queryClient';
import type { Agency, AgencyUser } from '@/lib/types';
import { useLocation } from 'wouter';
import { isPublicAuthPath } from '@/lib/auth';

interface AuthContextType {
  session: { id: string; email: string } | null;
  profile: AgencyUser | null;
  agency: Agency | null;
  isOwner: boolean;
  isOwnerOrManager: boolean;
  /** True when the owner has removed this user from the agency. */
  isDeactivated: boolean;
  isLoading: boolean;
  signOut: () => Promise<void>;
  /** Call this after agency setup completes to reload profile+agency without a page refresh. */
  refreshProfile: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

async function fetchProfileAndAgency(userId: string) {
  const { data: profileData } = await supabase
    .from('users')
    .select('*')
    .eq('id', userId)
    .single();

  if (!profileData) return { profile: null, agency: null };

  const { data: agencyData } = await supabase
    .from('agencies')
    .select('*')
    .eq('id', profileData.agency_id)
    .single();

  return { profile: profileData as AgencyUser, agency: agencyData as Agency | null };
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<{ id: string; email: string } | null>(null);
  const [profile, setProfile] = useState<AgencyUser | null>(null);
  const [agency, setAgency] = useState<Agency | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [, setLocation] = useLocation();
  // Id of the user the cached data belongs to; used to detect a user switch.
  const lastUserIdRef = useRef<string | null>(null);

  /** Explicitly reload profile + agency. Call after signup/setup completes. */
  const refreshProfile = useCallback(async () => {
    const { data: { session: current } } = await supabase.auth.getSession();
    if (!current?.user) return;
    const { profile: p, agency: a } = await fetchProfileAndAgency(current.user.id);
    if (p) setProfile(p);
    if (a) setAgency(a);
  }, []);

  useEffect(() => {
    let mounted = true;

    async function loadSession() {
      setIsLoading(true);
      const { data: { session: authSession } } = await supabase.auth.getSession();

      if (authSession?.user) {
        if (mounted) {
          lastUserIdRef.current = authSession.user.id;
          setSession({ id: authSession.user.id, email: authSession.user.email ?? '' });
        }
        const { profile: p, agency: a } = await fetchProfileAndAgency(authSession.user.id);
        if (mounted) {
          setProfile(p);
          setAgency(a);
          // User authenticated but no agency profile yet — send to registration to create one
          // (not while setting a new password from a reset link)
          if (!p && window.location.pathname !== '/register' && window.location.pathname !== '/join' && window.location.pathname !== '/reset-password') {
            setLocation('/register');
          }
        }
      } else {
        if (mounted) {
          setSession(null);
          setProfile(null);
          setAgency(null);
        }
      }

      if (mounted) setIsLoading(false);
    }

    loadSession();

    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, currentSession) => {
      if (!mounted) return;

      // Cached query data is keyed by agency, not user. Drop it whenever the
      // signed-in user changes (including sign-out) so the next login never
      // sees the previous user's data.
      const newUserId = currentSession?.user?.id ?? null;
      const userChanged = newUserId !== lastUserIdRef.current;
      if (userChanged) {
        queryClient.clear();
        lastUserIdRef.current = newUserId;
      }

      if (currentSession?.user) {
        setSession({ id: currentSession.user.id, email: currentSession.user.email ?? '' });

        // A password-reset link signs the user in; make sure they land on the
        // page that lets them choose a new password, wherever the link pointed.
        if (event === 'PASSWORD_RECOVERY' && window.location.pathname !== '/reset-password') {
          setLocation('/reset-password');
        }

        // On SIGNED_IN we may not yet have profile (e.g. first login, or token refresh).
        // Fetch it; register.tsx calls refreshProfile() explicitly after setup.
        if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
          const { profile: p, agency: a } = await fetchProfileAndAgency(currentSession.user.id);
          if (mounted) {
            // A different user just signed in: take the fetch result as-is, even
            // null, so the previous user's profile/agency can never linger. For
            // the same user (e.g. TOKEN_REFRESHED) keep the existing values if
            // the refetch comes back empty (transient failure).
            if (userChanged) {
              setProfile(p);
              setAgency(a);
            } else {
              if (p) setProfile(p);
              if (a) setAgency(a);
            }
          }
        }
      } else {
        setSession(null);
        setProfile(null);
        setAgency(null);
        const path = window.location.pathname;
        if (!isPublicAuthPath(path)) {
          setLocation('/login');
        }

      }
    });

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, [setLocation]);

  const signOut = async () => {
    await supabase.auth.signOut();
    queryClient.clear();
    lastUserIdRef.current = null;
    setProfile(null);
    setAgency(null);
    setSession(null);
    setLocation('/login');
  };

  const isOwner = profile?.role === 'owner';
  const isOwnerOrManager = profile?.role === 'owner' || profile?.role === 'manager';
  const isDeactivated = !!profile?.deactivated_at;

  return (
    <AuthContext.Provider value={{ session, profile, agency, isOwner, isOwnerOrManager, isDeactivated, isLoading, signOut, refreshProfile }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
