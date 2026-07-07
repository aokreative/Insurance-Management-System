import React, { useState } from 'react';
import { useInsurers, useCreateInsurer, useUpdateInsurer, useDeleteInsurer } from '@/hooks/queries';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Search, Plus, Edit, ShieldBan, ShieldCheck, Download, Trash2 } from 'lucide-react';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { useToast } from '@/hooks/use-toast';
import { Switch } from '@/components/ui/switch';
import { exportToCsv } from '@/lib/csv-export';

const insurerSchema = z.object({
  name: z.string().min(2, 'Name is required'),
  contact_email: z.string().email('Invalid email').optional().or(z.literal('')).nullable(),
  contact_phone: z.string().optional().nullable(),
  website: z.string().url('Invalid URL').optional().or(z.literal('')).nullable(),
  is_active: z.boolean().default(true),
});

type InsurerFormValues = z.infer<typeof insurerSchema>;

export default function Insurers() {
  const [searchTerm, setSearchTerm] = useState('');
  const [isAddOpen, setIsAddOpen] = useState(false);
  const [editingInsurer, setEditingInsurer] = useState<any | null>(null);
  const [deleteId, setDeleteId] = useState<string | null>(null);
  
  const { data: insurers, isLoading } = useInsurers();
  const createInsurer = useCreateInsurer();
  const updateInsurer = useUpdateInsurer();
  const deleteInsurer = useDeleteInsurer();
  const { toast } = useToast();

  const form = useForm<InsurerFormValues>({
    resolver: zodResolver(insurerSchema),
    defaultValues: {
      name: '',
      contact_email: '',
      contact_phone: '',
      website: '',
      is_active: true,
    },
  });

  const filteredInsurers = insurers?.filter(i => 
    i.name.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const onSubmit = (values: InsurerFormValues) => {
    if (editingInsurer) {
      updateInsurer.mutate({ id: editingInsurer.id, ...values }, {
        onSuccess: () => {
          toast({ title: 'Insurer updated' });
          setIsAddOpen(false);
          setEditingInsurer(null);
          form.reset();
        }
      });
    } else {
      createInsurer.mutate(values, {
        onSuccess: () => {
          toast({ title: 'Insurer added' });
          setIsAddOpen(false);
          form.reset();
        }
      });
    }
  };

  const openEdit = (insurer: any) => {
    setEditingInsurer(insurer);
    form.reset({
      name: insurer.name,
      contact_email: insurer.contact_email || '',
      contact_phone: insurer.contact_phone || '',
      website: insurer.website || '',
      is_active: insurer.is_active,
    });
    setIsAddOpen(true);
  };

  const toggleActive = (insurer: any, checked: boolean) => {
    updateInsurer.mutate({ id: insurer.id, is_active: checked }, {
      onSuccess: () => toast({ title: checked ? 'Insurer activated' : 'Insurer deactivated' })
    });
  };

  const handleDelete = () => {
    if (!deleteId) return;
    deleteInsurer.mutate(deleteId, {
      onSuccess: () => {
        toast({ title: 'Insurer deleted' });
        setDeleteId(null);
      },
      onError: (err) => {
        toast({ title: 'Error deleting insurer', description: err.message, variant: 'destructive' });
      }
    });
  };

  const handleExportCsv = () => {
    if (!insurers) return;
    const exportData = insurers.map(i => ({
      name: i.name,
      contact_email: i.contact_email || '',
      contact_phone: i.contact_phone || '',
      website: i.website || '',
      is_active: i.is_active
    }));
    exportToCsv('insurers', exportData);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Insurers</h1>
          <p className="text-muted-foreground">Manage the insurance companies you broker for.</p>
        </div>
        
        <Dialog open={isAddOpen} onOpenChange={(open) => {
          setIsAddOpen(open);
          if (!open) {
            setEditingInsurer(null);
            form.reset({ name: '', contact_email: '', contact_phone: '', website: '', is_active: true });
          }
        }}>
          <DialogTrigger asChild>
            <Button><Plus className="w-4 h-4 mr-2" /> Add Insurer</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{editingInsurer ? 'Edit Insurer' : 'Add New Insurer'}</DialogTitle>
              <DialogDescription>Enter the details for this underwriter.</DialogDescription>
            </DialogHeader>
            <Form {...form}>
              <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
                <FormField
                  control={form.control}
                  name="name"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Company Name</FormLabel>
                      <FormControl><Input {...field} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="contact_email"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Contact Email</FormLabel>
                        <FormControl><Input type="email" {...field} value={field.value || ''} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="contact_phone"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Contact Phone</FormLabel>
                        <FormControl><Input {...field} value={field.value || ''} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                <FormField
                  control={form.control}
                  name="website"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Website URL</FormLabel>
                      <FormControl><Input placeholder="https://" {...field} value={field.value || ''} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <FormField
                  control={form.control}
                  name="is_active"
                  render={({ field }) => (
                    <FormItem className="flex flex-row items-center justify-between rounded-lg border p-3 shadow-sm">
                      <div className="space-y-0.5">
                        <FormLabel>Active Status</FormLabel>
                        <p className="text-[0.8rem] text-muted-foreground">Active insurers appear in policy dropdowns.</p>
                      </div>
                      <FormControl>
                        <Switch checked={field.value} onCheckedChange={field.onChange} />
                      </FormControl>
                    </FormItem>
                  )}
                />
                <Button type="submit" className="w-full" disabled={createInsurer.isPending || updateInsurer.isPending}>
                  {editingInsurer ? "Save Changes" : "Add Insurer"}
                </Button>
              </form>
            </Form>
          </DialogContent>
        </Dialog>
      </div>

      <div className="flex items-center gap-2">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search insurers..."
            className="pl-9 bg-card"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
        <Button variant="secondary" size="sm" onClick={handleExportCsv}>
          <Download className="w-4 h-4 mr-2" /> Export CSV
        </Button>
      </div>

      <div className="border rounded-md bg-card overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Company Name</TableHead>
              <TableHead>Contact Email</TableHead>
              <TableHead>Phone</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow><TableCell colSpan={5} className="text-center py-8">Loading...</TableCell></TableRow>
            ) : filteredInsurers?.length === 0 ? (
              <TableRow><TableCell colSpan={5} className="text-center py-8 text-muted-foreground">No insurers found.</TableCell></TableRow>
            ) : (
              filteredInsurers?.map((insurer) => (
                <TableRow key={insurer.id} className={!insurer.is_active ? "opacity-60 bg-muted/30" : ""}>
                  <TableCell className="font-medium">
                    {insurer.name}
                    {insurer.website && <div className="text-xs text-muted-foreground font-normal hover:underline"><a href={insurer.website} target="_blank" rel="noreferrer">{insurer.website}</a></div>}
                  </TableCell>
                  <TableCell>{insurer.contact_email || '-'}</TableCell>
                  <TableCell>{insurer.contact_phone || '-'}</TableCell>
                  <TableCell>
                    {insurer.is_active ? (
                      <Badge variant="success" className="gap-1"><ShieldCheck className="w-3 h-3" /> Active</Badge>
                    ) : (
                      <Badge variant="secondary" className="gap-1"><ShieldBan className="w-3 h-3" /> Inactive</Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="ghost" size="icon" onClick={() => openEdit(insurer)}>
                      <Edit className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" className="text-destructive hover:text-destructive hover:bg-destructive/10 ml-1" onClick={() => setDeleteId(insurer.id)}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                    <Switch 
                      className="ml-2" 
                      checked={insurer.is_active} 
                      onCheckedChange={(c) => toggleActive(insurer, c)} 
                    />
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      <AlertDialog open={!!deleteId} onOpenChange={(open) => !open && setDeleteId(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete Insurer?</AlertDialogTitle>
            <AlertDialogDescription>
              Are you sure you want to delete this insurer? This action cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => setDeleteId(null)}>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete} className="bg-destructive text-destructive-foreground hover:bg-destructive/90" disabled={deleteInsurer.isPending}>
              {deleteInsurer.isPending ? "Deleting..." : "Delete"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
