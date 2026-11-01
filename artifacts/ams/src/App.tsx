import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from '@/lib/queryClient';
import { Toaster } from '@/components/ui/toaster';
import { TooltipProvider } from '@/components/ui/tooltip';
import { Route, Switch, Router as WouterRouter, Redirect } from 'wouter';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { AppLayout } from '@/layouts/AppLayout';
import NotFound from '@/pages/not-found';

import Login from '@/pages/login';
import Register from '@/pages/register';
import Join from '@/pages/join';
import Dashboard from '@/pages/dashboard';
import Clients from '@/pages/clients';
import ClientDetail from '@/pages/client-detail';
import Policies from '@/pages/policies';
import Insurers from '@/pages/insurers';
import ProductLines from '@/pages/product-lines';
import Commissions from '@/pages/commissions';
import Renewals from '@/pages/renewals';
import Reports from '@/pages/reports';
import Settings from '@/pages/settings';

// Protected Route Wrapper
const ProtectedRoute = ({ component: Component }: { component: React.ComponentType }) => {
  const { session, isLoading, isDeactivated, signOut } = useAuth();
  
  if (isLoading) return <div className="min-h-screen flex items-center justify-center">Loading workspace...</div>;
  if (!session) return <Redirect to="/login" />;
  if (isDeactivated) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background p-4">
        <Card className="w-full max-w-md text-center">
          <CardHeader>
            <CardTitle>Your access to this agency has been removed</CardTitle>
            <CardDescription>Ask the agency owner if you think this is a mistake.</CardDescription>
          </CardHeader>
          <CardContent>
            <Button onClick={() => { void signOut(); }}>Sign out</Button>
          </CardContent>
        </Card>
      </div>
    );
  }
  
  return (
    <AppLayout>
      <Component />
    </AppLayout>
  );
};

function Router() {
  return (
    <Switch>
      <Route path="~^/$" component={() => <Redirect to="/dashboard" />} />
      <Route path="/login" component={Login} />
      <Route path="/register" component={Register} />
      <Route path="/join" component={Join} />
      
      <Route path="/dashboard" component={() => <ProtectedRoute component={Dashboard} />} />
      <Route path="/clients" component={() => <ProtectedRoute component={Clients} />} />
      <Route path="/clients/:id" component={() => <ProtectedRoute component={ClientDetail} />} />
      <Route path="/policies" component={() => <ProtectedRoute component={Policies} />} />
      <Route path="/commissions" component={() => <ProtectedRoute component={Commissions} />} />
      <Route path="/renewals" component={() => <ProtectedRoute component={Renewals} />} />
      <Route path="/reports" component={() => <ProtectedRoute component={Reports} />} />
      <Route path="/insurers" component={() => <ProtectedRoute component={Insurers} />} />
      <Route path="/product-lines" component={() => <ProtectedRoute component={ProductLines} />} />
      <Route path="/settings" component={() => <ProtectedRoute component={Settings} />} />
      
      <Route component={NotFound} />
    </Switch>
  );
}

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <WouterRouter base={import.meta.env.BASE_URL.replace(/\/$/, '')}>
          <AuthProvider>
            <Router />
          </AuthProvider>
        </WouterRouter>
        <Toaster />
      </TooltipProvider>
    </QueryClientProvider>
  );
}

export default App;
