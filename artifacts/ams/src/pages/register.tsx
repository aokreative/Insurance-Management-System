import React, { useState } from 'react';
import { useLocation, Link } from 'wouter';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { ShieldCheck, Loader2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';

export default function Register() {
  const { refreshProfile } = useAuth();
  const [formData, setFormData] = useState({
    agencyName: '',
    ownerName: '',
    phone: '',
    email: '',
    password: '',
  });
  const [loading, setLoading] = useState(false);
  const [, setLocation] = useLocation();
  const { toast } = useToast();

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData(prev => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleRegister = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    
    try {
      // 1. Sign up user
      const { data: authData, error: authError } = await supabase.auth.signUp({
        email: formData.email,
        password: formData.password,
      });

      if (authError) throw authError;
      if (!authData.session) throw new Error("No session returned from signup");

      // 2. Call API to set up agency & profile
      const response = await fetch('/api/agency/setup', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${authData.session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          agency_name: formData.agencyName,
          owner_name: formData.ownerName,
          owner_phone: formData.phone,
        }),
      });

      if (!response.ok) {
        const errData = await response.json().catch(() => ({}));
        throw new Error(errData.error || "Failed to set up agency workspace.");
      }

      toast({
        title: "Workspace created!",
        description: "Welcome to your new agency command center.",
      });

      // Explicitly reload profile+agency now that the DB rows exist,
      // avoiding the race where SIGNED_IN fires before setup completes.
      await refreshProfile();
      setLocation('/dashboard');
    } catch (error: any) {
      toast({
        title: "Setup failed",
        description: error.message || "An unexpected error occurred during setup.",
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-background flex flex-col justify-center items-center p-4 py-12">
      <div className="w-full max-w-lg">
        <div className="flex justify-center mb-8">
          <div className="flex items-center gap-2 text-primary">
            <ShieldCheck className="w-10 h-10" />
            <span className="text-3xl font-bold tracking-tight">AMS</span>
          </div>
        </div>
        
        <Card className="border-border/50 shadow-xl">
          <CardHeader className="space-y-1 pb-6">
            <CardTitle className="text-2xl font-bold tracking-tight text-center">Set up your workspace</CardTitle>
            <CardDescription className="text-center">
              Register a new agency and create your owner account
            </CardDescription>
          </CardHeader>
          <form onSubmit={handleRegister}>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="agencyName">Agency Name</Label>
                <Input 
                  id="agencyName" 
                  name="agencyName"
                  placeholder="Acme Insurance Brokers Ltd" 
                  value={formData.agencyName}
                  onChange={handleChange}
                  required 
                  disabled={loading}
                />
              </div>
              
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="ownerName">Your Name</Label>
                  <Input 
                    id="ownerName" 
                    name="ownerName"
                    placeholder="Jane Doe" 
                    value={formData.ownerName}
                    onChange={handleChange}
                    required 
                    disabled={loading}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="phone">Phone Number</Label>
                  <Input 
                    id="phone" 
                    name="phone"
                    placeholder="07XX XXX XXX" 
                    value={formData.phone}
                    onChange={handleChange}
                    required 
                    disabled={loading}
                  />
                </div>
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="email">Email Address</Label>
                <Input 
                  id="email" 
                  name="email"
                  type="email" 
                  placeholder="jane@acmeinsurance.co.ke" 
                  value={formData.email}
                  onChange={handleChange}
                  required 
                  disabled={loading}
                />
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="password">Password (min 8 chars)</Label>
                <Input 
                  id="password" 
                  name="password"
                  type="password" 
                  value={formData.password}
                  onChange={handleChange}
                  required 
                  minLength={8}
                  disabled={loading}
                />
              </div>
            </CardContent>
            <CardFooter className="flex flex-col space-y-4 pt-4">
              <Button 
                type="submit" 
                className="w-full" 
                disabled={loading}
                data-testid="button-register"
              >
                {loading ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : null}
                Create Agency Workspace
              </Button>
              <div className="text-sm text-center text-muted-foreground">
                Already have an account?{" "}
                <Link href="/login" className="text-primary font-medium hover:underline">
                  Sign in instead
                </Link>
              </div>
            </CardFooter>
          </form>
        </Card>
      </div>
    </div>
  );
}
