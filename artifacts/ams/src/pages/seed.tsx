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
      // Step 1: Sign up
      const { data: authData, error: signUpError } = await supabase.auth.signUp({ email, password });

      let session = authData?.session;
      let userId = authData?.user?.id;

      // If already registered, sign in instead
      if (signUpError?.message?.includes('already registered') || signUpError?.message?.includes('User already registered')) {
        const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({ email, password });
        if (signInError) throw signInError;
        session = signInData.session;
        userId = signInData.user?.id;
      } else if (signUpError) {
        throw signUpError;
      }

      if (!userId) throw new Error('Could not get user ID after sign-up.');

      // Step 2: Check if profile already exists
      const { data: existingUser } = await supabase
        .from('users')
        .select('id, agency_id')
        .eq('id', userId)
        .single();

      if (existingUser) {
        setResult({ status: 'success', message: 'Account already set up — use these credentials to log in.' });
        setLoading(false);
        return;
      }

      // Step 3: Create agency + owner via RPC (SECURITY DEFINER — browser-callable)
      const { error: rpcError } = await supabase.rpc('create_agency_with_owner', {
        p_auth_user_id: userId,
        p_agency_name: agencyName,
        p_owner_name: ownerName,
        p_owner_email: email,
        p_owner_phone: null,
      });

      if (rpcError) throw rpcError;

      // Sign out so user can log in fresh via the login page
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
            <CardContent className="space-y-4">
              <div className={`flex items-start gap-3 p-4 rounded-lg border ${result.status === 'success' ? 'bg-green-50 border-green-200 text-green-800' : 'bg-red-50 border-red-200 text-red-800'}`}>
                {result.status === 'success'
                  ? <CheckCircle2 className="w-5 h-5 mt-0.5 flex-shrink-0" />
                  : <AlertCircle className="w-5 h-5 mt-0.5 flex-shrink-0" />}
                <p className="text-sm">{result.message}</p>
              </div>

              {result.status === 'success' && (
                <div className="bg-muted rounded-lg p-4 space-y-2 font-mono text-sm">
                  <div className="flex justify-between items-center">
                    <div>
                      <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">Email</div>
                      <div className="font-medium">{email}</div>
                    </div>
                  </div>
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">Password</div>
                    <div className="font-medium">{password}</div>
                  </div>
                  <Button variant="outline" size="sm" className="w-full mt-2 gap-2" onClick={copyCredentials}>
                    <Copy className="w-3.5 h-3.5" />
                    {copied ? 'Copied!' : 'Copy credentials'}
                  </Button>
                </div>
              )}
            </CardContent>
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
                  {loading ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : null}
                  Create account & agency
                </Button>
              </CardFooter>
            </form>
          )}

          {result?.status === 'success' && (
            <CardFooter className="pt-0">
              <a href="/login" className="w-full">
                <Button className="w-full">Go to login →</Button>
              </a>
            </CardFooter>
          )}
        </Card>
      </div>
    </div>
  );
}
