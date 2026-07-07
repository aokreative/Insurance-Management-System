import React, { useState } from 'react';
import { useLocation } from 'wouter';
import { useClients, useCreateClient, useUpdateClient, useDeleteClient } from '@/hooks/queries';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Search, Plus, Building2, User, Download, Edit, Trash2 } from 'lucide-react';
import { 
  Sheet, 
  SheetContent, 
  SheetDescription, 
  SheetHeader, 
  SheetTitle, 
  SheetTrigger 
} from '@/components/ui/sheet';
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { ClientType } from '@/lib/types';
import { exportToCsv } from '@/lib/csv-export';

const clientSchema = z.object({
  name: z.string().min(2, 'Name is required'),
  type: z.enum(['individual', 'corporate'] as const),
  phone: z.string().optional().nullable(),
  email: z.string().email('Invalid email').optional().or(z.literal('')).nullable(),
  kra_pin: z.string().optional().nullable(),
  id_or_reg_number: z.string().optional().nullable(),
  address: z.string().optional().nullable(),
});

type ClientFormValues = z.infer<typeof clientSchema>;

export default function Clients() {
  const [searchTerm, setSearchTerm] = useState('');
  const [isAddSheetOpen, setIsAddSheetOpen] = useState(false);
  const [editingClient, setEditingClient] = useState<any | null>(null);
  const [deleteId, setDeleteId] = useState<string | null>(null);
  
  const [, setLocation] = useLocation();
  const { data: clients, isLoading } = useClients();
  const createClient = useCreateClient();
  const updateClient = useUpdateClient();
  const deleteClient = useDeleteClient();
  const { toast } = useToast();

  const form = useForm<ClientFormValues>({
    resolver: zodResolver(clientSchema),
    defaultValues: {
      name: '',
      type: 'individual',
      phone: '',
      email: '',
      kra_pin: '',
      id_or_reg_number: '',
      address: '',
    },
  });

  const filteredClients = clients?.filter(c => 
    c.name.toLowerCase().includes(searchTerm.toLowerCase()) || 
    c.email?.toLowerCase().includes(searchTerm.toLowerCase()) ||
    c.phone?.includes(searchTerm) ||
    c.kra_pin?.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const onSubmit = (values: ClientFormValues) => {
    if (editingClient) {
      updateClient.mutate({ id: editingClient.id, ...values }, {
        onSuccess: () => {
          toast({ title: 'Client updated successfully' });
          setIsAddSheetOpen(false);
          setEditingClient(null);
          form.reset();
        },
        onError: (error) => {
          toast({ title: 'Error updating client', description: error.message, variant: 'destructive' });
        }
      });
    } else {
      createClient.mutate(values, {
        onSuccess: () => {
          toast({ title: 'Client created successfully' });
          setIsAddSheetOpen(false);
          form.reset();
        },
        onError: (error) => {
          toast({ title: 'Error creating client', description: error.message, variant: 'destructive' });
        }
      });
    }
  };

  const openEdit = (client: any, e: React.MouseEvent) => {
    e.stopPropagation();
    setEditingClient(client);
    form.reset({
      name: client.name,
      type: client.type,
      phone: client.phone || '',
      email: client.email || '',
      kra_pin: client.kra_pin || '',
      id_or_reg_number: client.id_or_reg_number || '',
      address: client.address || '',
    });
    setIsAddSheetOpen(true);
  };

  const handleDelete = () => {
    if (!deleteId) return;
    deleteClient.mutate(deleteId, {
      onSuccess: () => {
        toast({ title: 'Client deleted' });
        setDeleteId(null);
      },
      onError: (error) => {
        toast({ title: 'Error deleting client', description: error.message, variant: 'destructive' });
      }
    });
  };

  const handleExportCsv = () => {
    if (!clients) return;
    const exportData = clients.map(c => ({
      id: c.id,
      name: c.name,
      type: c.type,
      email: c.email || '',
      phone: c.phone || '',
      kra_pin: c.kra_pin || '',
      address: c.address || '',
      created_at: c.created_at
    }));
    exportToCsv('clients', exportData);
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Clients</h1>
          <p className="text-muted-foreground">Manage your individual and corporate clients.</p>
        </div>
        
        <Sheet open={isAddSheetOpen} onOpenChange={(open) => {
          setIsAddSheetOpen(open);
          if (!open) {
            setEditingClient(null);
            form.reset({ name: '', type: 'individual', phone: '', email: '', kra_pin: '', id_or_reg_number: '', address: '' });
          }
        }}>
          <SheetTrigger asChild>
            <Button data-testid="button-add-client">
              <Plus className="w-4 h-4 mr-2" /> Add Client
            </Button>
          </SheetTrigger>
          <SheetContent className="w-full sm:max-w-md overflow-y-auto">
            <SheetHeader>
              <SheetTitle>{editingClient ? 'Edit Client' : 'Add New Client'}</SheetTitle>
              <SheetDescription>
                {editingClient ? 'Update the client profile details.' : 'Create a new client profile. Click save when you\'re done.'}
              </SheetDescription>
            </SheetHeader>
            
            <Form {...form}>
              <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4 mt-6">
                <FormField
                  control={form.control}
                  name="type"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Client Type</FormLabel>
                      <Select onValueChange={field.onChange} defaultValue={field.value}>
                        <FormControl>
                          <SelectTrigger>
                            <SelectValue placeholder="Select type" />
                          </SelectTrigger>
                        </FormControl>
                        <SelectContent>
                          <SelectItem value="individual">Individual</SelectItem>
                          <SelectItem value="corporate">Corporate</SelectItem>
                        </SelectContent>
                      </Select>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <FormField
                  control={form.control}
                  name="name"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Full Name / Company Name</FormLabel>
                      <FormControl>
                        <Input placeholder="Enter name" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="phone"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Phone Number</FormLabel>
                        <FormControl>
                          <Input placeholder="07XX XXX XXX" {...field} value={field.value || ''} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="email"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Email Address</FormLabel>
                        <FormControl>
                          <Input type="email" placeholder="email@example.com" {...field} value={field.value || ''} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <FormField
                    control={form.control}
                    name="kra_pin"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>KRA PIN</FormLabel>
                        <FormControl>
                          <Input placeholder="A000000000A" {...field} value={field.value || ''} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="id_or_reg_number"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>{form.watch('type') === 'corporate' ? 'Reg Number' : 'ID Number'}</FormLabel>
                        <FormControl>
                          <Input placeholder="Enter number" {...field} value={field.value || ''} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>

                <FormField
                  control={form.control}
                  name="address"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Physical Address</FormLabel>
                      <FormControl>
                        <Input placeholder="P.O Box... or Physical Location" {...field} value={field.value || ''} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <div className="pt-4">
                  <Button type="submit" className="w-full" disabled={createClient.isPending || updateClient.isPending}>
                    {createClient.isPending || updateClient.isPending ? "Saving..." : "Save Client"}
                  </Button>
                </div>
              </form>
            </Form>
          </SheetContent>
        </Sheet>
      </div>

      <div className="flex items-center space-x-2">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search by name, email, KRA PIN..."
            className="pl-9 bg-card"
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
        <Button variant="secondary" size="sm" onClick={handleExportCsv} className="ml-auto">
          <Download className="w-4 h-4 mr-2" /> Export CSV
        </Button>
      </div>

      <div className="border rounded-md bg-card overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Name</TableHead>
              <TableHead>Type</TableHead>
              <TableHead>Contact</TableHead>
              <TableHead>Identifiers</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow>
                <TableCell colSpan={5} className="text-center py-8">Loading clients...</TableCell>
              </TableRow>
            ) : filteredClients?.length === 0 ? (
              <TableRow>
                <TableCell colSpan={5} className="text-center py-8 text-muted-foreground">
                  No clients found. {searchTerm && "Try a different search."}
                </TableCell>
              </TableRow>
            ) : (
              filteredClients?.map((client) => (
                <TableRow 
                  key={client.id} 
                  className="cursor-pointer hover:bg-muted/50"
                  onClick={() => setLocation(`/clients/${client.id}`)}
                >
                  <TableCell className="font-medium">{client.name}</TableCell>
                  <TableCell>
                    <Badge variant={client.type === 'corporate' ? 'default' : 'secondary'} className="gap-1">
                      {client.type === 'corporate' ? <Building2 className="w-3 h-3" /> : <User className="w-3 h-3" />}
                      <span className="capitalize">{client.type}</span>
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <div className="text-sm">{client.phone || '-'}</div>
                    <div className="text-xs text-muted-foreground">{client.email || '-'}</div>
                  </TableCell>
                  <TableCell>
                    {client.kra_pin && <div className="text-sm">KRA: {client.kra_pin}</div>}
                    {client.id_or_reg_number && <div className="text-xs text-muted-foreground">ID/Reg: {client.id_or_reg_number}</div>}
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="ghost" size="icon" onClick={(e) => openEdit(client, e)}>
                      <Edit className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" className="text-destructive hover:text-destructive hover:bg-destructive/10" onClick={(e) => { e.stopPropagation(); setDeleteId(client.id); }}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
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
            <AlertDialogTitle>Delete Client?</AlertDialogTitle>
            <AlertDialogDescription>
              This will also remove all linked policies and data. This action cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => setDeleteId(null)}>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete} className="bg-destructive text-destructive-foreground hover:bg-destructive/90" disabled={deleteClient.isPending}>
              {deleteClient.isPending ? "Deleting..." : "Delete"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
