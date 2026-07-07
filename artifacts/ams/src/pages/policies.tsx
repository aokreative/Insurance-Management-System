import React, { useState } from 'react';
import { usePolicies, useInsurers, useProductLines, useClients, useAgencyUsers, useCreatePolicy, useUpdatePolicy, useDeletePolicy } from '@/hooks/queries';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { formatCurrency, formatDate, getStatusColor } from '@/lib/utils';
import { Search, Plus, Filter, MoreHorizontal, Edit, Trash2, Download } from 'lucide-react';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger, DialogFooter } from '@/components/ui/dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { Policy } from '@/lib/types';
import { exportToCsv } from '@/lib/csv-export';

// Omitted schema/form for brevity, will implement fully if requested, but going all the way:
const policySchema = z.object({
  client_id: z.string().min(1, 'Required'),
  insurer_id: z.string().min(1, 'Required'),
  product_line_id: z.string().min(1, 'Required'),
  agent_id: z.string().min(1, 'Required'),
  policy_number: z.string().min(1, 'Required'),
  premium_amount: z.coerce.number().min(1, 'Must be positive'),
  commission_rate: z.coerce.number().min(0).max(100),
  start_date: z.string().min(1, 'Required'),
  expiry_date: z.string().min(1, 'Required'),
  status: z.enum(['active', 'expired', 'cancelled', 'pending']),
  notes: z.string().optional(),
});

export default function Policies() {
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [insurerFilter, setInsurerFilter] = useState('all');
  const [isAddOpen, setIsAddOpen] = useState(false);
  const [deleteId, setDeleteId] = useState<string | null>(null);
  
  const { profile } = useAuth();
  const { toast } = useToast();
  
  const { data: policies, isLoading } = usePolicies({ 
    status: statusFilter,
    insurerId: insurerFilter 
  });
  
  const { data: clients } = useClients();
  const { data: insurers } = useInsurers();
  const { data: productLines } = useProductLines();
  const { data: users } = useAgencyUsers();
  
  const createPolicy = useCreatePolicy();
  const deletePolicy = useDeletePolicy();

  const form = useForm({
    resolver: zodResolver(policySchema),
    defaultValues: {
      client_id: '',
      insurer_id: '',
      product_line_id: '',
      agent_id: profile?.id || '',
      policy_number: '',
      premium_amount: 0,
      commission_rate: 10,
      start_date: new Date().toISOString().split('T')[0],
      expiry_date: new Date(new Date().setFullYear(new Date().getFullYear() + 1)).toISOString().split('T')[0],
      status: 'active' as const,
      notes: '',
    },
  });

  const filteredPolicies = policies?.filter(p => 
    p.policy_number.toLowerCase().includes(searchTerm.toLowerCase()) ||
    p.client?.name.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const onSubmit = (values: z.infer<typeof policySchema>) => {
    createPolicy.mutate(values, {
      onSuccess: () => {
        toast({ title: 'Policy created' });
        setIsAddOpen(false);
        form.reset();
      },
      onError: (err) => {
        toast({ title: 'Error', description: err.message, variant: 'destructive' });
      }
    });
  };
  
  const handleDelete = () => {
    if (!deleteId) return;
    deletePolicy.mutate(deleteId, {
      onSuccess: () => {
        toast({ title: 'Policy deleted' });
        setDeleteId(null);
      }
    });
  };

  const handleExportCsv = () => {
    if (!policies) return;
    const exportData = policies.map(p => ({
      policy_number: p.policy_number,
      client_name: p.client?.name || '',
      insurer_name: p.insurer?.name || '',
      product_line: p.product_line?.name || '',
      status: p.status,
      premium_amount: p.premium_amount,
      commission_rate: p.commission_rate,
      commission_expected: p.commission_expected,
      commission_received: p.commission_received,
      start_date: p.start_date,
      expiry_date: p.expiry_date
    }));
    exportToCsv('policies', exportData);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Policies</h1>
          <p className="text-muted-foreground">Manage all insurance policies across your agency.</p>
        </div>
        
        <Dialog open={isAddOpen} onOpenChange={setIsAddOpen}>
          <DialogTrigger asChild>
            <Button><Plus className="w-4 h-4 mr-2" /> Create Policy</Button>
          </DialogTrigger>
          <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
            <DialogHeader>
              <DialogTitle>Create New Policy</DialogTitle>
              <DialogDescription>Record a new policy in the system.</DialogDescription>
            </DialogHeader>
            <Form {...form}>
              <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
                <FormField
                  control={form.control}
                  name="client_id"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Client</FormLabel>
                      <Select onValueChange={field.onChange} value={field.value}>
                        <FormControl><SelectTrigger><SelectValue placeholder="Select client" /></SelectTrigger></FormControl>
                        <SelectContent>
                          {clients?.map(c => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}
                        </SelectContent>
                      </Select>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="insurer_id"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Insurer</FormLabel>
                        <Select onValueChange={field.onChange} value={field.value}>
                          <FormControl><SelectTrigger><SelectValue placeholder="Select insurer" /></SelectTrigger></FormControl>
                          <SelectContent>
                            {insurers?.map(i => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
                          </SelectContent>
                        </Select>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="product_line_id"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Product Line</FormLabel>
                        <Select onValueChange={field.onChange} value={field.value}>
                          <FormControl><SelectTrigger><SelectValue placeholder="Select product" /></SelectTrigger></FormControl>
                          <SelectContent>
                            {productLines?.map(p => <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>)}
                          </SelectContent>
                        </Select>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                
                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="policy_number"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Policy Number</FormLabel>
                        <FormControl><Input {...field} /></FormControl>
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
                            <SelectItem value="active">Active</SelectItem>
                            <SelectItem value="pending">Pending</SelectItem>
                            <SelectItem value="expired">Expired</SelectItem>
                            <SelectItem value="cancelled">Cancelled</SelectItem>
                          </SelectContent>
                        </Select>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="premium_amount"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Premium (KES)</FormLabel>
                        <FormControl><Input type="number" {...field} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="commission_rate"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Commission Rate (%)</FormLabel>
                        <FormControl><Input type="number" step="0.1" {...field} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                
                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="start_date"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Start Date</FormLabel>
                        <FormControl><Input type="date" {...field} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="expiry_date"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Expiry Date</FormLabel>
                        <FormControl><Input type="date" {...field} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                
                {(profile?.role === 'admin' || profile?.role === 'owner') && (
                  <FormField
                    control={form.control}
                    name="agent_id"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Assigned Agent</FormLabel>
                        <Select onValueChange={field.onChange} value={field.value}>
                          <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
                          <SelectContent>
                            {users?.map(u => <SelectItem key={u.id} value={u.id}>{u.full_name}</SelectItem>)}
                          </SelectContent>
                        </Select>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                )}

                <Button type="submit" className="w-full mt-4" disabled={createPolicy.isPending}>
                  {createPolicy.isPending ? "Saving..." : "Save Policy"}
                </Button>
              </form>
            </Form>
          </DialogContent>
        </Dialog>
      </div>

      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search policy # or client..."
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
            <SelectTrigger className="w-[140px] bg-card"><SelectValue placeholder="Status" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Statuses</SelectItem>
              <SelectItem value="active">Active</SelectItem>
              <SelectItem value="pending">Pending</SelectItem>
              <SelectItem value="expired">Expired</SelectItem>
              <SelectItem value="cancelled">Cancelled</SelectItem>
            </SelectContent>
          </Select>
          <Select value={insurerFilter} onValueChange={setInsurerFilter}>
            <SelectTrigger className="w-[180px] bg-card"><SelectValue placeholder="Insurer" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Insurers</SelectItem>
              {insurers?.map(i => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="border rounded-md bg-card overflow-hidden">
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Policy & Client</TableHead>
                <TableHead>Product & Insurer</TableHead>
                <TableHead className="text-right">Premium</TableHead>
                <TableHead className="text-right">Expected Comm.</TableHead>
                <TableHead>Dates</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-[50px]"></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                <TableRow><TableCell colSpan={7} className="text-center py-8">Loading...</TableCell></TableRow>
              ) : filteredPolicies?.length === 0 ? (
                <TableRow><TableCell colSpan={7} className="text-center py-8">No policies found.</TableCell></TableRow>
              ) : (
                filteredPolicies?.map((policy) => (
                  <TableRow key={policy.id}>
                    <TableCell>
                      <div className="font-medium text-primary">{policy.policy_number}</div>
                      <div className="text-sm font-medium">{policy.client?.name}</div>
                    </TableCell>
                    <TableCell>
                      <div className="text-sm font-medium">{policy.product_line?.name}</div>
                      <div className="text-xs text-muted-foreground">{policy.insurer?.name}</div>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="font-medium">{formatCurrency(policy.premium_amount)}</div>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="font-medium text-emerald-600 dark:text-emerald-500">
                        {formatCurrency(policy.commission_expected)}
                      </div>
                      <div className="text-xs text-muted-foreground">{policy.commission_rate}%</div>
                    </TableCell>
                    <TableCell>
                      <div className="text-sm">{formatDate(policy.start_date)}</div>
                      <div className="text-xs text-muted-foreground">to {formatDate(policy.expiry_date)}</div>
                    </TableCell>
                    <TableCell>
                      <Badge variant={getStatusColor(policy.status)} className="capitalize">
                        {policy.status}
                      </Badge>
                    </TableCell>
                    <TableCell>
                      <DropdownMenu>
                        <DropdownMenuTrigger asChild>
                          <Button variant="ghost" className="h-8 w-8 p-0">
                            <span className="sr-only">Open menu</span>
                            <MoreHorizontal className="h-4 w-4" />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end">
                          <DropdownMenuLabel>Actions</DropdownMenuLabel>
                          <DropdownMenuItem onClick={() => {}} disabled>
                            <Edit className="mr-2 h-4 w-4" /> Edit Policy
                          </DropdownMenuItem>
                          <DropdownMenuSeparator />
                          <DropdownMenuItem className="text-destructive focus:bg-destructive/10" onClick={() => setDeleteId(policy.id)}>
                            <Trash2 className="mr-2 h-4 w-4" /> Delete Policy
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </div>
      </div>
      
      {/* Delete Confirmation */}
      <Dialog open={!!deleteId} onOpenChange={(open) => !open && setDeleteId(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Policy</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete this policy? This action cannot be undone and will delete associated commission records.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteId(null)}>Cancel</Button>
            <Button variant="destructive" onClick={handleDelete} disabled={deletePolicy.isPending}>
              {deletePolicy.isPending ? "Deleting..." : "Delete"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
