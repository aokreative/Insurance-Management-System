import React, { useState } from 'react';
import { useLocation } from 'wouter';
import { supabase } from '@/lib/supabase';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { ShieldCheck, Loader2, AlertCircle } from 'lucide-react';

export default function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [, setLocation] = useLocation();

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);

    try {
      const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });

      if (signInError) {
        // Give friendly, specific messages
        if (signInError.message.toLowerCase().includes('invalid login credentials') ||
            signInError.message.toLowerCase().includes('invalid credentials')) {
          throw new Error('Incorrect email or password. Double-check and try again.');
        }
        if (signInError.message.toLowerCase().includes('email not confirmed')) {
          throw new Error(
            'Your email has not been confirmed. Go to your Supabase dashboard → Authentication → Email settings and disable "Confirm email", then try again.'
          );
        }
        if (signInError.message.toLowerCase().includes('fetch') ||
            signInError.message.toLowerCase().includes('network') ||
            signInError.message.toLowerCase().includes('failed')) {
          throw new Error(
            'Could not reach the database. Check that your Supabase project is active (it may be paused on the free tier) and that your URL/key secrets are correct.'
          );
        }
        throw signInError;
      }

      setLocation('/dashboard');
    } catch (err: any) {
      setError(err.message || 'Login failed. Please try again.');
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
            <CardTitle className="text-2xl font-bold tracking-tight text-center">Welcome back</CardTitle>
            <CardDescription className="text-center">
              Enter your credentials to access your agency cockpit
            </CardDescription>
          </CardHeader>

          <form onSubmit={handleLogin}>
            <CardContent className="space-y-4">
              {error && (
                <div className="flex items-start gap-3 p-3 rounded-lg bg-destructive/10 border border-destructive/20 text-destructive text-sm">
                  <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
                  <span>{error}</span>
                </div>
              )}

              <div className="space-y-2">
                <Label htmlFor="email">Email address</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="agent@brokerage.co.ke"
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
                  value={password}
                  onChange={e => { setPassword(e.target.value); setError(null); }}
                  required
                  disabled={loading}
                  autoComplete="current-password"
                />
              </div>
            </CardContent>

            <CardFooter className="flex flex-col space-y-3 pt-4">
              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
                Sign in
              </Button>
              <p className="text-xs text-center text-muted-foreground">
                No account yet?{' '}
                <a href="/seed" className="text-primary font-medium hover:underline">
                  Create a demo account
                </a>
              </p>
            </CardFooter>
          </form>
        </Card>
      </div>
    </div>
  );
}
