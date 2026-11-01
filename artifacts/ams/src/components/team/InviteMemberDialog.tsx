import React, { useState } from 'react';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useCreateInvite, inviteLink, type InviteResult } from '@/hooks/team';
import { Copy, MessageCircle } from 'lucide-react';

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function InviteMemberDialog({ open, onOpenChange }: Props) {
  const { agency, isOwner } = useAuth();
  const { toast } = useToast();
  const createInvite = useCreateInvite();
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<'manager' | 'agent'>('agent');
  const [result, setResult] = useState<InviteResult | null>(null);

  const handleOpenChange = (next: boolean) => {
    if (!next) {
      // The link is shown once; closing discards it.
      setResult(null);
      setEmail('');
      setRole('agent');
    }
    onOpenChange(next);
  };

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    createInvite.mutate(
      { email: email.trim(), role: isOwner ? role : 'agent' },
      {
        onSuccess: (data) => setResult(data),
        onError: (err: any) => toast({ title: 'Could not create invite', description: err.message, variant: 'destructive' }),
      },
    );
  };

  const link = result ? inviteLink(result.code) : '';

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(link);
      toast({ title: 'Link copied' });
    } catch {
      toast({ title: 'Could not copy', description: 'Select the link and copy it manually.', variant: 'destructive' });
    }
  };

  const message = "You've been invited to join " + (agency?.name ?? 'our agency') + ' on AMS: ' + link;
  const whatsappUrl = 'https://wa.me/?text=' + encodeURIComponent(message);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent>
        {result ? (
          <>
            <DialogHeader>
              <DialogTitle>Invite created</DialogTitle>
              <DialogDescription>Send this link to {email.trim()}.</DialogDescription>
            </DialogHeader>
            <div className="space-y-3">
              <Input readOnly value={link} onFocus={(e) => e.target.select()} />
              <div className="flex flex-wrap gap-2">
                <Button type="button" variant="outline" onClick={copy}>
                  <Copy className="w-4 h-4 mr-2" /> Copy link
                </Button>
                <Button type="button" variant="outline" asChild>
                  <a href={whatsappUrl} target="_blank" rel="noopener noreferrer">
                    <MessageCircle className="w-4 h-4 mr-2" /> Share on WhatsApp
                  </a>
                </Button>
              </div>
              <p className="text-sm text-muted-foreground">This link is shown only once and expires in 7 days.</p>
            </div>
            <DialogFooter>
              <Button onClick={() => handleOpenChange(false)}>Done</Button>
            </DialogFooter>
          </>
        ) : (
          <form onSubmit={submit} className="space-y-4">
            <DialogHeader>
              <DialogTitle>Invite member</DialogTitle>
              <DialogDescription>They will join your agency with the role you pick.</DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              <Label htmlFor="invite-email">Email</Label>
              <Input id="invite-email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Role</Label>
              <Select value={isOwner ? role : 'agent'} onValueChange={(v) => setRole(v as 'manager' | 'agent')} disabled={!isOwner}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {isOwner && <SelectItem value="manager">Manager</SelectItem>}
                  <SelectItem value="agent">Agent</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => handleOpenChange(false)}>Cancel</Button>
              <Button type="submit" disabled={createInvite.isPending || !email.trim()}>
                {createInvite.isPending ? 'Creating...' : 'Create invite'}
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
