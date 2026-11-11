import { Link, useRoute } from 'wouter';
import { usePayout } from '@/hooks/payouts';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { earningLabel, formatDay, kes, methodLabel } from '@/lib/payouts';
import { ArrowLeft, Printer } from 'lucide-react';

export default function PayoutDetail() {
  const [, params] = useRoute('/payouts/:id');
  const { data, isLoading, error } = usePayout(params?.id);

  if (isLoading) return <div className="text-muted-foreground">Loading...</div>;
  if (error) return <div className="text-destructive">{(error as Error).message}</div>;
  if (!data) return <div className="text-muted-foreground">Payout not found</div>;

  const { payout: p, earnings } = data;
  const voided = !!p.voided_at;

  return (
    <div className="space-y-6 max-w-4xl">
      <div className="flex items-center justify-between gap-4 print:hidden">
        <Button variant="ghost" asChild>
          <Link href="/payouts"><ArrowLeft className="w-4 h-4 mr-2" /> Back</Link>
        </Button>
        <Button variant="outline" onClick={() => window.print()}>
          <Printer className="w-4 h-4 mr-2" /> Print / Save as PDF
        </Button>
      </div>

      {voided && (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 text-destructive px-4 py-3 font-semibold">
          Voided on {formatDay(p.voided_at)}. This payout no longer counts: its earnings are unpaid again.
        </div>
      )}

      <div>
        <h1 className="text-3xl font-bold tracking-tight">Commission payout statement</h1>
        <p className="text-muted-foreground">{p.agent?.full_name ?? 'Agent'}</p>
      </div>

      <dl className="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
        <div><dt className="text-muted-foreground">Paid on</dt><dd className="font-medium">{formatDay(p.paid_on)}</dd></div>
        <div><dt className="text-muted-foreground">Earnings up to</dt><dd className="font-medium">{formatDay(p.period_end)}</dd></div>
        <div><dt className="text-muted-foreground">Method</dt><dd className="font-medium">{methodLabel(p.method)}</dd></div>
        <div><dt className="text-muted-foreground">Reference</dt><dd className="font-medium">{p.reference ?? '-'}</dd></div>
      </dl>

      <div className="border rounded-md overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Earned on</TableHead>
              <TableHead>Policy</TableHead>
              <TableHead>Client</TableHead>
              <TableHead className="text-right">Base</TableHead>
              <TableHead className="text-right">Rate</TableHead>
              <TableHead className="text-right">Earned</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {earnings.length === 0 ? (
              <TableRow>
                <TableCell colSpan={6} className="text-center py-6 text-muted-foreground">
                  {voided ? 'Lines are no longer attached to this voided payout.' : 'No lines.'}
                </TableCell>
              </TableRow>
            ) : earnings.map((e) => (
              <TableRow key={e.id}>
                <TableCell>{formatDay(e.earned_on)}</TableCell>
                {e.kind === 'adjustment' ? (
                  <TableCell colSpan={4}>{earningLabel(e)}</TableCell>
                ) : (
                  <>
                    <TableCell>
                      {e.policy_number ?? '-'}
                      {e.kind === 'reversal' && <Badge variant="secondary" className="ml-2">Reversal</Badge>}
                    </TableCell>
                    <TableCell>{e.client_name ?? '-'}</TableCell>
                    <TableCell className="text-right">{kes(e.base_amount)}</TableCell>
                    <TableCell className="text-right">{e.rate != null ? `${Number(e.rate)}%` : '-'}</TableCell>
                  </>
                )}
                <TableCell className="text-right font-medium">{kes(e.amount)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <div className="flex justify-end text-xl font-bold">Total paid: {kes(p.amount)}</div>
    </div>
  );
}
