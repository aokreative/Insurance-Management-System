import React, { useState } from 'react';
import { useCommissions, useUpdateCommission, useCreateCommission, usePolicies } from '@/hooks/queries';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
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
  status: z.enum(['pending', 'received']),
  expected_date: z.string().min(1, 'Required'),
  notes: z.string().optional()
});

type CommissionFormValues = z.infer<typeof commissionSchema>;

export default function Commissions() {
  const [statusFilter, setStatusFilter] = useState('all');
  const [searchTerm, setSearchTerm] = useState('');
  const [receivingId, setReceivingId] = useState<string | null>(null);
  const [receiveAmount, setReceiveAmount] = useState('');
  const [isAddOpen, setIsAddOpen] = useState(false);
  
  const { data: commissions, isLoading } = useCommissions({ status: statusFilter });
  const { data: policies } = usePolicies();
  const updateCommission = useUpdateCommission();
  const createCommission = useCreateCommission();
  const { toast } = useToast();

  const form = useForm<CommissionFormValues>({
    resolver: zodResolver(commissionSchema),
    defaultValues: {
      policy_id: '',
      amount: 0,
      status: 'pending',
      expected_date: new Date().toISOString().split('T')[0],
      notes: ''
    }
  });

  const filteredCommissions = commissions?.filter(c => 
    c.policy?.policy_number.toLowerCase().includes(searchTerm.toLowerCase()) ||
    c.policy?.client?.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
    c.policy?.insurer?.name.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const totalExpected = commissions?.reduce((sum, c) => sum + (c.amount || 0), 0) || 0;
  const totalReceived = commissions?.filter(c => c.status === 'received').reduce((sum, c) => sum + (c.amount || 0), 0) || 0;
  
  const today = new Date().toISOString().split('T')[0];
  const totalOverdue = commissions?.filter(c => c.status === 'pending' && c.expected_date && c.expected_date < today)
    .reduce((sum, c) => sum + (c.amount || 0), 0) || 0;

  const handleReceive = () => {
    if (!receivingId || !receiveAmount) return;
    
    updateCommission.mutate({
      id: receivingId,
      status: 'received',
      received_date: new Date().toISOString().split('T')[0],
      amount: parseFloat(receiveAmount)
    }, {
      onSuccess: () => {
        toast({ title: 'Commission marked as received' });
        setReceivingId(null);
        setReceiveAmount('');
      }
    });
  };

  const openReceiveDialog = (comm: any) => {
    setReceivingId(comm.id);
    setReceiveAmount(comm.amount.toString());
  };

  const onSubmitAdd = (values: CommissionFormValues) => {
    createCommission.mutate({
      ...values,
      received_date: values.status === 'received' ? new Date().toISOString().split('T')[0] : null
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
      received_date: c.received_date || ''
    }));
    exportToCsv('commissions', exportData);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Commissions</h1>
          <p className="text-muted-foreground">Track expected and received commissions.</p>
        </div>

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
                            <SelectItem key={p.id} value={p.id}>{p.policy_number} - {p.client?.name}</SelectItem>
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
                  <FormField
                    control={form.control}
                    name="status"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Status</FormLabel>
                        <Select onValueChange={field.onChange} value={field.value}>
                          <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
                          <SelectContent>
                            <SelectItem value="pending">Pending</SelectItem>
                            <SelectItem value="received">Received</SelectItem>
                          </SelectContent>
                        </Select>
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
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
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
      </div>

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
              <TableHead>Policy & Client</TableHead>
              <TableHead>Insurer</TableHead>
              <TableHead className="text-right">Amount (KES)</TableHead>
              <TableHead>Dates</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="text-right">Action</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow><TableCell colSpan={6} className="text-center py-8">Loading...</TableCell></TableRow>
            ) : filteredCommissions?.length === 0 ? (
              <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">No commission records found.</TableCell></TableRow>
            ) : (
              filteredCommissions?.map((comm) => {
                const isOverdue = comm.status === 'pending' && comm.expected_date && comm.expected_date < today;
                const displayStatus = isOverdue ? 'overdue' : comm.status;
                
                return (
                  <TableRow key={comm.id}>
                    <TableCell>
                      <div className="font-medium">{comm.policy?.policy_number}</div>
                      <div className="text-xs text-muted-foreground">{comm.policy?.client?.name}</div>
                    </TableCell>
                    <TableCell className="font-medium">
                      {comm.policy?.insurer?.name}
                    </TableCell>
                    <TableCell className="text-right font-medium">
                      {formatCurrency(comm.amount)}
                    </TableCell>
                    <TableCell>
                      <div className="text-sm">Expected: {formatDate(comm.expected_date)}</div>
                      {comm.received_date && <div className="text-xs text-emerald-600">Received: {formatDate(comm.received_date)}</div>}
                    </TableCell>
                    <TableCell>
                      <Badge variant={getStatusColor(displayStatus)} className="capitalize">
                        {displayStatus}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      {comm.status === 'pending' && (
                        <Button size="sm" variant="outline" onClick={() => openReceiveDialog(comm)}>
                          <CheckCircle2 className="w-4 h-4 mr-2" /> Mark Received
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })
            )}
          </TableBody>
        </Table>
      </div>

      <Dialog open={!!receivingId} onOpenChange={(open) => !open && setReceivingId(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Mark Commission Received</DialogTitle>
            <DialogDescription>Confirm the amount received from the insurer.</DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">Amount Received (KES)</label>
              <Input 
                type="number" 
                value={receiveAmount} 
                onChange={(e) => setReceiveAmount(e.target.value)} 
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setReceivingId(null)}>Cancel</Button>
            <Button onClick={handleReceive} disabled={updateCommission.isPending || !receiveAmount}>
              {updateCommission.isPending ? "Saving..." : "Confirm Receipt"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
