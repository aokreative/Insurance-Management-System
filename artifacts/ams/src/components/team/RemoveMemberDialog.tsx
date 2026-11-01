import React, { useEffect, useState } from 'react';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { useAgencyMembers, useRemoveMember } from '@/hooks/team';

interface Props {
  member: { id: string; full_name: string } | null;
  onOpenChange: (open: boolean) => void;
}

export function RemoveMemberDialog({ member, onOpenChange }: Props) {
  const { toast } = useToast();
  const { data: members } = useAgencyMembers();
  const removeMember = useRemoveMember();
  const [reassignTo, setReassignTo] = useState('');

  useEffect(() => {
    setReassignTo('');
  }, [member?.id]);

  const options = (members ?? []).filter((m) => m.id !== member?.id);

  const confirm = () => {
    if (!member || !reassignTo) return;
    removeMember.mutate(
      { userId: member.id, reassignTo },
      {
        onSuccess: (res) => {
          toast({ title: `Removed — ${res.clients_moved} clients and ${res.policies_moved} policies reassigned` });
          onOpenChange(false);
        },
        onError: (err: any) => toast({ title: 'Could not remove member', description: err.message, variant: 'destructive' }),
      },
    );
  };

  return (
    <Dialog open={!!member} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Remove {member?.full_name}</DialogTitle>
          <DialogDescription>
            They will lose access immediately. Their clients and policies move to the member you pick.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Label>Reassign their clients to</Label>
          <Select value={reassignTo} onValueChange={setReassignTo}>
            <SelectTrigger><SelectValue placeholder="Select a member" /></SelectTrigger>
            <SelectContent>
              {options.map((m) => (
                <SelectItem key={m.id} value={m.id}>{m.full_name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button variant="destructive" onClick={confirm} disabled={!reassignTo || removeMember.isPending}>
            {removeMember.isPending ? 'Removing...' : 'Remove member'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
