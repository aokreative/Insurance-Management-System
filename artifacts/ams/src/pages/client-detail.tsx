import React, { useState, useEffect } from 'react';
import { useRoute } from 'wouter';
import { useClient, useUpdateClient, usePolicies, useInsurers, useProductLines, useCreatePolicy, useAgencyUsers, useDeletePolicy } from '@/hooks/queries';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Edit, FileText, ArrowLeft, Building2, User, Plus, Trash2 } from 'lucide-react';
import { formatCurrency, formatDate, getStatusColor } from '@/lib/utils';
import { useToast } from '@/hooks/use-toast';
import { 
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useAuth } from '@/contexts/AuthContext';

const policySchema = z.object({
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

export default function ClientDetail() {
  const [, params] = useRoute('/clients/:id');
  const clientId = params?.id || '';
  const { profile } = useAuth();
  
  const { data: client, isLoading: isClientLoading } = useClient(clientId);
  const { data: policies, isLoading: isPoliciesLoading } = usePolicies({ clientId });
  const { data: insurers } = useInsurers();
  const { data: productLines } = useProductLines();
  const { data: users } = useAgencyUsers();
  
  const updateClient = useUpdateClient();
  const createPolicy = useCreatePolicy();
  const deletePolicy = useDeletePolicy();
  const { toast } = useToast();
  
  const [isEditClientOpen, setIsEditClientOpen] = useState(false);
  const [isAddPolicyOpen, setIsAddPolicyOpen] = useState(false);
  const [deletePolicyId, setDeletePolicyId] = useState<string | null>(null);
  
  const form = useForm({
    resolver: zodResolver(policySchema),
    defaultValues: {
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
  
  // Set default agent_id when profile loads
  useEffect(() => {
    if (profile?.id && !form.getValues('agent_id')) {
      form.setValue('agent_id', profile.id);
    }
  }, [profile?.id, form]);

  if (isClientLoading) return <div className="p-8">Loading client details...</div>;
  if (!client) return <div className="p-8">Client not found</div>;

  const onAddPolicy = (values: z.infer<typeof policySchema>) => {
    createPolicy.mutate({
      ...values,
      client_id: clientId,
    }, {
      onSuccess: () => {
        toast({ title: 'Policy added' });
        setIsAddPolicyOpen(false);
        form.reset();
      },
      onError: (err) => {
        toast({ title: 'Error adding policy', description: err.message, variant: 'destructive' });
      }
    });
  };

  const handleDeletePolicy = () => {
    if (!deletePolicyId) return;
    deletePolicy.mutate(deletePolicyId, {
      onSuccess: () => {
        toast({ title: 'Policy deleted' });
        setDeletePolicyId(null);
      },
      onError: (err) => {
        toast({ title: 'Error deleting policy', description: err.message, variant: 'destructive' });
      }
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-4">
        <Button variant="outline" size="icon" onClick={() => window.history.back()}>
          <ArrowLeft className="h-4 w-4" />
        </Button>
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-3xl font-bold tracking-tight">{client.name}</h1>
            <Badge variant={client.type === 'corporate' ? 'default' : 'secondary'} className="gap-1">
              {client.type === 'corporate' ? <Building2 className="w-3 h-3" /> : <User className="w-3 h-3" />}
              <span className="capitalize">{client.type}</span>
            </Badge>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <Card className="md:col-span-1">
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-lg">Contact Information</CardTitle>
            <Button variant="ghost" size="icon" onClick={() => setIsEditClientOpen(true)}>
              <Edit className="h-4 w-4" />
            </Button>
          </CardHeader>
          <CardContent className="space-y-4">
            <div>
              <div className="text-sm font-medium text-muted-foreground">Email</div>
              <div>{client.email || '-'}</div>
            </div>
            <div>
              <div className="text-sm font-medium text-muted-foreground">Phone</div>
              <div>{client.phone || '-'}</div>
            </div>
            <div>
              <div className="text-sm font-medium text-muted-foreground">Address</div>
              <div>{client.address || '-'}</div>
            </div>
            <div className="pt-4 border-t">
              <div className="text-sm font-medium text-muted-foreground">Identifiers</div>
              <div className="grid grid-cols-2 mt-2">
                <div>
                  <div className="text-xs text-muted-foreground">KRA PIN</div>
                  <div className="text-sm font-medium">{client.kra_pin || '-'}</div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground">{client.type === 'corporate' ? 'Reg No.' : 'ID No.'}</div>
                  <div className="text-sm font-medium">{client.id_or_reg_number || '-'}</div>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card className="md:col-span-2 flex flex-col">
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-lg">Policies</CardTitle>
            
            <Dialog open={isAddPolicyOpen} onOpenChange={setIsAddPolicyOpen}>
              <DialogTrigger asChild>
                <Button size="sm"><Plus className="w-4 h-4 mr-2" /> Add Policy</Button>
              </DialogTrigger>
              <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
                <DialogHeader>
                  <DialogTitle>Add New Policy for {client.name}</DialogTitle>
                  <DialogDescription>Enter the policy details below.</DialogDescription>
                </DialogHeader>
                
                <Form {...form}>
                  <form onSubmit={form.handleSubmit(onAddPolicy)} className="space-y-4 mt-4">
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
                    
                    <div className="p-3 bg-muted/50 rounded-md text-sm flex justify-between items-center">
                      <span className="font-medium text-muted-foreground">Expected Commission:</span>
                      <span className="font-bold">
                        {formatCurrency((form.watch('premium_amount') || 0) * (form.watch('commission_rate') || 0) / 100)}
                      </span>
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
          </CardHeader>
          <CardContent className="flex-1 p-0">
            {isPoliciesLoading ? (
              <div className="p-4 text-center">Loading policies...</div>
            ) : !policies || policies.length === 0 ? (
              <div className="flex flex-col items-center justify-center py-12 text-muted-foreground border-t">
                <FileText className="h-12 w-12 mb-4 opacity-20" />
                <p>No policies recorded for this client.</p>
              </div>
            ) : (
              <div className="border-t">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Policy #</TableHead>
                      <TableHead>Details</TableHead>
                      <TableHead className="text-right">Premium</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead className="w-[50px]"></TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {policies.map(policy => (
                      <TableRow key={policy.id}>
                        <TableCell className="font-medium">{policy.policy_number}</TableCell>
                        <TableCell>
                          <div className="text-sm font-medium">{policy.product_line?.name}</div>
                          <div className="text-xs text-muted-foreground">{policy.insurer?.name}</div>
                          <div className="text-xs text-muted-foreground mt-1">Exp: {formatDate(policy.expiry_date)}</div>
                        </TableCell>
                        <TableCell className="text-right font-medium">
                          {formatCurrency(policy.premium_amount)}
                        </TableCell>
                        <TableCell>
                          <Badge variant={getStatusColor(policy.status)} className="capitalize">
                            {policy.status}
                          </Badge>
                        </TableCell>
                        <TableCell>
                          <Button variant="ghost" size="icon" className="text-destructive hover:text-destructive hover:bg-destructive/10" onClick={() => setDeletePolicyId(policy.id)}>
                            <Trash2 className="h-4 w-4" />
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <AlertDialog open={!!deletePolicyId} onOpenChange={(open) => !open && setDeletePolicyId(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete Policy?</AlertDialogTitle>
            <AlertDialogDescription>
              Are you sure you want to delete this policy? This action cannot be undone and will delete associated commission records.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => setDeletePolicyId(null)}>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDeletePolicy} className="bg-destructive text-destructive-foreground hover:bg-destructive/90" disabled={deletePolicy.isPending}>
              {deletePolicy.isPending ? "Deleting..." : "Delete"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
