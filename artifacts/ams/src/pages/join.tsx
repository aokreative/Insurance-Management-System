import React, { useEffect, useState } from 'react';
import { Link, useLocation } from 'wouter';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { BrandLockup } from '@/components/BrandLockup';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { Loader2, AlertCircle } from 'lucide-react';

interface InvitePreview {
  agency_name: string;
  role: string;
  email: string;
}

const INVALID_LINK =
  'This invite link is invalid or has expired. Ask the person who invited you for a new one.';

function capitalise(s: string) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-background flex flex-col justify-center items-center p-4">
      <div className="w-full max-w-md">
        <div className="flex justify-center mb-8">
          <BrandLockup />
        </div>
        <Card className="border-border/50 shadow-xl">{children}</Card>
      </div>
    </div>
  );
}

function ErrorBox({ message }: { message: string }) {
  return (
    <div className="flex items-start gap-3 p-3 rounded-lg bg-destructive/10 border border-destructive/20 text-destructive text-sm">
      <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
      <span>{message}</span>
    </div>
  );
}

export default function Join() {
  const code = new URLSearchParams(window.location.search).get('code');
  const { session, profile, isLoading: authLoading, refreshProfile } = useAuth();
  const [, setLocation] = useLocation();

  const [preview, setPreview] = useState<InvitePreview | null>(null);
  const [previewLoading, setPreviewLoading] = useState(true);
  const [previewError, setPreviewError] = useState<string | null>(null);

  const [mode, setMode] = useState<'signup' | 'signin'>('signup');
  const [fullName, setFullName] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!code) {
        setPreviewError(INVALID_LINK);
        setPreviewLoading(false);
        return;
      }
      const { data, error: rpcError } = await supabase.rpc('get_invite_preview', { p_code: code });
      if (cancelled) return;
      if (rpcError || !data) {
        setPreviewError(INVALID_LINK);
      } else {
        const row = (Array.isArray(data) ? data[0] : data) as InvitePreview | undefined;
        if (row) setPreview(row);
        else setPreviewError(INVALID_LINK);
      }
      setPreviewLoading(false);
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, [code]);

  const accept = async () => {
    const { error: rpcError } = await supabase.rpc('accept_invite', {
      p_code: code,
      p_full_name: fullName.trim(),
    });
    if (rpcError) throw new Error(rpcError.message);
    await refreshProfile();
    setLocation('/dashboard');
  };

  // Signed-in visitor with a matching email and no profile: just accept.
  const handleAcceptSignedIn = async (e: React.FormEvent) => {
    e.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      await accept();
    } catch (err: any) {
      setError(err.message || 'Something went wrong. Please try again.');
    } finally {
      setSubmitting(false);
    }
  };

  // Signed-out visitor: sign up (or sign in), then accept.
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (submitting || !preview) return;
    setError(null);

    if (!fullName.trim()) {
      setError('Enter your full name');
      return;
    }
    if (mode === 'signup' && password.length < 8) {
      setError('Password must be at least 8 characters.');
      return;
    }
    if (mode === 'signin' && !password) {
      setError('Enter your password.');
      return;
    }

    setSubmitting(true);
    const email = preview.email;
    try {
      if (mode === 'signin') {
        const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
        if (signInError) throw new Error(signInError.message);
      } else {
        const { data: authData, error: signUpError } = await supabase.auth.signUp({ email, password });
        if (signUpError) {
          const msg = signUpError.message.toLowerCase();
          if (msg.includes('already registered') || msg.includes('user already registered')) {
            const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
            if (signInError) {
              throw new Error('An account with this email already exists. Sign in instead with your existing password.');
            }
          } else {
            throw new Error(signUpError.message);
          }
        } else if (!authData.session) {
          const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
          if (signInError) {
            throw new Error(
              'Account created but could not sign in automatically. ' +
                'Disable "Confirm email" in your Supabase Auth settings, then try again.'
            );
          }
        }
      }
      await accept();
    } catch (err: any) {
      setError(err.message || 'Something went wrong. Please try again.');
    } finally {
      setSubmitting(false);
    }
  };

  const handleSignOut = async () => {
    setError(null);
    // Use supabase directly so we stay on /join (context signOut redirects to /login).
    await supabase.auth.signOut();
  };

  if (previewLoading || authLoading) {
    return (
      <Shell>
        <CardContent className="py-12 flex justify-center">
          <Loader2 className="w-6 h-6 animate-spin text-muted-foreground" />
        </CardContent>
      </Shell>
    );
  }

  if (previewError || !preview) {
    return (
      <Shell>
        <CardHeader className="space-y-1">
          <CardTitle className="text-2xl font-bold tracking-tight text-center">Invite unavailable</CardTitle>
        </CardHeader>
        <CardContent>
          <ErrorBox message={previewError ?? INVALID_LINK} />
        </CardContent>
        <CardFooter>
          <p className="text-sm text-center text-muted-foreground w-full">
            <Link href="/login" className="text-primary font-medium hover:underline">
              Go to sign in
            </Link>
          </p>
        </CardFooter>
      </Shell>
    );
  }

  const roleLabel = capitalise(preview.role);
  const header = (
    <CardHeader className="space-y-1 pb-6">
      <CardTitle className="text-2xl font-bold tracking-tight text-center">Join {preview.agency_name}</CardTitle>
      <CardDescription className="text-center">You've been invited as {roleLabel}</CardDescription>
    </CardHeader>
  );

  // Keep the form on screen while a submit is in flight, even though the session appears mid-way.
  if (session && !submitting) {
    if (profile) {
      return (
        <Shell>
          {header}
          <CardContent className="space-y-4">
            <p className="text-sm text-center">This account already belongs to an agency</p>
          </CardContent>
          <CardFooter>
            <Button asChild className="w-full">
              <Link href="/dashboard">Go to dashboard</Link>
            </Button>
          </CardFooter>
        </Shell>
      );
    }

    if (session.email.toLowerCase() !== preview.email.toLowerCase()) {
      return (
        <Shell>
          {header}
          <CardContent className="space-y-4">
            {error && <ErrorBox message={error} />}
            <p className="text-sm text-center">
              You're signed in as {session.email}. Sign out to accept this invite.
            </p>
          </CardContent>
          <CardFooter>
            <Button className="w-full" onClick={() => { void handleSignOut(); }}>
              Sign out
            </Button>
          </CardFooter>
        </Shell>
      );
    }

    return (
      <Shell>
        {header}
        <form onSubmit={handleAcceptSignedIn}>
          <CardContent className="space-y-4">
            {error && <ErrorBox message={error} />}
            <div className="space-y-2">
              <Label htmlFor="email">Email address</Label>
              <Input id="email" type="email" value={preview.email} disabled />
            </div>
            <div className="space-y-2">
              <Label htmlFor="fullName">Your full name</Label>
              <Input
                id="fullName"
                placeholder="Jane Kamau"
                value={fullName}
                onChange={e => { setFullName(e.target.value); setError(null); }}
                required
                disabled={submitting}
                autoComplete="name"
              />
            </div>
          </CardContent>
          <CardFooter className="pt-4">
            <Button type="submit" className="w-full" disabled={submitting}>
              {submitting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              Join {preview.agency_name}
            </Button>
          </CardFooter>
        </form>
      </Shell>
    );
  }

  return (
    <Shell>
      {header}
      <form onSubmit={handleSubmit}>
        <CardContent className="space-y-4">
          {error && <ErrorBox message={error} />}

          <div className="space-y-2">
            <Label htmlFor="email">Email address</Label>
            <Input id="email" type="email" value={preview.email} disabled />
          </div>

          {(
            <div className="space-y-2">
              <Label htmlFor="fullName">Your full name</Label>
              <Input
                id="fullName"
                placeholder="Jane Kamau"
                value={fullName}
                onChange={e => { setFullName(e.target.value); setError(null); }}
                required
                disabled={submitting}
                autoComplete="name"
              />
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="password">Password</Label>
            <Input
              id="password"
              type="password"
              placeholder={mode === 'signup' ? 'At least 8 characters' : 'Your password'}
              value={password}
              onChange={e => { setPassword(e.target.value); setError(null); }}
              required
              minLength={mode === 'signup' ? 8 : undefined}
              disabled={submitting}
              autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
            />
          </div>
        </CardContent>

        <CardFooter className="flex flex-col space-y-3 pt-4">
          <Button type="submit" className="w-full" disabled={submitting}>
            {submitting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            {submitting
              ? 'Joining…'
              : mode === 'signup'
                ? `Join ${preview.agency_name}`
                : 'Sign in and join'}
          </Button>
          <p className="text-sm text-center text-muted-foreground">
            {mode === 'signup' ? 'Already have an account?' : 'New here?'}{' '}
            <button
              type="button"
              className="text-primary font-medium hover:underline"
              disabled={submitting}
              onClick={() => { setMode(mode === 'signup' ? 'signin' : 'signup'); setError(null); }}
            >
              {mode === 'signup' ? 'Sign in instead' : 'Create an account'}
            </button>
          </p>
        </CardFooter>
      </form>
    </Shell>
  );
}
