import React, { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useCommissions, useCreateCommission, usePolicies } from '@/hooks/queries';
import { useCreateReceipt } from '@/hooks/receipts';
import { Link } from 'wouter';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Checkbox } from '@/components/ui/checkbox';
import { formatCurrency, formatDate, getStatusColor } from '@/lib/utils';
import { Search, Filter, CheckCircle2, Plus, Download } from 'lucide-react';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { useToast } from '@/hooks/use-toast';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogFooter, DialogTrigger } from '@/components/ui/dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Textarea } from '@/components/ui/textarea';
import { exportToCsv } from '@/lib/csv-export';

const commissionSchema = z.object({
  policy_id: z.string().min(1, 'Required'),
  amount: z.coerce.number().min(1, 'Must be positive'),
  expected_date: z.string().min(1, 'Required'),
  notes: z.string().optional()
});

type CommissionFormValues = z.infer<typeof commissionSchema>;

export default function Commissions() {
  const [statusFilter, setStatusFilter] = useState('all');
  const [searchTerm, setSearchTerm] = useState('');
  const [payingComm, setPayingComm] = useState<any | null>(null);
  const [bulkOpen, setBulkOpen] = useState(false);
  const [payDate, setPayDate] = useState(new Date().toISOString().split('T')[0]);
  const [payAmount, setPayAmount] = useState('');
  const [payRef, setPayRef] = useState('');
  const [isAddOpen, setIsAddOpen] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  
  const { profile, isOwnerOrManager } = useAuth();
  const isAgent = !!profile && !isOwnerOrManager;

  const { data: commissions, isLoading } = useCommissions({ status: statusFilter });
  const { data: policies } = usePolicies();
  const createCommission = useCreateCommission();
  const createReceipt = useCreateReceipt();
  const { toast } = useToast();

  const form = useForm<CommissionFormValues>({
    resolver: zodResolver(commissionSchema),
    defaultValues: {
      policy_id: '',
      amount: 0,
      expected_date: new Date().toISOString().split('T')[0],
      notes: ''
    }
  });

  const filteredCommissions = commissions?.filter(c => 
    c.policy?.policy_number?.toLowerCase().includes(searchTerm.toLowerCase()) ||
    c.policy?.client?.name?.toLowerCase().includes(searchTerm.toLowerCase()) ||
    c.policy?.insurer?.name?.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const remainingOf = (c: any) => Math.max((Number(c.amount) || 0) - (Number(c.amount_received) || 0), 0);
  const today = new Date().toISOString().split('T')[0];
  const isUnpaid = (c: any) => c.status === 'pending' || c.status === 'part_paid';
  const isOverdueRow = (c: any) => isUnpaid(c) && !!c.expected_date && c.expected_date < today;
  const lastReceivedOn = (c: any): string | null => {
    const dates = ((c.allocations ?? []) as any[]).map(a => a.receipt?.received_on).filter(Boolean) as string[];
    return dates.length ? dates.reduce((m, d) => (d > m ? d : m)) : null;
  };

  const totalExpected = commissions?.reduce((sum, c) => sum + (c.amount || 0), 0) || 0;
  const totalReceived = commissions?.reduce((sum, c) => sum + (Number(c.amount_received) || 0), 0) || 0;
  const totalOverdue = commissions?.filter(isOverdueRow).reduce((sum, c) => sum + remainingOf(c), 0) || 0;

  const collectionRate = totalExpected > 0 ? (totalReceived / totalExpected) * 100 : 0;
  let rateColor = 'text-muted-foreground';
  let rateBg = 'bg-card';
  let rateBorder = 'border-border';
  if (totalExpected > 0) {
    if (collectionRate >= 80) {
      rateColor = 'text-emerald-700 dark:text-emerald-500';
      rateBg = 'bg-emerald-50 dark:bg-emerald-950/20';
      rateBorder = 'border-emerald-200 dark:border-emerald-900';
    } else if (collectionRate >= 50) {
      rateColor = 'text-amber-700 dark:text-amber-500';
      rateBg = 'bg-amber-50 dark:bg-amber-950/20';
      rateBorder = 'border-amber-200 dark:border-amber-900';
    } else {
      rateColor = 'text-red-700 dark:text-red-500';
      rateBg = 'bg-red-50 dark:bg-red-950/20';
      rateBorder = 'border-red-200 dark:border-red-900';
    }
  }

  const nowMs = new Date().getTime();
  const overdueItems = commissions?.filter(isOverdueRow) || [];
  
  const aging = {
    '0-30': { label: '0–30 Days', count: 0, amount: 0 },
    '31-60': { label: '31–60 Days', count: 0, amount: 0 },
    '61-90': { label: '61–90 Days', count: 0, amount: 0 },
    '90+': { label: '90+ Days', count: 0, amount: 0 }
  };

  overdueItems.forEach(c => {
    const days = Math.floor((nowMs - new Date(c.expected_date).getTime()) / (1000 * 3600 * 24));
    if (days <= 30) { aging['0-30'].count++; aging['0-30'].amount += remainingOf(c); }
    else if (days <= 60) { aging['31-60'].count++; aging['31-60'].amount += remainingOf(c); }
    else if (days <= 90) { aging['61-90'].count++; aging['61-90'].amount += remainingOf(c); }
    else { aging['90+'].count++; aging['90+'].amount += remainingOf(c); }
  });

  const selectedComms = (commissions ?? []).filter(c => selectedIds.has(c.id) && remainingOf(c) > 0);
  const selectedInsurerIds = new Set(selectedComms.map(c => c.policy?.insurer?.id));
  const sameInsurer = selectedComms.length > 0 && selectedInsurerIds.size === 1;
  const selectedTotal = selectedComms.reduce((sum, c) => sum + remainingOf(c), 0);

  const showError = (err: Error) => toast({ title: 'Error', description: err.message, variant: 'destructive' });

  const openBulkDialog = () => {
    setPayDate(today);
    setPayRef('');
    setBulkOpen(true);
  };

  const handleBulkRecord = () => {
    const insurerId = selectedComms[0]?.policy?.insurer?.id;
    if (!insurerId || !sameInsurer) return;
    createReceipt.mutate({
      insurerId,
      receivedOn: payDate,
      amount: selectedTotal,
      bankReference: payRef.trim() || null,
      allocations: selectedComms.map(c => ({ commission_id: c.id, amount: remainingOf(c) })),
    }, {
      onSuccess: () => {
        toast({ title: 'Payment recorded' });
        setBulkOpen(false);
        setSelectedIds(new Set());
      },
      onError: showError,
    });
  };

  const toggleSelectAll = () => {
    if (!filteredCommissions) return;
    const selectable = filteredCommissions.filter(c => remainingOf(c) > 0);
    if (selectedIds.size === selectable.length && selectable.length > 0) {
      setSelectedIds(new Set());
    } else {
      setSelectedIds(new Set(selectable.map(c => c.id)));
    }
  };

  const toggleSelectRow = (id: string) => {
    const next = new Set(selectedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setSelectedIds(next);
  };

  const handleReceive = () => {
    const amount = parseFloat(payAmount);
    const insurerId = payingComm?.policy?.insurer?.id;
    if (!payingComm || !insurerId || !(amount > 0)) return;
    createReceipt.mutate({
      insurerId,
      receivedOn: payDate,
      amount,
      bankReference: payRef.trim() || null,
      allocations: [{ commission_id: payingComm.id, amount }],
    }, {
      onSuccess: () => {
        toast({ title: 'Payment recorded' });
        setPayingComm(null);
      },
      onError: showError,
    });
  };

  const openReceiveDialog = (comm: any) => {
    setPayingComm(comm);
    setPayDate(today);
    setPayAmount(remainingOf(comm).toString());
    setPayRef('');
  };

  const onSubmitAdd = (values: CommissionFormValues) => {
    createCommission.mutate({
      ...values
    }, {
      onSuccess: () => {
        toast({ title: 'Commission transaction added' });
        setIsAddOpen(false);
        form.reset();
      },
      onError: (err) => {
        toast({ title: 'Error', description: err.message, variant: 'destructive' });
      }
    });
  };

  const handleExportCsv = () => {
    if (!commissions) return;
    const exportData = commissions.map(c => ({
      policy_number: c.policy?.policy_number || '',
      client_name: c.policy?.client?.name || '',
      insurer_name: c.policy?.insurer?.name || '',
      amount: c.amount,
      status: c.status,
      expected_date: c.expected_date,
      received_amount: c.amount_received,
      received_date: lastReceivedOn(c) || ''
    }));
    exportToCsv('commissions', exportData);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Commissions</h1>
          <p className="text-muted-foreground">{isAgent ? 'Your expected and received commissions.' : 'Track expected and received commissions.'}</p>
        </div>

        {!isAgent && (
        <Dialog open={isAddOpen} onOpenChange={(open) => {
          setIsAddOpen(open);
          if (!open) form.reset();
        }}>
          <DialogTrigger asChild>
            <Button><Plus className="w-4 h-4 mr-2" /> Add Transaction</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Add Commission Transaction</DialogTitle>
              <DialogDescription>Record a new expected or received commission.</DialogDescription>
            </DialogHeader>
            <Form {...form}>
              <form onSubmit={form.handleSubmit(onSubmitAdd)} className="space-y-4">
                <FormField
                  control={form.control}
                  name="policy_id"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Policy</FormLabel>
                      <Select onValueChange={field.onChange} value={field.value}>
                        <FormControl><SelectTrigger><SelectValue placeholder="Select policy" /></SelectTrigger></FormControl>
                        <SelectContent>
                          {policies?.map(p => (
                            <SelectItem key={p.id} value={p.id}>{p.policy_number} - {p.client?.name ?? '—'}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="amount"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Amount (KES)</FormLabel>
                        <FormControl><Input type="number" {...field} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                <FormField
                  control={form.control}
                  name="expected_date"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Expected Date</FormLabel>
                      <FormControl><Input type="date" {...field} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <FormField
                  control={form.control}
                  name="notes"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Notes (Optional)</FormLabel>
                      <FormControl><Textarea {...field} value={field.value || ''} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <Button type="submit" className="w-full" disabled={createCommission.isPending}>
                  {createCommission.isPending ? "Saving..." : "Save Transaction"}
                </Button>
              </form>
            </Form>
          </DialogContent>
        </Dialog>
        )}
      </div>

      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card className="bg-card">
          <CardContent className="p-6">
            <div className="text-sm font-medium text-muted-foreground mb-1">Total Expected</div>
            <div className="text-2xl font-bold">{formatCurrency(totalExpected)}</div>
          </CardContent>
        </Card>
        <Card className="bg-emerald-50 dark:bg-emerald-950/20 border-emerald-200 dark:border-emerald-900">
          <CardContent className="p-6">
            <div className="text-sm font-medium text-emerald-800 dark:text-emerald-400 mb-1">Total Received</div>
            <div className="text-2xl font-bold text-emerald-700 dark:text-emerald-500">{formatCurrency(totalReceived)}</div>
          </CardContent>
        </Card>
        <Card className="bg-red-50 dark:bg-red-950/20 border-red-200 dark:border-red-900">
          <CardContent className="p-6">
            <div className="text-sm font-medium text-red-800 dark:text-red-400 mb-1">Overdue (Unpaid)</div>
            <div className="text-2xl font-bold text-red-700 dark:text-red-500">{formatCurrency(totalOverdue)}</div>
          </CardContent>
        </Card>
        <Card className={`${rateBg} ${rateBorder}`}>
          <CardContent className="p-6">
            <div className={`text-sm font-medium mb-1 ${totalExpected > 0 ? rateColor.replace('700', '800').replace('500', '400') : 'text-muted-foreground'}`}>Collection Rate</div>
            <div className={`text-2xl font-bold ${rateColor}`}>{totalExpected > 0 ? `${collectionRate.toFixed(1)}%` : '0%'}</div>
          </CardContent>
        </Card>
      </div>

      {overdueItems.length > 0 && (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold tracking-tight">Overdue by Age</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4">
            {Object.values(aging).map((b, i) => (
              <Card key={i} className={`bg-card ${b.count === 0 ? 'opacity-40' : ''}`}>
                <CardContent className="p-4 flex justify-between items-center">
                  <div>
                    <div className="text-sm font-medium text-muted-foreground">{b.label}</div>
                    <div className="text-lg font-bold">{formatCurrency(b.amount)}</div>
                  </div>
                  <Badge variant="secondary">{b.count}</Badge>
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      )}

      {selectedIds.size > 0 && !isAgent && (
        <div className="sticky top-4 z-10 flex items-center justify-between bg-primary text-primary-foreground px-4 py-3 rounded-md shadow-md">
          <div className="text-sm font-medium">{selectedIds.size} selected</div>
          <div className="space-x-2">
            <Tooltip>
              <TooltipTrigger asChild>
                <span>
                  <Button size="sm" variant="secondary" onClick={openBulkDialog} disabled={!sameInsurer}>
                    Record payment for selected
                  </Button>
                </span>
              </TooltipTrigger>
              {!sameInsurer && <TooltipContent>Select commissions from one insurer</TooltipContent>}
            </Tooltip>
            <Button size="sm" variant="ghost" className="text-primary-foreground hover:bg-primary-foreground/20 hover:text-primary-foreground" onClick={() => setSelectedIds(new Set())}>
              Clear
            </Button>
          </div>
        </div>
      )}

      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search policy, client, insurer..."
            className="pl-9 bg-card"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
        <div className="flex gap-2">
          <Button variant="secondary" onClick={handleExportCsv}>
            <Download className="w-4 h-4 mr-2" /> Export CSV
          </Button>
          <Select value={statusFilter} onValueChange={setStatusFilter}>
            <SelectTrigger className="w-[180px] bg-card">
              <Filter className="w-4 h-4 mr-2 text-muted-foreground" />
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Statuses</SelectItem>
              <SelectItem value="pending">Pending</SelectItem>
              <SelectItem value="part_paid">Part-paid</SelectItem>
              <SelectItem value="received">Received</SelectItem>
              <SelectItem value="overdue">Overdue</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="border rounded-md bg-card overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow>
              {!isAgent && (
                <TableHead className="w-12 text-center">
                  <Checkbox 
                    checked={!!filteredCommissions && filteredCommissions.filter(c => remainingOf(c) > 0).length > 0 && selectedIds.size === filteredCommissions.filter(c => remainingOf(c) > 0).length}
                    onCheckedChange={toggleSelectAll}
                  />
                </TableHead>
              )}
              <TableHead>Policy & Client</TableHead>
              <TableHead>Insurer</TableHead>
              <TableHead className="text-right">Amount (KES)</TableHead>
              <TableHead>Dates</TableHead>
              <TableHead>Status</TableHead>
              {!isAgent && <TableHead className="text-right">Action</TableHead>}
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow><TableCell colSpan={isAgent ? 5 : 7} className="text-center py-8">Loading...</TableCell></TableRow>
            ) : filteredCommissions?.length === 0 ? (
              <TableRow><TableCell colSpan={isAgent ? 5 : 7} className="text-center py-8 text-muted-foreground">No commission records found.</TableCell></TableRow>
            ) : (
              filteredCommissions?.map((comm) => {
                const isOverdue = isOverdueRow(comm);
                const receivedOn = lastReceivedOn(comm);
                const remaining = remainingOf(comm);
                
                return (
                  <TableRow key={comm.id}>
                    {!isAgent && (
                      <TableCell className="text-center">
                        <Checkbox 
                          checked={remaining <= 0 ? true : selectedIds.has(comm.id)}
                          disabled={remaining <= 0}
                          onCheckedChange={() => toggleSelectRow(comm.id)}
                        />
                      </TableCell>
                    )}
                    <TableCell>
                      <div className="font-medium">{comm.policy?.policy_number}</div>
                      <div className="text-xs text-muted-foreground">{comm.policy?.client?.name ?? '—'}</div>
                    </TableCell>
                    <TableCell className="font-medium">
                      {comm.policy?.insurer?.name}
                    </TableCell>
                    <TableCell className="text-right font-medium">
                      {formatCurrency(comm.amount)}
                    </TableCell>
                    <TableCell>
                      <div className="text-sm">Expected: {formatDate(comm.expected_date)}</div>
                      {receivedOn && <div className="text-xs text-emerald-600">Received: {formatDate(receivedOn)}</div>}
                    </TableCell>
                    <TableCell>
                      <div className="flex flex-wrap items-center gap-1">
                        {comm.status === 'part_paid' ? (
                          <Badge variant="warning">Part-paid</Badge>
                        ) : (
                          <Badge variant={getStatusColor(comm.status)} className="capitalize">{comm.status}</Badge>
                        )}
                        {isOverdue && <Badge variant="destructive">Overdue</Badge>}
                      </div>
                      {comm.status === 'part_paid' && (
                        <div className="text-xs text-muted-foreground mt-1">
                          {formatCurrency(comm.amount_received)} / {formatCurrency(comm.amount)}
                        </div>
                      )}
                      {!isAgent && ((comm.allocations ?? []) as any[]).length > 0 && (
                        <div className="text-xs mt-1 space-x-2">
                          {Array.from(new Map(((comm.allocations ?? []) as any[]).filter(a => a.receipt?.id).map(a => [a.receipt.id, a.receipt])).values()).map((r: any) => (
                            <Link key={r.id} href={`/receipts/${r.id}`} className="text-primary underline">
                              Receipt {formatDate(r.received_on)}
                            </Link>
                          ))}
                        </div>
                      )}
                    </TableCell>
                    {!isAgent && (
                      <TableCell className="text-right">
                        {remaining > 0 && (
                          <Button size="sm" variant="outline" onClick={() => openReceiveDialog(comm)}>
                            <CheckCircle2 className="w-4 h-4 mr-2" /> Record payment
                          </Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                );
              })
            )}
          </TableBody>
        </Table>
      </div>

      {!isAgent && (
      <Dialog open={!!payingComm} onOpenChange={(open) => !open && setPayingComm(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Record payment</DialogTitle>
            <DialogDescription>
              {payingComm?.policy?.policy_number} - {payingComm?.policy?.insurer?.name}. Remaining {payingComm ? formatCurrency(remainingOf(payingComm)) : ''}.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">Date received</label>
              <Input type="date" value={payDate} onChange={(e) => setPayDate(e.target.value)} />
            </div>
            <div className="space-y-2">
              <label className="text-sm font-medium">Amount received (KES)</label>
              <Input type="number" value={payAmount} onChange={(e) => setPayAmount(e.target.value)} />
            </div>
            <div className="space-y-2">
              <label className="text-sm font-medium">Bank reference (optional)</label>
              <Input value={payRef} onChange={(e) => setPayRef(e.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPayingComm(null)}>Cancel</Button>
            <Button onClick={handleReceive} disabled={createReceipt.isPending || !(parseFloat(payAmount) > 0) || !payDate}>
              {createReceipt.isPending ? "Saving..." : "Record payment"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      )}

      {!isAgent && (
      <Dialog open={bulkOpen} onOpenChange={setBulkOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Record payment for selected</DialogTitle>
            <DialogDescription>
              {selectedComms.length} commission{selectedComms.length === 1 ? '' : 's'}, {formatCurrency(selectedTotal)} in total (each paid in full).
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">Date received</label>
              <Input type="date" value={payDate} onChange={(e) => setPayDate(e.target.value)} />
            </div>
            <div className="space-y-2">
              <label className="text-sm font-medium">Bank reference (optional)</label>
              <Input value={payRef} onChange={(e) => setPayRef(e.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setBulkOpen(false)}>Cancel</Button>
            <Button onClick={handleBulkRecord} disabled={createReceipt.isPending || !sameInsurer || !payDate}>
              {createReceipt.isPending ? "Saving..." : "Record payment"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      )}
    </div>
  );
}
