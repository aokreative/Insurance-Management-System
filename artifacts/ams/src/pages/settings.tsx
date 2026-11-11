import React, { useState } from 'react';
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { formatDate } from '@/lib/utils';
import { InviteMemberDialog } from '@/components/team/InviteMemberDialog';
import { RemoveMemberDialog } from '@/components/team/RemoveMemberDialog';
import { AgentRatesDialog } from '@/components/team/AgentRatesDialog';
import { Switch } from '@/components/ui/switch';
import { useSetAgentsManageRenewals } from '@/hooks/renewals';
import { usePendingInvites, useRevokeInvite, useChangeMemberRole, useClientCountsByAgent } from '@/hooks/team';
import { useForm } from 'react-hook-form';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';

export default function Settings() {
  const { agency, profile, session, isOwner, isOwnerOrManager } = useAuth();
  const updateAgency = useUpdateAgency();
  const { data: users, isLoading: usersLoading } = useAgencyUsers();
  const { toast } = useToast();
  const setAgentsManage = useSetAgentsManageRenewals();
  const { data: invites } = usePendingInvites();
  const { data: clientCounts } = useClientCountsByAgent();
  const revokeInvite = useRevokeInvite();
  const changeRole = useChangeMemberRole();
  const [inviteOpen, setInviteOpen] = useState(false);
  const [removing, setRemoving] = useState<{ id: string; full_name: string } | null>(null);
  const [ratesFor, setRatesFor] = useState<{ id: string; full_name: string } | null>(null);
  const activeUsers = users?.filter(u => !u.deactivated_at) ?? [];
  const removedUsers = users?.filter(u => u.deactivated_at) ?? [];

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

  return (
    <div className="space-y-8 max-w-5xl">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Agency Settings</h1>
        <p className="text-muted-foreground">Manage your workspace configuration and team.</p>
      </div>

      <Tabs defaultValue="profile" className="space-y-6">
        <TabsList>
          <TabsTrigger value="profile">Profile</TabsTrigger>
          <TabsTrigger value="agency">Agency</TabsTrigger>
          {isOwnerOrManager && <TabsTrigger value="team">Team</TabsTrigger>}
        </TabsList>

        <TabsContent value="profile" className="space-y-4 max-w-md">
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
        </TabsContent>

        <TabsContent value="agency">
          <Card>
            <CardHeader>
              <CardTitle>Agency Profile</CardTitle>
              <CardDescription>{isOwner ? "Update your agency's contact information and branding." : 'Only the owner can edit agency details.'}</CardDescription>
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
                        <FormControl><Input {...field} disabled={!isOwner} /></FormControl>
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
                          <FormControl><Input type="email" {...field} disabled={!isOwner} /></FormControl>
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
                          <FormControl><Input {...field} disabled={!isOwner} /></FormControl>
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
                        <FormControl><Input {...field} disabled={!isOwner} /></FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  {isOwner && (
                    <Button type="submit" disabled={updateAgency.isPending}>
                      {updateAgency.isPending ? "Saving..." : "Save Changes"}
                    </Button>
                  )}
                </form>
              </Form>
            </CardContent>
          </Card>
          <Card className="mt-6">
            <CardHeader>
              <CardTitle>Renewals</CardTitle>
              <CardDescription>
                Owners and managers can always update any renewal.{' '}
                {isOwner ? 'Only you can change this setting.' : 'Only the owner can change this setting.'}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="flex items-center justify-between gap-4">
                <Label htmlFor="agents-manage-renewals" className="font-normal">
                  Agents can update their own renewals
                  <span className="block text-xs text-muted-foreground">
                    Log contacts, record quotes, renew and mark lost on policies assigned to them.
                  </span>
                </Label>
                <Switch
                  id="agents-manage-renewals"
                  checked={agency?.agents_manage_renewals ?? true}
                  disabled={!isOwner || setAgentsManage.isPending}
                  onCheckedChange={(checked) =>
                    setAgentsManage.mutate(checked, {
                      onSuccess: () =>
                        toast({ title: checked ? 'Agents can now update their renewals' : 'Renewal updates by agents turned off' }),
                      onError: (err) => toast({ title: 'Could not save', description: err.message, variant: 'destructive' }),
                    })
                  }
                />
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        {isOwnerOrManager && (
          <TabsContent value="team" className="space-y-8">
            <Card>
              <CardHeader className="flex flex-row items-center justify-between">
                <div>
                  <CardTitle className="flex items-center gap-2">
                    <Users className="w-5 h-5" /> Team Members
                  </CardTitle>
                  <CardDescription>Manage who has access to your workspace.</CardDescription>
                </div>
                <Button variant="outline" size="sm" onClick={() => setInviteOpen(true)}>
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
                        <TableHead className="text-right">Clients</TableHead>
                        <TableHead className="text-right">Actions</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {usersLoading ? (
                        <TableRow><TableCell colSpan={5} className="text-center py-4">Loading...</TableCell></TableRow>
                      ) : (
                        activeUsers.map(user => (
                          <TableRow key={user.id}>
                            <TableCell className="font-medium">{user.full_name}</TableCell>
                            <TableCell>{user.email}</TableCell>
                            <TableCell>
                              <Badge variant={user.role === 'owner' ? 'default' : 'secondary'} className="capitalize">
                                {user.role}
                              </Badge>
                            </TableCell>
                            <TableCell className="text-right">{clientCounts?.[user.id] ?? 0}</TableCell>
                            <TableCell className="text-right">
                              <div className="flex items-center justify-end gap-2">
                                <Button variant="outline" size="sm" onClick={() => setRatesFor({ id: user.id, full_name: user.full_name })}>
                                  Rates
                                </Button>
                                {isOwner && user.role !== 'owner' && (
                                  <>
                                    <Select
                                      value={user.role}
                                      onValueChange={(role) => changeRole.mutate(
                                        { userId: user.id, role: role as 'manager' | 'agent' },
                                        {
                                          onSuccess: () => toast({ title: 'Role updated' }),
                                          onError: (err: any) => toast({ title: 'Could not change role', description: err.message, variant: 'destructive' }),
                                        },
                                      )}
                                    >
                                      <SelectTrigger className="w-28 h-8"><SelectValue /></SelectTrigger>
                                      <SelectContent>
                                        <SelectItem value="manager">Manager</SelectItem>
                                        <SelectItem value="agent">Agent</SelectItem>
                                      </SelectContent>
                                    </Select>
                                    <Button variant="outline" size="sm" onClick={() => setRemoving({ id: user.id, full_name: user.full_name })}>
                                      Remove
                                    </Button>
                                  </>
                                )}
                              </div>
                            </TableCell>
                          </TableRow>
                        ))
                      )}
                    </TableBody>
                  </Table>
                </div>
                {removedUsers.length > 0 && (
                  <div className="mt-6">
                    <div className="text-sm font-medium text-muted-foreground mb-2">Removed</div>
                    <ul className="text-sm text-muted-foreground space-y-1">
                      {removedUsers.map(u => (
                        <li key={u.id}>{u.full_name}{u.email ? ` (${u.email})` : ''}</li>
                      ))}
                    </ul>
                  </div>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Pending Invites</CardTitle>
                <CardDescription>Invites that have not been accepted yet.</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="border rounded-md">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Email</TableHead>
                        <TableHead>Role</TableHead>
                        <TableHead>Expires</TableHead>
                        <TableHead className="text-right"></TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {!invites || invites.length === 0 ? (
                        <TableRow><TableCell colSpan={4} className="text-center py-4 text-muted-foreground">No pending invites</TableCell></TableRow>
                      ) : (
                        invites.map(invite => {
                          const canRevoke = isOwner || (invite.role === 'agent' && invite.invited_by === session?.id);
                          return (
                            <TableRow key={invite.id}>
                              <TableCell className="font-medium">{invite.email}</TableCell>
                              <TableCell><Badge variant="secondary" className="capitalize">{invite.role}</Badge></TableCell>
                              <TableCell>{formatDate(invite.expires_at)}</TableCell>
                              <TableCell className="text-right">
                                {canRevoke && (
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    disabled={revokeInvite.isPending}
                                    onClick={() => revokeInvite.mutate(invite.id, {
                                      onSuccess: () => toast({ title: 'Invite revoked' }),
                                      onError: (err: any) => toast({ title: 'Could not revoke invite', description: err.message, variant: 'destructive' }),
                                    })}
                                  >
                                    Revoke
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
              </CardContent>
            </Card>

            <InviteMemberDialog open={inviteOpen} onOpenChange={setInviteOpen} />
            <AgentRatesDialog member={ratesFor} canEdit={isOwner} onOpenChange={(o) => { if (!o) setRatesFor(null); }} />
            <RemoveMemberDialog member={removing} onOpenChange={(o) => { if (!o) setRemoving(null); }} />
          </TabsContent>
        )}
      </Tabs>
    </div>
  );
}
