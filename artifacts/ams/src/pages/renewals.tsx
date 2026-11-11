import { useMemo, useState } from 'react';
import { endOfMonth, format, startOfMonth } from 'date-fns';
import { AlertTriangle, CalendarClock, Download, MoreHorizontal, Percent, Wallet } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { StatCard } from '@/components/StatCard';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { RenewalActionDialogs, type RenewalAction } from '@/components/renewals/RenewalDialogs';
import { RenewalDrawer } from '@/components/renewals/RenewalDrawer';
import { useAgencyUsers } from '@/hooks/queries';
import { useClosedRenewals, useOpenRenewals, useReopenRenewal, type RenewalWindow } from '@/hooks/renewals';
import { useToast } from '@/hooks/use-toast';
import { exportToCsv } from '@/lib/csv-export';
import { fromCents, toCents } from '@/lib/reconcile';
import {
  LOST_REASONS,
  RENEWAL_STAGES,
  canUpdateRenewals,
  lostReasonLabel,
  renewalRate,
  stageLabel,
} from '@/lib/renewals';
import { formatCurrency, formatDate } from '@/lib/utils';
import type { RenewalRow, RenewalStage } from '@/lib/types';

const WINDOWS: { value: RenewalWindow; label: string }[] = [
  { value: 'all', label: 'All open' },
  { value: 'overdue', label: 'Overdue' },
  { value: '30', label: 'Next 30 days' },
  { value: '60', label: 'Next 60 days' },
  { value: '90', label: 'Next 90 days' },
];

function inWindow(r: RenewalRow, w: RenewalWindow): boolean {
  if (w === 'all') return true;
  if (w === 'overdue') return r.days_to_expiry < 0;
  return r.days_to_expiry >= 0 && r.days_to_expiry <= Number(w);
}

function ExpiryBadge({ days }: { days: number }) {
  if (days < 0) {
    return (
      <span className="mt-1 flex items-center justify-end gap-1 text-xs font-semibold text-destructive">
        <AlertTriangle className="h-3 w-3" />
        {-days} {days === -1 ? 'day' : 'days'} overdue
      </span>
    );
  }
  return (
    <Badge variant={days <= 7 ? 'destructive' : 'secondary'} className="mt-1">
      {days === 0 ? 'Today' : `In ${days} ${days === 1 ? 'day' : 'days'}`}
    </Badge>
  );
}

export default function Renewals() {
  const { agency, profile, isOwnerOrManager } = useAuth();
  const { toast } = useToast();
  const isAgent = !!profile && !isOwnerOrManager;
  const agentsManage = agency?.agents_manage_renewals ?? true;

  const [stage, setStage] = useState<RenewalStage>('to_contact');
  const [expiryWindow, setExpiryWindow] = useState<RenewalWindow>('all');
  const [agentId, setAgentId] = useState<string>('all');
  const [month, setMonth] = useState(format(new Date(), 'yyyy-MM'));
  const [action, setAction] = useState<RenewalAction | null>(null);
  const [actionRow, setActionRow] = useState<RenewalRow | null>(null);
  const [drawerRow, setDrawerRow] = useState<RenewalRow | null>(null);

  const monthStart = month ? startOfMonth(new Date(`${month}-01T00:00:00`)) : startOfMonth(new Date());
  const from = format(monthStart, 'yyyy-MM-dd');
  const to = format(endOfMonth(monthStart), 'yyyy-MM-dd');
  const agentFilter = isOwnerOrManager && agentId !== 'all' ? agentId : undefined;

  const { data: users } = useAgencyUsers();
  const { data: open, isLoading: openLoading } = useOpenRenewals(agentFilter);
  const { data: closed, isLoading: closedLoading } = useClosedRenewals(from, to, agentFilter);
  const reopen = useReopenRenewal();

  const openInWindow = useMemo(() => (open ?? []).filter((r) => inWindow(r, expiryWindow)), [open, expiryWindow]);

  const counts = useMemo(() => {
    const c: Record<RenewalStage, number> = { to_contact: 0, contacted: 0, quoted: 0, renewed: 0, lost: 0 };
    for (const r of openInWindow) c[r.stage]++;
    for (const r of closed ?? []) c[r.stage]++;
    return c;
  }, [openInWindow, closed]);

  const rows = useMemo(() => {
    if (stage === 'renewed' || stage === 'lost') return (closed ?? []).filter((r) => r.stage === stage);
    return openInWindow.filter((r) => r.stage === stage);
  }, [stage, openInWindow, closed]);

  const due30 = (open ?? []).filter((r) => r.days_to_expiry >= 0 && r.days_to_expiry <= 30).length;
  const overdue = (open ?? []).filter((r) => r.days_to_expiry < 0).length;
  const rate = renewalRate(counts.renewed, counts.lost);
  const premiumRenewedCents = (closed ?? [])
    .filter((r) => r.stage === 'renewed')
    .reduce((s, r) => s + (toCents(r.renewed_premium ?? 0) ?? 0), 0);

  const lostByReason = useMemo(() => {
    const m = new Map<string, number>();
    for (const r of closed ?? []) if (r.stage === 'lost' && r.lost_reason) m.set(r.lost_reason, (m.get(r.lost_reason) ?? 0) + 1);
    return LOST_REASONS.filter((r) => m.has(r)).map((r) => ({ reason: r, count: m.get(r)! }));
  }, [closed]);

  const canUpdate = (r: RenewalRow) => canUpdateRenewals(profile?.role, agentsManage, r.agent_id === profile?.id);
  const isClosedTab = stage === 'renewed' || stage === 'lost';

  const startAction = (a: RenewalAction, r: RenewalRow) => {
    setActionRow(r);
    setAction(a);
  };

  const doReopen = (r: RenewalRow) => {
    reopen.mutate(r.policy_id, {
      onSuccess: () => toast({ title: 'Renewal reopened' }),
      onError: (err) => toast({ title: 'Could not reopen', description: err.message, variant: 'destructive' }),
    });
  };

  const handleExportCsv = () => {
    const all = [...(open ?? []), ...(closed ?? [])];
    if (all.length === 0) return;
    exportToCsv(
      'renewals',
      all.map((r) => ({
        client_name: r.client_name ?? '',
        policy_number: r.policy_number,
        product_line: r.product_line_name ?? '',
        insurer: r.insurer_name ?? '',
        agent: r.agent_name ?? '',
        expiry_date: r.expiry_date,
        days_until_expiry: r.days_to_expiry,
        stage: stageLabel(r.stage),
        quoted_premium: r.quoted_premium ?? '',
        lost_reason: r.lost_reason ? lostReasonLabel(r.lost_reason) : '',
        closed_date: r.closed_at ? format(new Date(r.closed_at), 'yyyy-MM-dd') : '',
      })),
    );
  };

  const loading = isClosedTab ? closedLoading : openLoading;

  return (
    <div className="space-y-6">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-center">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{isAgent ? 'My Renewals' : 'Renewals'}</h1>
          <p className="text-muted-foreground">Follow every expiring policy through to renewed or lost.</p>
        </div>
        <Button variant="secondary" onClick={handleExportCsv}>
          <Download className="mr-2 h-4 w-4" /> Export CSV
        </Button>
      </div>

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard title="Due in 30 days" value={due30} icon={CalendarClock} loading={openLoading} />
        <StatCard title="Overdue" value={overdue} icon={AlertTriangle} loading={openLoading} />
        <StatCard
          title="Renewal rate"
          value={rate === null ? '—' : `${rate}%`}
          subtitle={format(monthStart, 'MMMM yyyy')}
          icon={Percent}
          loading={closedLoading}
        />
        <StatCard
          title="Premium renewed"
          value={formatCurrency(fromCents(premiumRenewedCents))}
          subtitle={format(monthStart, 'MMMM yyyy')}
          icon={Wallet}
          loading={closedLoading}
        />
      </div>

      {isAgent && !agentsManage && (
        <p className="rounded-md border bg-muted/40 p-3 text-sm text-muted-foreground">
          Your agency has turned off renewal updates by agents. You can see your renewals; the office records the
          follow-up.
        </p>
      )}

      <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end">
        {!isClosedTab ? (
          <div className="space-y-1">
            <span className="text-xs text-muted-foreground">Expiry</span>
            <Select value={expiryWindow} onValueChange={(v) => setExpiryWindow(v as RenewalWindow)}>
              <SelectTrigger className="w-full sm:w-44"><SelectValue /></SelectTrigger>
              <SelectContent>
                {WINDOWS.map((w) => (
                  <SelectItem key={w.value} value={w.value}>{w.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        ) : null}
        <div className="space-y-1">
          <span className="text-xs text-muted-foreground">Closed in</span>
          <Input
            type="month"
            className="w-full sm:w-44"
            value={month}
            onChange={(e) => setMonth(e.target.value)}
          />
        </div>
        {isOwnerOrManager && (
          <div className="space-y-1">
            <span className="text-xs text-muted-foreground">Agent</span>
            <Select value={agentId} onValueChange={setAgentId}>
              <SelectTrigger className="w-full sm:w-52"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All agents</SelectItem>
                {(users ?? []).map((u) => (
                  <SelectItem key={u.id} value={u.id}>
                    {u.full_name}
                    {u.deactivated_at ? ' (removed)' : ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
      </div>

      <Tabs value={stage} onValueChange={(v) => setStage(v as RenewalStage)}>
        <div className="overflow-x-auto">
          <TabsList className="h-11 border bg-card">
            {RENEWAL_STAGES.map((s) => (
              <TabsTrigger
                key={s}
                value={s}
                className="gap-2 data-[state=active]:bg-primary data-[state=active]:text-primary-foreground"
              >
                {stageLabel(s)}
                <Badge variant="secondary" className="ml-1 h-5 min-w-[20px] rounded-full px-1.5 opacity-80">
                  {counts[s]}
                </Badge>
              </TabsTrigger>
            ))}
          </TabsList>
        </div>
      </Tabs>

      {stage === 'lost' && lostByReason.length > 0 && (
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-base">Why renewals were lost · {format(monthStart, 'MMMM yyyy')}</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {lostByReason.map(({ reason, count }) => (
              <Badge key={reason} variant="outline" className="text-sm">
                {lostReasonLabel(reason)}: {count}
              </Badge>
            ))}
          </CardContent>
        </Card>
      )}

      <div className="overflow-x-auto rounded-md border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Client</TableHead>
              <TableHead>Policy &amp; product</TableHead>
              <TableHead>Agent</TableHead>
              <TableHead className="text-right">Expiry</TableHead>
              <TableHead>{isClosedTab ? 'Closed' : 'Last activity'}</TableHead>
              <TableHead className="text-right">{stage === 'lost' ? 'Reason' : 'Quote'}</TableHead>
              <TableHead className="w-12" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {loading ? (
              <TableRow>
                <TableCell colSpan={7} className="py-8 text-center">Loading renewals…</TableCell>
              </TableRow>
            ) : rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} className="py-12 text-center text-muted-foreground">
                  {isClosedTab ? `Nothing ${stageLabel(stage).toLowerCase()} in this month.` : 'No renewals here.'}
                </TableCell>
              </TableRow>
            ) : (
              rows.map((r) => {
                const editable = canUpdate(r);
                const showMenu = isClosedTab ? isOwnerOrManager && r.stage === 'lost' : editable;
                return (
                  <TableRow key={r.policy_id} className="cursor-pointer" onClick={() => setDrawerRow(r)}>
                    <TableCell>
                      <div className="font-medium">{r.client_name ?? '—'}</div>
                      <div className="text-xs text-muted-foreground">
                        {r.client_phone || r.client_email || 'No contact info'}
                      </div>
                    </TableCell>
                    <TableCell>
                      <div className="text-sm font-medium">{r.policy_number}</div>
                      <div className="text-xs text-muted-foreground">
                        {r.product_line_name} · {r.insurer_name}
                      </div>
                    </TableCell>
                    <TableCell className="text-sm">{r.agent_name ?? '—'}</TableCell>
                    <TableCell className="text-right">
                      <div className="font-medium">{formatDate(r.expiry_date)}</div>
                      {!isClosedTab && <ExpiryBadge days={r.days_to_expiry} />}
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {isClosedTab ? formatDate(r.closed_at) : r.last_activity_at ? formatDate(r.last_activity_at) : 'None'}
                    </TableCell>
                    <TableCell className="text-right text-sm">
                      {stage === 'lost'
                        ? r.lost_reason
                          ? lostReasonLabel(r.lost_reason)
                          : '—'
                        : r.quoted_premium != null
                          ? formatCurrency(r.quoted_premium)
                          : '—'}
                    </TableCell>
                    <TableCell onClick={(e) => e.stopPropagation()}>
                      {showMenu && (
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <Button variant="ghost" size="icon" aria-label="Update renewal">
                              <MoreHorizontal className="h-4 w-4" />
                            </Button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end">
                            {isClosedTab ? (
                              <DropdownMenuItem onClick={() => doReopen(r)} disabled={reopen.isPending}>
                                Reopen
                              </DropdownMenuItem>
                            ) : (
                              <>
                                <DropdownMenuItem onClick={() => startAction('contact', r)}>Log contact</DropdownMenuItem>
                                <DropdownMenuItem onClick={() => startAction('quote', r)}>Record quote</DropdownMenuItem>
                                <DropdownMenuItem onClick={() => startAction('renew', r)}>Renew…</DropdownMenuItem>
                                <DropdownMenuSeparator />
                                <DropdownMenuItem className="text-destructive" onClick={() => startAction('lost', r)}>
                                  Mark lost
                                </DropdownMenuItem>
                              </>
                            )}
                          </DropdownMenuContent>
                        </DropdownMenu>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })
            )}
          </TableBody>
        </Table>
      </div>

      <RenewalActionDialogs
        action={action}
        row={actionRow}
        onClose={() => {
          setAction(null);
          setActionRow(null);
        }}
      />
      <RenewalDrawer row={drawerRow} onClose={() => setDrawerRow(null)} />
    </div>
  );
}
