import React, { useState } from 'react';
import { supabase } from '@/lib/supabase';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { ShieldCheck, Loader2, CheckCircle2, AlertCircle, Copy } from 'lucide-react';

export default function Seed() {
  const [agencyName, setAgencyName] = useState('Demo Agency');
  const [ownerName, setOwnerName] = useState('Demo Owner');
  const [email, setEmail] = useState('demo@ams.co.ke');
  const [password, setPassword] = useState('Demo@2026!');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<{ status: 'success' | 'error'; message: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const handleSetup = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setResult(null);

    try {
      let userId: string | undefined;

      // Step 1: Try signing up
      const { data: authData, error: signUpError } = await supabase.auth.signUp({ email, password });

      if (signUpError) {
        // Already registered — sign in to get a valid session
        if (
          signUpError.message.toLowerCase().includes('already registered') ||
          signUpError.message.toLowerCase().includes('user already registered')
        ) {
          const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({ email, password });
          if (signInError) throw new Error(`Sign-in failed: ${signInError.message}`);
          userId = signInData.user?.id;
        } else {
          throw new Error(`Sign-up failed: ${signUpError.message}`);
        }
      } else {
        userId = authData.user?.id;

        // If session is null after signup (email confirmation required), sign in now
        if (!authData.session && userId) {
          const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({ email, password });
          if (signInError) throw new Error(
            `Account created but sign-in failed. ` +
            `Check your Supabase dashboard → Authentication → Email and disable "Confirm email". ` +
            `Error: ${signInError.message}`
          );
          userId = signInData.user?.id ?? userId;
        }
      }

      if (!userId) throw new Error('Could not resolve user ID.');

      // Step 2: Check if profile already exists
      const { data: existingUser, error: profileCheckError } = await supabase
        .from('users')
        .select('id, agency_id')
        .eq('id', userId)
        .single();

      // If the table doesn't exist yet, give an actionable message
      if (profileCheckError && profileCheckError.code !== 'PGRST116') {
        const msg = profileCheckError.message.toLowerCase();
        if (msg.includes('does not exist') || msg.includes('relation') || msg.includes('schema')) {
          throw new Error(
            'Database tables not found. Please apply the SQL migrations first:\n' +
            '1. Open your Supabase dashboard → SQL Editor\n' +
            '2. Run supabase/migrations/001_initial_schema.sql\n' +
            '3. Run supabase/migrations/002_auto_renewal_reminders.sql\n' +
            '4. Then come back here and try again.'
          );
        }
        throw new Error(`Profile check failed: ${profileCheckError.message}`);
      }

      if (existingUser) {
        await supabase.auth.signOut();
        setResult({ status: 'success', message: 'Account already set up — use these credentials to log in.' });
        setLoading(false);
        return;
      }

      // Step 3: Create agency + owner via RPC (SECURITY DEFINER, requires active session)
      const { error: rpcError } = await supabase.rpc('create_agency_with_owner', {
        p_auth_user_id: userId,
        p_agency_name: agencyName,
        p_owner_name: ownerName,
        p_owner_email: email,
        p_owner_phone: null,
      });

      if (rpcError) {
        if (rpcError.message.toLowerCase().includes('does not exist') || rpcError.code === '42883') {
          throw new Error(
            'Setup function not found. Apply the SQL migrations in your Supabase SQL Editor first, then try again.'
          );
        }
        throw new Error(`Agency setup failed: ${rpcError.message}`);
      }

      // Sign out so user logs in fresh
      await supabase.auth.signOut();

      setResult({ status: 'success', message: 'Account created! Use the credentials below to log in.' });
    } catch (err: any) {
      setResult({ status: 'error', message: err.message || 'Something went wrong.' });
    } finally {
      setLoading(false);
    }
  };

  const copyCredentials = () => {
    navigator.clipboard.writeText(`Email: ${email}\nPassword: ${password}`);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
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
          <CardHeader className="space-y-1 pb-4">
            <CardTitle className="text-xl font-bold tracking-tight text-center">Create Demo Account</CardTitle>
            <CardDescription className="text-center text-xs">
              One-time setup — creates a user + agency in Supabase directly from the browser.
              <br />
              <span className="text-amber-600 font-medium">Apply SQL migrations first if you haven't already.</span>
            </CardDescription>
          </CardHeader>

          {result ? (
            <>
              <CardContent className="space-y-4">
                <div className={`flex items-start gap-3 p-4 rounded-lg border ${result.status === 'success' ? 'bg-green-50 border-green-200 text-green-800' : 'bg-red-50 border-red-200 text-red-800'}`}>
                  {result.status === 'success'
                    ? <CheckCircle2 className="w-5 h-5 mt-0.5 flex-shrink-0" />
                    : <AlertCircle className="w-5 h-5 mt-0.5 flex-shrink-0" />}
                  <p className="text-sm whitespace-pre-line">{result.message}</p>
                </div>

                {result.status === 'success' && (
                  <div className="bg-muted rounded-lg p-4 space-y-3 font-mono text-sm">
                    <div>
                      <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">Email</div>
                      <div className="font-medium">{email}</div>
                    </div>
                    <div>
                      <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">Password</div>
                      <div className="font-medium">{password}</div>
                    </div>
                    <Button variant="outline" size="sm" className="w-full mt-1 gap-2" onClick={copyCredentials}>
                      <Copy className="w-3.5 h-3.5" />
                      {copied ? 'Copied!' : 'Copy credentials'}
                    </Button>
                  </div>
                )}

                {result.status === 'error' && (
                  <Button variant="outline" className="w-full" onClick={() => setResult(null)}>
                    Try again
                  </Button>
                )}
              </CardContent>

              {result.status === 'success' && (
                <CardFooter className="pt-0">
                  <a href="/login" className="w-full">
                    <Button className="w-full">Go to login →</Button>
                  </a>
                </CardFooter>
              )}
            </>
          ) : (
            <form onSubmit={handleSetup}>
              <CardContent className="space-y-3">
                <div className="space-y-1.5">
                  <Label htmlFor="agencyName">Agency name</Label>
                  <Input id="agencyName" value={agencyName} onChange={e => setAgencyName(e.target.value)} required disabled={loading} />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="ownerName">Your name</Label>
                  <Input id="ownerName" value={ownerName} onChange={e => setOwnerName(e.target.value)} required disabled={loading} />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="email">Email</Label>
                  <Input id="email" type="email" value={email} onChange={e => setEmail(e.target.value)} required disabled={loading} />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="password">Password</Label>
                  <Input id="password" type="password" value={password} onChange={e => setPassword(e.target.value)} required disabled={loading} />
                </div>
              </CardContent>
              <CardFooter className="pt-2">
                <Button type="submit" className="w-full" disabled={loading}>
                  {loading && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
                  Create account & agency
                </Button>
              </CardFooter>
            </form>
          )}
        </Card>
      </div>
    </div>
  );
}
