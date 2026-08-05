import React, { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { supabase } from '@/lib/supabase';
import type { Agency, AgencyUser } from '@/lib/types';
import { useLocation } from 'wouter';

interface AuthContextType {
  session: { id: string; email: string } | null;
  profile: AgencyUser | null;
  agency: Agency | null;
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
          setSession({ id: authSession.user.id, email: authSession.user.email ?? '' });
        }
        const { profile: p, agency: a } = await fetchProfileAndAgency(authSession.user.id);
        if (mounted) {
          if (p) setProfile(p);
          if (a) setAgency(a);
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

      if (currentSession?.user) {
        setSession({ id: currentSession.user.id, email: currentSession.user.email ?? '' });

        // On SIGNED_IN we may not yet have profile (e.g. first login, or token refresh).
        // Fetch it; register.tsx calls refreshProfile() explicitly after setup.
        if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
          const { profile: p, agency: a } = await fetchProfileAndAgency(currentSession.user.id);
          if (mounted) {
            if (p) setProfile(p);
            if (a) setAgency(a);
          }
        }
      } else {
        setSession(null);
        setProfile(null);
        setAgency(null);
        const path = window.location.pathname;
        if (path !== '/login' && path !== '/register' && path !== '/seed') {
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
    setProfile(null);
    setAgency(null);
    setSession(null);
    setLocation('/login');
  };

  return (
    <AuthContext.Provider value={{ session, profile, agency, isLoading, signOut, refreshProfile }}>
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
