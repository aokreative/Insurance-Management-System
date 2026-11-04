import { useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from '@/components/ui/command';
import type { DraftLine, MatchStatus } from '@/lib/reconcile';
import { formatKes } from '@/lib/receipt-grid';
import type { ReceivablePolicy } from '@/hooks/receipts';

export type MatchRow = {
  key: string; // grid row id
  line: DraftLine;
  policyId: string | null;
  status: MatchStatus;
  applyCents: number;
};

const BADGES: Record<MatchStatus, { label: string; variant: 'success' | 'warning' | 'secondary' | 'destructive' | 'default' | 'outline' }> = {
  matched: { label: 'Matched', variant: 'success' },
  short: { label: 'Short', variant: 'warning' },
  over: { label: 'Over', variant: 'warning' },
  unmatched: { label: 'Unmatched', variant: 'destructive' },
  new_commission: { label: 'New commission', variant: 'default' },
  reversal: { label: 'Reversal — not applied', variant: 'secondary' },
};

function PolicyPicker({ policies, onPick }: { policies: ReceivablePolicy[]; onPick: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" size="sm">Pick policy</Button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-0" align="start">
        <Command>
          <CommandInput placeholder="Search policy no. or client..." />
          <CommandList>
            <CommandEmpty>No policy found.</CommandEmpty>
            <CommandGroup>
              {policies.map((p) => (
                <CommandItem
                  key={p.id}
                  value={`${p.policy_number} ${p.clientName}`}
                  onSelect={() => {
                    onPick(p.id);
                    setOpen(false);
                  }}
                >
                  <div>
                    <div className="font-medium">{p.policy_number}</div>
                    <div className="text-xs text-muted-foreground">{p.clientName}</div>
                  </div>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}

export function MatchTable({
  rows,
  policies,
  overrides,
  onPick,
}: {
  rows: MatchRow[];
  policies: ReceivablePolicy[];
  overrides: Record<string, string>;
  onPick: (key: string, policyId: string | null) => void;
}) {
  const nameOf = (id: string | null) => policies.find((p) => p.id === id)?.policy_number ?? '';
  return (
    <div className="border rounded-md bg-card overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Policy no.</TableHead>
            <TableHead>Client</TableHead>
            <TableHead className="text-right">Commission</TableHead>
            <TableHead>Match</TableHead>
            <TableHead className="text-right">To apply</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((r) => {
            const badge = BADGES[r.status];
            const overridden = overrides[r.key] !== undefined;
            return (
              <TableRow key={r.key}>
                <TableCell className="font-medium">
                  {r.line.policyNumber || '—'}
                  {overridden && (
                    <div className="text-xs text-muted-foreground">Linked to {nameOf(r.policyId)}</div>
                  )}
                </TableCell>
                <TableCell>{r.line.clientName || '—'}</TableCell>
                <TableCell className="text-right">
                  {r.line.commissionCents === null ? '—' : formatKes(r.line.commissionCents)}
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-2 flex-wrap">
                    <Badge variant={badge.variant}>{badge.label}</Badge>
                    {r.status === 'unmatched' && <PolicyPicker policies={policies} onPick={(id) => onPick(r.key, id)} />}
                    {overridden && (
                      <Button type="button" variant="ghost" size="sm" onClick={() => onPick(r.key, null)}>
                        Clear
                      </Button>
                    )}
                  </div>
                </TableCell>
                <TableCell className="text-right">{formatKes(r.applyCents)}</TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}
