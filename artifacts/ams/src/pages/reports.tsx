import React, { useState } from 'react';
import { 
  BarChart2, 
  TrendingUp, 
  Users, 
  FileText, 
  DollarSign, 
  Eye, 
  Printer, 
  Loader2
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { supabase } from '@/lib/supabase';
import { formatCurrency, formatDate } from '@/lib/utils';
import { useToast } from '@/hooks/use-toast';
import {
  useYtdSummary,
  useMonthlyPremiumVolume,
  usePolicyStatusBreakdown,
  useTopClients,
  useTopInsurers,
  useNewClientsPerMonth,
  useReports
} from '@/hooks/queries';
import { useQueryClient } from '@tanstack/react-query';

import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip as RechartsTooltip,
  Legend,
  PieChart,
  Pie,
  Cell,
  AreaChart,
  Area,
  ResponsiveContainer,
  Label as RechartsLabel
} from 'recharts';

// Colors mapped to Tailwind theme / brand colors
const COLORS = {
  primary: '#1e3a5f',
  accent: '#0ea5e9',
  emerald: '#10b981',
  amber: '#f59e0b',
  rose: '#f43f5e',
  purple: '#8b5cf6',
  slate: '#64748b'
};

const STATUS_COLORS: Record<string, string> = {
  active: COLORS.emerald,
  pending: COLORS.amber,
  expired: COLORS.rose,
  cancelled: COLORS.slate
};

export default function Reports() {
  const { session, agency } = useAuth();
  const { toast } = useToast();
  const queryClient = useQueryClient();

  // Queries
  const { data: ytdSummary, isLoading: isLoadingYtd } = useYtdSummary();
  const { data: monthlyPremium, isLoading: isLoadingMonthly } = useMonthlyPremiumVolume();
  const { data: policyStatus, isLoading: isLoadingStatus } = usePolicyStatusBreakdown();
  const { data: topClients, isLoading: isLoadingClients } = useTopClients();
  const { data: topInsurers, isLoading: isLoadingInsurers } = useTopInsurers();
  const { data: newClients, isLoading: isLoadingNewClients } = useNewClientsPerMonth();
  const { data: reports, isLoading: isLoadingReports } = useReports();

  // Modals state
  const [isGenerateOpen, setIsGenerateOpen] = useState(false);
  const [isGenerating, setIsGenerating] = useState(false);
  
  // Default to previous month
  const prevDate = new Date();
  prevDate.setMonth(prevDate.getMonth() - 1);
  const [generateMonth, setGenerateMonth] = useState<string>((prevDate.getMonth() + 1).toString());
  const [generateYear, setGenerateYear] = useState<string>(prevDate.getFullYear().toString());

  const [selectedReport, setSelectedReport] = useState<any>(null);
  const [isViewOpen, setIsViewOpen] = useState(false);

  // Formatting compact currency for charts
  const formatCompactKsh = (val: number) => {
    return new Intl.NumberFormat('en-KE', { notation: 'compact', compactDisplay: 'short', maximumFractionDigits: 1 }).format(val);
  };

  const handleGenerate = async () => {
    if (!session) return;
    setIsGenerating(true);
    try {
      const response = await fetch(`${import.meta.env.BASE_URL}api/reports/generate`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${(await supabase.auth.getSession()).data.session?.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ month: parseInt(generateMonth), year: parseInt(generateYear) }),
      });
      
      if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error || 'Failed to generate report');
      }

      toast({
        title: 'Success',
        description: 'Report generated successfully',
      });
      setIsGenerateOpen(false);
      queryClient.invalidateQueries({ queryKey: ['reports'] });
    } catch (error: any) {
      toast({
        title: 'Error',
        description: error.message || 'An error occurred while generating the report',
        variant: 'destructive',
      });
    } finally {
      setIsGenerating(false);
    }
  };

  const handleViewReport = (report: any) => {
    setSelectedReport(report);
    setIsViewOpen(true);
  };

  const topInsurersData = topInsurers?.map(i => ({
    ...i,
    premium10k: i.premium / 10000
  })) || [];

  return (
    <div className="space-y-8 pb-8">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-foreground">Reports & Analytics</h1>
          <p className="text-muted-foreground mt-1">Agency performance at a glance</p>
        </div>
        <Button onClick={() => setIsGenerateOpen(true)} className="gap-2">
          <BarChart2 className="w-4 h-4" />
          Generate Report
        </Button>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
        {isLoadingYtd ? (
          Array(5).fill(0).map((_, i) => <Skeleton key={i} className="h-28 rounded-xl" />)
        ) : (
          <>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">Active Policies</CardTitle>
                <FileText className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{ytdSummary?.activePolicies || 0}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">Premium Volume YTD</CardTitle>
                <DollarSign className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{formatCurrency(ytdSummary?.totalPremiumYtd)}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">Commission Received YTD</CardTitle>
                <TrendingUp className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{formatCurrency(ytdSummary?.commReceivedYtd)}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">New Clients YTD</CardTitle>
                <Users className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{ytdSummary?.newClientsYtd || 0}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground">Collection Rate</CardTitle>
                <BarChart2 className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className={`text-2xl font-bold ${
                  ytdSummary && ytdSummary.collectionRate >= 80 ? 'text-emerald-500' :
                  ytdSummary && ytdSummary.collectionRate >= 50 ? 'text-amber-500' :
                  'text-rose-500'
                }`}>
                  {ytdSummary?.collectionRate || 0}%
                </div>
              </CardContent>
            </Card>
          </>
        )}
      </div>

      {/* Row 2: Monthly Premium + Portfolio Mix */}
      <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
        <Card className="lg:col-span-3">
          <CardHeader>
            <CardTitle>Monthly Premium & Commission</CardTitle>
          </CardHeader>
          <CardContent className="h-80">
            {isLoadingMonthly ? <div className="h-full w-full flex items-center justify-center"><Skeleton className="h-8 w-32 animate-pulse rounded-md" /></div> : (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={monthlyPremium || []} margin={{ top: 20, right: 30, left: 20, bottom: 5 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                  <XAxis dataKey="month" axisLine={false} tickLine={false} />
                  <YAxis tickFormatter={formatCompactKsh} axisLine={false} tickLine={false} />
                  <RechartsTooltip 
                    formatter={(value: number) => formatCurrency(value)}
                    cursor={{fill: '#f1f5f9'}}
                  />
                  <Legend wrapperStyle={{ paddingTop: '20px' }} />
                  <Bar dataKey="premium" name="Premium" fill={COLORS.primary} radius={[4, 4, 0, 0]} />
                  <Bar dataKey="expected" name="Expected Comm." fill={COLORS.accent} radius={[4, 4, 0, 0]} />
                  <Bar dataKey="received" name="Received Comm." fill={COLORS.emerald} radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle>Policy Portfolio Mix</CardTitle>
          </CardHeader>
          <CardContent className="h-80">
            {isLoadingStatus ? <div className="h-full w-full flex items-center justify-center"><Skeleton className="h-8 w-32 animate-pulse rounded-md" /></div> : (
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie
                    data={policyStatus || []}
                    cx="50%"
                    cy="50%"
                    innerRadius={80}
                    outerRadius={110}
                    paddingAngle={2}
                    dataKey="value"
                  >
                    {(policyStatus || []).map((entry: any) => (
                      <Cell key={entry.name} fill={STATUS_COLORS[entry.name] || COLORS.slate} />
                    ))}
                    <RechartsLabel 
                      value={(policyStatus || []).reduce((acc: number, cur: any) => acc + cur.value, 0)} 
                      position="center" 
                      className="text-3xl font-bold fill-foreground"
                    />
                  </Pie>
                  <RechartsTooltip formatter={(value: number) => [value, 'Policies']} />
                  <Legend wrapperStyle={{ paddingTop: '20px' }} />
                </PieChart>
              </ResponsiveContainer>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Row 3: Top Clients & Top Insurers */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card>
          <CardHeader>
            <CardTitle>Top 5 Clients by Premium</CardTitle>
          </CardHeader>
          <CardContent className="h-80">
            {isLoadingClients ? <div className="h-full w-full flex items-center justify-center"><Skeleton className="h-8 w-32 animate-pulse rounded-md" /></div> : (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={topClients || []} layout="vertical" margin={{ top: 20, right: 30, left: 40, bottom: 5 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#e2e8f0" />
                  <XAxis type="number" tickFormatter={formatCompactKsh} axisLine={false} tickLine={false} />
                  <YAxis type="category" dataKey="name" axisLine={false} tickLine={false} width={100} tickFormatter={(val: string) => val.length > 20 ? val.substring(0, 20) + '...' : val} />
                  <RechartsTooltip formatter={(value: number) => formatCurrency(value)} cursor={{fill: '#f1f5f9'}} />
                  <Bar dataKey="premium" name="Premium" fill={COLORS.primary} radius={[0, 4, 4, 0]} barSize={32} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Top 5 Insurers</CardTitle>
          </CardHeader>
          <CardContent className="h-80">
            {isLoadingInsurers ? <div className="h-full w-full flex items-center justify-center"><Skeleton className="h-8 w-32 animate-pulse rounded-md" /></div> : (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={topInsurersData} margin={{ top: 20, right: 30, left: 20, bottom: 5 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                  <XAxis dataKey="name" axisLine={false} tickLine={false} tickFormatter={(val: string) => val.length > 15 ? val.substring(0, 15) + '...' : val} />
                  <YAxis yAxisId="left" orientation="left" axisLine={false} tickLine={false} />
                  <YAxis yAxisId="right" orientation="right" tickFormatter={formatCompactKsh} axisLine={false} tickLine={false} />
                  <RechartsTooltip 
                    formatter={(value: number, name: string) => name === 'KES (×10k)' ? formatCurrency(value * 10000) : value}
                    cursor={{fill: '#f1f5f9'}}
                  />
                  <Legend wrapperStyle={{ paddingTop: '20px' }} />
                  <Bar yAxisId="left" dataKey="count" name="Policies" fill={COLORS.accent} radius={[4, 4, 0, 0]} />
                  <Bar yAxisId="right" dataKey="premium10k" name="KES (×10k)" fill={COLORS.emerald} radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Row 4: New Clients Area Chart */}
      <Card>
        <CardHeader>
          <CardTitle>New Client Acquisition (Last 6 Months)</CardTitle>
        </CardHeader>
        <CardContent className="h-80">
          {isLoadingNewClients ? <div className="h-full w-full flex items-center justify-center"><Skeleton className="h-8 w-32 animate-pulse rounded-md" /></div> : (
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={newClients || []} margin={{ top: 20, right: 30, left: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="colorClients" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor={COLORS.accent} stopOpacity={0.3}/>
                    <stop offset="95%" stopColor={COLORS.accent} stopOpacity={0}/>
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e2e8f0" />
                <XAxis dataKey="month" axisLine={false} tickLine={false} />
                <YAxis allowDecimals={false} axisLine={false} tickLine={false} />
                <RechartsTooltip cursor={{ stroke: COLORS.accent, strokeWidth: 1, strokeDasharray: '3 3' }} />
                <Area type="monotone" dataKey="clients" name="New Clients" stroke={COLORS.accent} strokeWidth={3} fillOpacity={1} fill="url(#colorClients)" />
              </AreaChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>

      {/* Phase 5: Reports Archive */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <div>
            <CardTitle>Monthly Report Archive</CardTitle>
            <CardDescription>Generated snapshots of agency performance by month</CardDescription>
          </div>
          <Button variant="secondary" size="sm" onClick={() => setIsGenerateOpen(true)}>
            <BarChart2 className="w-4 h-4 mr-2" /> Generate Report
          </Button>
        </CardHeader>
        <CardContent>
          <div className="rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Month/Year</TableHead>
                  <TableHead className="text-right">Policies Written</TableHead>
                  <TableHead className="text-right">Premium (KES)</TableHead>
                  <TableHead className="text-right">Commissions Received</TableHead>
                  <TableHead className="text-right">Collection Rate</TableHead>
                  <TableHead className="text-right">New Clients</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {isLoadingReports ? (
                  <TableRow>
                    <TableCell colSpan={7} className="text-center py-8 text-muted-foreground">
                      <Loader2 className="w-6 h-6 animate-spin mx-auto mb-2" />
                      Loading archive...
                    </TableCell>
                  </TableRow>
                ) : !reports || reports.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={7} className="text-center py-8 text-muted-foreground">
                      No reports generated yet. Click 'Generate Report' to create your first monthly snapshot.
                    </TableCell>
                  </TableRow>
                ) : (
                  reports.map((report: any) => {
                    const md = report.metadata || {};
                    const dateObj = new Date(report.year, report.month - 1);
                    const monthName = dateObj.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
                    
                    return (
                      <TableRow key={report.id}>
                        <TableCell className="font-medium">{monthName}</TableCell>
                        <TableCell className="text-right">{md.total_policies_written || 0}</TableCell>
                        <TableCell className="text-right">{formatCurrency(md.total_premium_kes || 0)}</TableCell>
                        <TableCell className="text-right">{formatCurrency(md.commission_received_kes || 0)}</TableCell>
                        <TableCell className="text-right">{md.collection_rate_pct ?? 0}%</TableCell>
                        <TableCell className="text-right">{md.new_clients || 0}</TableCell>
                        <TableCell className="text-right">
                          <Button variant="ghost" size="sm" onClick={() => handleViewReport(report)}>
                            <Eye className="w-4 h-4 mr-2" /> View
                          </Button>
                        </TableCell>
                      </TableRow>
                    )
                  })
                )}
              </TableBody>
            </Table>
          </div>
        </CardContent>
      </Card>

      {/* Generate Report Dialog */}
      <Dialog open={isGenerateOpen} onOpenChange={setIsGenerateOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Generate Monthly Report</DialogTitle>
            <DialogDescription>Create a performance snapshot for a specific month. Reports are stored in your archive.</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 py-4">
            <div className="grid gap-2">
              <Label>Month</Label>
              <Select value={generateMonth} onValueChange={setGenerateMonth}>
                <SelectTrigger>
                  <SelectValue placeholder="Select month" />
                </SelectTrigger>
                <SelectContent>
                  {Array.from({ length: 12 }, (_, i) => i + 1).map(m => (
                    <SelectItem key={m} value={m.toString()}>
                      {new Date(2000, m - 1).toLocaleDateString('en-GB', { month: 'long' })}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="grid gap-2">
              <Label>Year</Label>
              <Input type="number" value={generateYear} onChange={e => setGenerateYear(e.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setIsGenerateOpen(false)}>Cancel</Button>
            <Button onClick={handleGenerate} disabled={isGenerating}>
              {isGenerating ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : null}
              Generate
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* View Report Dialog */}
      <Dialog open={isViewOpen} onOpenChange={setIsViewOpen}>
        <DialogContent className="max-w-2xl">
          <style dangerouslySetInnerHTML={{ __html: `
            @media print { 
              body > * { display: none; } 
              .print-report { display: block !important; position: absolute; left: 0; top: 0; width: 100%; padding: 2rem; background: white; color: black; } 
              .print-report .border { border-color: #e2e8f0 !important; }
              .print-report .bg-muted { background-color: #f1f5f9 !important; }
            }
          `}} />
          <DialogHeader className="print:hidden">
            <DialogTitle>Report Details</DialogTitle>
          </DialogHeader>
          
          {selectedReport && (
            <div className="print-report space-y-6">
              <div className="border-b pb-4">
                <h2 className="text-2xl font-bold text-foreground">{agency?.name}</h2>
                <p className="text-lg text-muted-foreground mt-1">
                  Monthly Report &mdash; {new Date(selectedReport.year, selectedReport.month - 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' })}
                </p>
              </div>
              
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">Policies Written</div>
                  <div className="text-2xl font-bold mt-1">{selectedReport.metadata?.total_policies_written || 0}</div>
                </div>
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">Total Premium</div>
                  <div className="text-2xl font-bold mt-1">{formatCurrency(selectedReport.metadata?.total_premium_kes || 0)}</div>
                </div>
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">Expected Comm.</div>
                  <div className="text-2xl font-bold mt-1">{formatCurrency(selectedReport.metadata?.commission_expected_kes || 0)}</div>
                </div>
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">Received Comm.</div>
                  <div className="text-2xl font-bold mt-1">{formatCurrency(selectedReport.metadata?.commission_received_kes || 0)}</div>
                </div>
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">Collection Rate</div>
                  <div className="text-2xl font-bold mt-1">{selectedReport.metadata?.collection_rate_pct || 0}%</div>
                </div>
                <div className="p-4 bg-muted/50 rounded-lg border">
                  <div className="text-sm font-medium text-muted-foreground">New Clients</div>
                  <div className="text-2xl font-bold mt-1">{selectedReport.metadata?.new_clients || 0}</div>
                </div>
              </div>

              <div className="text-xs text-muted-foreground pt-4 border-t">
                Generated: {formatDate(selectedReport.generated_at)}
              </div>
            </div>
          )}

          <DialogFooter className="print:hidden">
            <Button variant="outline" onClick={() => setIsViewOpen(false)}>Close</Button>
            <Button onClick={() => window.print()} className="gap-2">
              <Printer className="w-4 h-4" /> Print / Save as PDF
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
