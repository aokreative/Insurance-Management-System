import React, { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Card, CardContent } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { formatDate } from '@/lib/utils';
import { BellRing, CalendarClock, CheckCircle2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { addDays, startOfDay } from 'date-fns';
import { useCreateRenewalReminder } from '@/hooks/queries';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import * as z from 'zod';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';

const reminderSchema = z.object({
  channel: z.enum(['whatsapp', 'email', 'sms']),
  reminder_date: z.string().min(1, 'Required'),
  notes: z.string().optional()
});

type ReminderFormValues = z.infer<typeof reminderSchema>;

export default function Renewals() {
  const { agency, session } = useAuth();
  const { toast } = useToast();
  const createReminder = useCreateRenewalReminder();
  
  const [reminderPolicyId, setReminderPolicyId] = useState<string | null>(null);
  
  const form = useForm<ReminderFormValues>({
    resolver: zodResolver(reminderSchema),
    defaultValues: {
      channel: 'email',
      reminder_date: new Date().toISOString().split('T')[0],
      notes: ''
    }
  });

  const onSubmitReminder = (values: ReminderFormValues) => {
    if (!reminderPolicyId) return;
    createReminder.mutate({
      policy_id: reminderPolicyId,
      ...values
    }, {
      onSuccess: () => {
        toast({ title: 'Reminder logged successfully' });
        setReminderPolicyId(null);
        form.reset();
      },
      onError: (err) => {
        toast({ title: 'Error logging reminder', description: err.message, variant: 'destructive' });
      }
    });
  };

  const { data: renewals, isLoading } = useQuery({
    queryKey: ['renewals', agency?.id],
    queryFn: async () => {
      const today = startOfDay(new Date()).toISOString();
      const in90Days = addDays(new Date(), 90).toISOString();
      
      const { data, error } = await supabase
        .from('policies')
        .select(`
          id, policy_number, expiry_date,
          client:clients(name, phone, email),
          insurer:insurers(name),
          product_line:product_lines(name),
          agent:users(full_name)
        `)
        .eq('agency_id', agency?.id)
        .eq('status', 'active')
        .gte('expiry_date', today)
        .lte('expiry_date', in90Days)
        .order('expiry_date', { ascending: true });
        
      if (error) throw error;
      
      const now = new Date().getTime();
      
      // Bucket them
      const buckets = {
        '30': [] as any[],
        '60': [] as any[],
        '90': [] as any[],
      };
      
      data.forEach(p => {
        const days = Math.ceil((new Date(p.expiry_date).getTime() - now) / (1000 * 3600 * 24));
        if (days <= 30) buckets['30'].push({ ...p, days });
        else if (days <= 60) buckets['60'].push({ ...p, days });
        else buckets['90'].push({ ...p, days });
      });
      
      return buckets;
    },
    enabled: !!session && !!agency?.id,
  });

  const renderTable = (policies: any[]) => {
    if (isLoading) return <div className="text-center py-8">Loading renewals...</div>;
    if (!policies || policies.length === 0) return <div className="text-center py-12 text-muted-foreground">No policies expiring in this window.</div>;
    
    return (
      <div className="border rounded-md bg-card overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Client</TableHead>
              <TableHead>Policy & Product</TableHead>
              <TableHead>Agent</TableHead>
              <TableHead className="text-right">Expiry Date</TableHead>
              <TableHead className="text-center">Action</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {policies.map(p => {
              const isUrgent = p.days <= 7;
              return (
                <TableRow key={p.id}>
                  <TableCell>
                    <div className="font-medium">{p.client?.name}</div>
                    <div className="text-xs text-muted-foreground">{p.client?.phone || p.client?.email || 'No contact info'}</div>
                  </TableCell>
                  <TableCell>
                    <div className="text-sm font-medium">{p.policy_number}</div>
                    <div className="text-xs text-muted-foreground">{p.product_line?.name} • {p.insurer?.name}</div>
                  </TableCell>
                  <TableCell className="text-sm">{p.agent?.full_name}</TableCell>
                  <TableCell className="text-right">
                    <div className={`font-medium ${isUrgent ? 'text-destructive' : ''}`}>
                      {formatDate(p.expiry_date)}
                    </div>
                    <Badge variant={isUrgent ? "destructive" : "secondary"} className="mt-1">
                      In {p.days} days
                    </Badge>
                  </TableCell>
                  <TableCell className="text-center">
                    <Button size="sm" variant="outline" className="gap-2" onClick={() => {
                      setReminderPolicyId(p.id);
                      form.reset({
                        channel: 'email',
                        reminder_date: new Date().toISOString().split('T')[0],
                        notes: ''
                      });
                    }}>
                      <BellRing className="w-3 h-3" /> Log Reminder
                    </Button>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    );
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Upcoming Renewals</h1>
        <p className="text-muted-foreground">Don't miss a renewal. Track expiring policies for the next 90 days.</p>
      </div>

      <Dialog open={!!reminderPolicyId} onOpenChange={(open) => !open && setReminderPolicyId(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Log Renewal Reminder</DialogTitle>
            <DialogDescription>Record that you've contacted the client about this renewal.</DialogDescription>
          </DialogHeader>
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmitReminder)} className="space-y-4">
              <FormField
                control={form.control}
                name="channel"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Channel</FormLabel>
                    <Select onValueChange={field.onChange} value={field.value}>
                      <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
                      <SelectContent>
                        <SelectItem value="email">Email</SelectItem>
                        <SelectItem value="whatsapp">WhatsApp</SelectItem>
                        <SelectItem value="sms">SMS</SelectItem>
                      </SelectContent>
                    </Select>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={form.control}
                name="reminder_date"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Date</FormLabel>
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
              <Button type="submit" className="w-full" disabled={createReminder.isPending}>
                {createReminder.isPending ? "Saving..." : "Save Reminder"}
              </Button>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      <Tabs defaultValue="30" className="space-y-4">
        <TabsList className="bg-card border h-11">
          <TabsTrigger value="30" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground gap-2">
            Next 30 Days
            <Badge variant="secondary" className="ml-1 opacity-80 h-5 px-1.5 min-w-[20px] rounded-full">
              {renewals?.['30']?.length || 0}
            </Badge>
          </TabsTrigger>
          <TabsTrigger value="60" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground gap-2">
            31-60 Days
            <Badge variant="secondary" className="ml-1 opacity-80 h-5 px-1.5 min-w-[20px] rounded-full">
              {renewals?.['60']?.length || 0}
            </Badge>
          </TabsTrigger>
          <TabsTrigger value="90" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground gap-2">
            61-90 Days
            <Badge variant="secondary" className="ml-1 opacity-80 h-5 px-1.5 min-w-[20px] rounded-full">
              {renewals?.['90']?.length || 0}
            </Badge>
          </TabsTrigger>
        </TabsList>
        
        <TabsContent value="30" className="space-y-4">
          {renderTable(renewals?.['30'] || [])}
        </TabsContent>
        <TabsContent value="60" className="space-y-4">
          {renderTable(renewals?.['60'] || [])}
        </TabsContent>
        <TabsContent value="90" className="space-y-4">
          {renderTable(renewals?.['90'] || [])}
        </TabsContent>
      </Tabs>
    </div>
  );
}
