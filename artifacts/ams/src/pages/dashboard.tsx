import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { StatCard } from '@/components/StatCard';
import { FileText, DollarSign, CalendarClock, AlertCircle } from 'lucide-react';
import { formatCurrency, formatDate } from '@/lib/utils';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { startOfMonth, endOfMonth, addDays, startOfDay } from 'date-fns';
import { OnboardingChecklist } from '@/components/OnboardingChecklist';

export default function Dashboard() {
  const { agency, session } = useAuth();
  
  // Dashboard Metrics Queries
  const { data: metrics, isLoading } = useQuery({
    queryKey: ['dashboard-metrics', agency?.id],
    queryFn: async () => {
      if (!agency?.id) throw new Error('No agency');
      
      const today = startOfDay(new Date()).toISOString();
      const in30Days = addDays(new Date(), 30).toISOString();
      const startOfCurrentMonth = startOfMonth(new Date()).toISOString();
      const endOfCurrentMonth = endOfMonth(new Date()).toISOString();
      
      // 1. Active policies count
      const { count: activeCount } = await supabase
        .from('policies')
        .select('*', { count: 'exact', head: true })
        .eq('agency_id', agency.id)
        .eq('status', 'active');
        
      // 2. Total premium (active)
      const { data: premiumData } = await supabase
        .from('policies')
        .select('premium_amount')
        .eq('agency_id', agency.id)
        .eq('status', 'active');
        
      const totalPremium = premiumData?.reduce((sum, p) => sum + (p.premium_amount || 0), 0) || 0;
      
      // 3. Expiring in 30 days
      const { count: expiringCount } = await supabase
        .from('policies')
        .select('*', { count: 'exact', head: true })
        .eq('agency_id', agency.id)
        .eq('status', 'active')
        .gte('expiry_date', today)
        .lte('expiry_date', in30Days);
        
      // 4. Commissions this month (expected & received)
      const { data: commissionsThisMonth } = await supabase
        .from('commission_transactions')
        .select('amount, status')
        .eq('agency_id', agency.id)
        .gte('expected_date', startOfCurrentMonth)
        .lte('expected_date', endOfCurrentMonth);
        
      const expectedThisMonth = commissionsThisMonth?.reduce((sum, c) => sum + (c.amount || 0), 0) || 0;
      const receivedThisMonth = commissionsThisMonth?.filter(c => c.status === 'received').reduce((sum, c) => sum + (c.amount || 0), 0) || 0;
      
      // 5. Overdue commissions
      const { count: overdueCount } = await supabase
        .from('commission_transactions')
        .select('*', { count: 'exact', head: true })
        .eq('agency_id', agency.id)
        .eq('status', 'pending')
        .lt('expected_date', today.split('T')[0]);

      // 6. Recent policies
      const { data: recentPolicies } = await supabase
        .from('policies')
        .select(`
          id, policy_number, premium_amount, status, created_at,
          client:clients(name), 
          insurer:insurers(name), 
          product_line:product_lines(name)
        `)
        .eq('agency_id', agency.id)
        .order('created_at', { ascending: false })
        .limit(5);
        
      // 7. Upcoming renewals (next 30 days list)
      const { data: upcomingRenewals } = await supabase
        .from('policies')
        .select(`
          id, policy_number, expiry_date, status,
          client:clients(name),
          insurer:insurers(name)
        `)
        .eq('agency_id', agency.id)
        .eq('status', 'active')
        .gte('expiry_date', today)
        .lte('expiry_date', in30Days)
        .order('expiry_date', { ascending: true })
        .limit(5);

      // 8. Onboarding counts
      const [{ count: insurerCount }, { count: clientCount }] = await Promise.all([
        supabase.from('insurers').select('*', { count: 'exact', head: true }).eq('agency_id', agency.id),
        supabase.from('clients').select('*', { count: 'exact', head: true }).eq('agency_id', agency.id),
      ]);

      return {
        activeCount: activeCount || 0,
        totalPremium,
        expiringCount: expiringCount || 0,
        expectedThisMonth,
        receivedThisMonth,
        overdueCount: overdueCount || 0,
        recentPolicies: recentPolicies || [],
        upcomingRenewals: upcomingRenewals || [],
        // onboarding
        hasInsurers: (insurerCount || 0) > 0,
        hasClients: (clientCount || 0) > 0,
        hasPolicies: (activeCount || 0) > 0,
      };
    },
    enabled: !!session && !!agency?.id,
  });

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-2">
        <h1 className="text-3xl font-bold tracking-tight">Overview</h1>
        <p className="text-muted-foreground">
          Welcome back. Here's what's happening at your agency today.
        </p>
      </div>

      {/* Onboarding checklist — only shown when agency is fresh */}
      {!isLoading && agency?.id && (!metrics?.hasInsurers || !metrics?.hasClients || !metrics?.hasPolicies) && (
        <OnboardingChecklist
          agencyId={agency.id}
          hasInsurers={metrics?.hasInsurers ?? false}
          hasClients={metrics?.hasClients ?? false}
          hasPolicies={metrics?.hasPolicies ?? false}
        />
      )}

      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <StatCard
          title="Total Active Policies"
          value={metrics?.activeCount || 0}
          icon={FileText}
          loading={isLoading}
        />
        <StatCard
          title="Active Premium Total"
          value={formatCurrency(metrics?.totalPremium)}
          icon={DollarSign}
          loading={isLoading}
        />
        <StatCard
          title="Expiring (30 Days)"
          value={metrics?.expiringCount || 0}
          subtitle="Requires attention"
          icon={CalendarClock}
          loading={isLoading}
          className={metrics?.expiringCount ? "border-amber-200 dark:border-amber-900 bg-amber-50/50 dark:bg-amber-950/20" : ""}
        />
        <StatCard
          title="Expected Commission (MTD)"
          value={formatCurrency(metrics?.expectedThisMonth)}
          icon={DollarSign}
          loading={isLoading}
        />
        <StatCard
          title="Received Commission (MTD)"
          value={formatCurrency(metrics?.receivedThisMonth)}
          icon={DollarSign}
          loading={isLoading}
        />
        <StatCard
          title="Overdue Commissions"
          value={metrics?.overdueCount || 0}
          subtitle="Pending past expected date"
          icon={AlertCircle}
          loading={isLoading}
          className={metrics?.overdueCount ? "border-red-200 dark:border-red-900 bg-red-50/50 dark:bg-red-950/20" : ""}
        />
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle>Recent Policies</CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="space-y-2">
                {[1,2,3].map(i => <div key={i} className="h-12 bg-muted/50 rounded-md animate-pulse"></div>)}
              </div>
            ) : metrics?.recentPolicies.length === 0 ? (
              <div className="text-center py-6 text-sm text-muted-foreground">No recent policies</div>
            ) : (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Client</TableHead>
                      <TableHead>Product</TableHead>
                      <TableHead className="text-right">Premium</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {metrics?.recentPolicies.map((policy: any) => (
                      <TableRow key={policy.id}>
                        <TableCell className="font-medium">{policy.client?.name}</TableCell>
                        <TableCell>
                          <div className="text-sm">{policy.product_line?.name}</div>
                          <div className="text-xs text-muted-foreground">{policy.insurer?.name}</div>
                        </TableCell>
                        <TableCell className="text-right">{formatCurrency(policy.premium_amount)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-3">
            <CardTitle>Upcoming Renewals</CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="space-y-2">
                {[1,2,3].map(i => <div key={i} className="h-12 bg-muted/50 rounded-md animate-pulse"></div>)}
              </div>
            ) : metrics?.upcomingRenewals.length === 0 ? (
              <div className="text-center py-6 text-sm text-muted-foreground">No upcoming renewals in next 30 days</div>
            ) : (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Client</TableHead>
                      <TableHead>Policy #</TableHead>
                      <TableHead className="text-right">Expires</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {metrics?.upcomingRenewals.map((policy: any) => {
                      const daysLeft = Math.ceil((new Date(policy.expiry_date).getTime() - new Date().getTime()) / (1000 * 3600 * 24));
                      const isUrgent = daysLeft <= 7;
                      return (
                        <TableRow key={policy.id}>
                          <TableCell className="font-medium">{policy.client?.name}</TableCell>
                          <TableCell>
                            <div className="text-sm">{policy.policy_number}</div>
                            <div className="text-xs text-muted-foreground">{policy.insurer?.name}</div>
                          </TableCell>
                          <TableCell className="text-right">
                            <div className={`font-medium ${isUrgent ? 'text-destructive' : ''}`}>
                              {formatDate(policy.expiry_date)}
                            </div>
                            <div className="text-xs text-muted-foreground">{daysLeft} days</div>
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
