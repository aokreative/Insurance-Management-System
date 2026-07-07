import React from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useUpdateAgency, useAgencyUsers } from '@/hooks/queries';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { useToast } from '@/hooks/use-toast';
import { ShieldCheck, Users, Building } from 'lucide-react';
import { useForm } from 'react-hook-form';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';

export default function Settings() {
  const { agency, profile } = useAuth();
  const updateAgency = useUpdateAgency();
  const { data: users, isLoading: usersLoading } = useAgencyUsers();
  const { toast } = useToast();

  const form = useForm({
    defaultValues: {
      name: agency?.name || '',
      email: agency?.email || '',
      phone: agency?.phone || '',
      address: agency?.address || '',
    }
  });

  const onSaveProfile = (values: any) => {
    if (!agency?.id) return;
    updateAgency.mutate({ id: agency.id, ...values }, {
      onSuccess: () => {
        toast({ title: 'Agency settings updated' });
      }
    });
  };

  const isOwnerOrAdmin = profile?.role === 'owner' || profile?.role === 'admin';

  return (
    <div className="space-y-8 max-w-5xl">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Agency Settings</h1>
        <p className="text-muted-foreground">Manage your workspace configuration and team.</p>
      </div>

      <div className="grid gap-8 grid-cols-1 md:grid-cols-3">
        <div className="md:col-span-1 space-y-4">
          <Card className="bg-primary/5 border-primary/20">
            <CardHeader className="pb-2">
              <CardTitle className="text-base flex items-center gap-2">
                <Building className="w-4 h-4 text-primary" />
                Current Workspace
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{agency?.name}</div>
              <Badge variant="outline" className="mt-2 capitalize bg-background">{agency?.subscription_tier} Plan</Badge>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-base flex items-center gap-2">
                <ShieldCheck className="w-4 h-4" />
                Your Profile
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="font-medium">{profile?.full_name}</div>
              <div className="text-sm text-muted-foreground">{profile?.email}</div>
              <Badge variant="secondary" className="mt-2 capitalize">{profile?.role}</Badge>
            </CardContent>
          </Card>
        </div>

        <div className="md:col-span-2 space-y-8">
          <Card>
            <CardHeader>
              <CardTitle>Agency Profile</CardTitle>
              <CardDescription>Update your agency's contact information and branding.</CardDescription>
            </CardHeader>
            <CardContent>
              <Form {...form}>
                <form onSubmit={form.handleSubmit(onSaveProfile)} className="space-y-4">
                  <FormField
                    control={form.control}
                    name="name"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>Agency Name</FormLabel>
                        <FormControl><Input {...field} disabled={!isOwnerOrAdmin} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <div className="grid grid-cols-2 gap-4">
                    <FormField
                      control={form.control}
                      name="email"
                      render={({ field }) => (
                        <FormItem>
                          <FormLabel>General Email</FormLabel>
                          <FormControl><Input type="email" {...field} disabled={!isOwnerOrAdmin} /></FormControl>
                          <FormMessage />
                        </FormItem>
                      )}
                    />
                    <FormField
                      control={form.control}
                      name="phone"
                      render={({ field }) => (
                        <FormItem>
                          <FormLabel>Phone Number</FormLabel>
                          <FormControl><Input {...field} disabled={!isOwnerOrAdmin} /></FormControl>
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
                        <FormControl><Input {...field} disabled={!isOwnerOrAdmin} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  {isOwnerOrAdmin && (
                    <Button type="submit" disabled={updateAgency.isPending}>
                      {updateAgency.isPending ? "Saving..." : "Save Changes"}
                    </Button>
                  )}
                </form>
              </Form>
            </CardContent>
          </Card>

          {isOwnerOrAdmin && (
            <Card>
              <CardHeader className="flex flex-row items-center justify-between">
                <div>
                  <CardTitle className="flex items-center gap-2">
                    <Users className="w-5 h-5" /> Team Members
                  </CardTitle>
                  <CardDescription>Manage who has access to your workspace.</CardDescription>
                </div>
                <Button variant="outline" size="sm" onClick={() => toast({ title: 'Invites coming soon', description: 'Phase 6 feature' })}>
                  Invite Member
                </Button>
              </CardHeader>
              <CardContent>
                <div className="border rounded-md">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Name</TableHead>
                        <TableHead>Email</TableHead>
                        <TableHead>Role</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {usersLoading ? (
                        <TableRow><TableCell colSpan={3} className="text-center py-4">Loading...</TableCell></TableRow>
                      ) : (
                        users?.map(user => (
                          <TableRow key={user.id}>
                            <TableCell className="font-medium">{user.full_name}</TableCell>
                            <TableCell>{user.email}</TableCell>
                            <TableCell>
                              <Badge variant={user.role === 'owner' ? 'default' : 'secondary'} className="capitalize">
                                {user.role}
                              </Badge>
                            </TableCell>
                          </TableRow>
                        ))
                      )}
                    </TableBody>
                  </Table>
                </div>
              </CardContent>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}
