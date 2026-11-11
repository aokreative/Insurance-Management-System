import React, { useState } from 'react';
import { supabase } from '@/lib/supabase';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { BrandLockup } from '@/components/BrandLockup';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { Loader2, AlertCircle, MailCheck } from 'lucide-react';

export default function ForgotPassword() {
  const [email, setEmail] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/reset-password`,
    });
    setLoading(false);
    if (resetError) {
      // Rate limits and network failures are worth showing; an unknown email is not
      // reported by Supabase, so nobody can probe which addresses have accounts.
      setError(
        resetError.message.toLowerCase().includes('rate limit')
          ? 'Too many reset emails were requested. Wait a few minutes and try again.'
          : resetError.message || 'Could not send the reset email. Please try again.',
      );
      return;
    }
    setSent(true);
  };

  return (
    <div className="min-h-screen bg-background flex flex-col justify-center items-center p-4">
      <div className="w-full max-w-md">
        <div className="flex justify-center mb-8">
          <BrandLockup />
        </div>

        <Card className="border-border/50 shadow-xl">
          <CardHeader className="space-y-1 pb-6">
            <CardTitle className="text-2xl font-bold tracking-tight text-center">Reset your password</CardTitle>
            <CardDescription className="text-center">
              {sent ? 'Check your inbox.' : "Enter your email and we'll send you a link to set a new password."}
            </CardDescription>
          </CardHeader>

          {sent ? (
            <>
              <CardContent>
                <div className="flex items-start gap-3 p-3 rounded-lg bg-muted text-sm">
                  <MailCheck className="w-4 h-4 mt-0.5 shrink-0 text-primary" />
                  <span>
                    If an account exists for <strong>{email.trim()}</strong>, a reset link is on its way. It can take a
                    minute; check your spam folder too.
                  </span>
                </div>
              </CardContent>
              <CardFooter className="flex flex-col space-y-3 pt-4">
                <Button variant="outline" className="w-full" onClick={() => setSent(false)}>
                  Send to a different email
                </Button>
                <a href="/login" className="text-xs text-primary font-medium hover:underline">
                  Back to sign in
                </a>
              </CardFooter>
            </>
          ) : (
            <form onSubmit={handleSubmit}>
              <CardContent className="space-y-4">
                {error && (
                  <div className="flex items-start gap-3 p-3 rounded-lg bg-destructive/10 border border-destructive/20 text-destructive text-sm">
                    <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
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
                    onChange={(e) => { setEmail(e.target.value); setError(null); }}
                    required
                    disabled={loading}
                    autoComplete="email"
                  />
                </div>
              </CardContent>
              <CardFooter className="flex flex-col space-y-3 pt-4">
                <Button type="submit" className="w-full" disabled={loading || !email.trim()}>
                  {loading && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
                  Send reset link
                </Button>
                <a href="/login" className="text-xs text-primary font-medium hover:underline">
                  Back to sign in
                </a>
              </CardFooter>
            </form>
          )}
        </Card>
      </div>
    </div>
  );
}
