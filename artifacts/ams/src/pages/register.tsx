import React, { useState } from 'react';
import { Link, useLocation } from 'wouter';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { ShieldCheck, Loader2, AlertCircle } from 'lucide-react';

export default function Register() {
  const [agencyName, setAgencyName] = useState('');
  const [ownerName, setOwnerName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { refreshProfile } = useAuth();
  const [, setLocation] = useLocation();

  const handleRegister = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);

    try {
      let userId: string | undefined;

      // Step 1: Sign up
      const { data: authData, error: signUpError } = await supabase.auth.signUp({ email, password });

      if (signUpError) {
        if (
          signUpError.message.toLowerCase().includes('already registered') ||
          signUpError.message.toLowerCase().includes('user already registered')
        ) {
          // Already exists — sign in to get a session
          const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({ email, password });
          if (signInError) throw new Error('An account with this email already exists. Try logging in instead.');
          userId = signInData.user?.id;
        } else {
          throw new Error(signUpError.message);
        }
      } else {
        userId = authData.user?.id;

        // If email confirmation is required, session will be null — sign in immediately
        if (!authData.session && userId) {
          const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({ email, password });
          if (signInError) throw new Error(
            'Account created but could not sign in automatically. ' +
            'Disable "Confirm email" in your Supabase Auth settings, then try again.'
          );
          userId = signInData.user?.id ?? userId;
        }
      }

      if (!userId) throw new Error('Could not create account. Please try again.');

      // Step 2: Check if this user already has an agency profile
      const { data: existingProfile } = await supabase
        .from('users')
        .select('id, agency_id')
        .eq('id', userId)
        .single();

      if (existingProfile) {
        // Already set up — just load the profile and go to dashboard
        await refreshProfile();
        setLocation('/dashboard');
        return;
      }

      // Step 3: Create agency + owner profile via RPC (SECURITY DEFINER)
      const { error: rpcError } = await supabase.rpc('create_agency_with_owner', {
        p_auth_user_id: userId,
        p_agency_name: agencyName,
        p_owner_name: ownerName,
        p_owner_email: email,
        p_owner_phone: null,
      });

      if (rpcError) {
        if (rpcError.code === '42883' || rpcError.message.toLowerCase().includes('does not exist')) {
          throw new Error('Database not ready. Make sure all SQL migrations have been applied in Supabase.');
        }
        throw new Error(rpcError.message);
      }

      // Step 4: Load profile into context and navigate to dashboard
      await refreshProfile();
      setLocation('/dashboard');
    } catch (err: any) {
      setError(err.message || 'Something went wrong. Please try again.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-background flex flex-col justify-center items-center p-4">
      <div className="w-full max-w-md">
        <div className="flex justify-center mb-8">
          <div className="flex items-center gap-2 text-primary">
            <ShieldCheck className="w-10 h-10" />
            <span className="text-3xl font-bold tracking-tight">AMS</span>
          </div>
        </div>

        <Card className="border-border/50 shadow-xl">
          <CardHeader className="space-y-1 pb-6">
            <CardTitle className="text-2xl font-bold tracking-tight text-center">Create your agency</CardTitle>
            <CardDescription className="text-center">
              Set up your account and start managing policies in minutes.
            </CardDescription>
          </CardHeader>

          <form onSubmit={handleRegister}>
            <CardContent className="space-y-4">
              {error && (
                <div className="flex items-start gap-3 p-3 rounded-lg bg-destructive/10 border border-destructive/20 text-destructive text-sm">
                  <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
                  <span>{error}</span>
                </div>
              )}

              <div className="space-y-2">
                <Label htmlFor="agencyName">Agency name</Label>
                <Input
                  id="agencyName"
                  placeholder="Acme Insurance Brokers"
                  value={agencyName}
                  onChange={e => { setAgencyName(e.target.value); setError(null); }}
                  required
                  disabled={loading}
                  autoComplete="organization"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="ownerName">Your full name</Label>
                <Input
                  id="ownerName"
                  placeholder="Jane Kamau"
                  value={ownerName}
                  onChange={e => { setOwnerName(e.target.value); setError(null); }}
                  required
                  disabled={loading}
                  autoComplete="name"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="email">Email address</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="jane@acmebrokers.co.ke"
                  value={email}
                  onChange={e => { setEmail(e.target.value); setError(null); }}
                  required
                  disabled={loading}
                  autoComplete="email"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="password">Password</Label>
                <Input
                  id="password"
                  type="password"
                  placeholder="At least 8 characters"
                  value={password}
                  onChange={e => { setPassword(e.target.value); setError(null); }}
                  required
                  minLength={8}
                  disabled={loading}
                  autoComplete="new-password"
                />
              </div>
            </CardContent>

            <CardFooter className="flex flex-col space-y-3 pt-4">
              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
                {loading ? 'Setting up your agency…' : 'Create agency account'}
              </Button>
              <p className="text-sm text-center text-muted-foreground">
                Already have an account?{' '}
                <Link href="/login" className="text-primary font-medium hover:underline">
                  Sign in
                </Link>
              </p>
            </CardFooter>
          </form>
        </Card>
      </div>
    </div>
  );
}
