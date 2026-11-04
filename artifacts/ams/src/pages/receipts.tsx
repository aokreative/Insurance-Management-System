import { useState } from 'react';
import { Link, useLocation } from 'wouter';
import { useAuth } from '@/contexts/AuthContext';
import { useInsurers } from '@/hooks/queries';
import { useReceipts, useInsurerMoneySummary } from '@/hooks/receipts';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency, formatDate } from '@/lib/utils';
import { Plus } from 'lucide-react';

export default function Receipts() {
  const { isOwnerOrManager } = useAuth();
  const [, navigate] = useLocation();
  const [insurerId, setInsurerId] = useState('all');
  const [month, setMonth] = useState('');

  const { data: insurers } = useInsurers();
  const { data: money } = useInsurerMoneySummary();
  const { data: receipts, isLoading } = useReceipts({ insurerId, month: month || undefined });

  if (!isOwnerOrManager) {
    return <div className="text-muted-foreground">Only owners and managers can view receipts.</div>;
  }

  const insurerName = (id: string) => insurers?.find(i => i.id === id)?.name ?? 'Insurer';
  const unappliedCards = (money ?? []).filter(m => m.unapplied > 0.005);

  const statusOf = (r: { applied: number; unapplied: number }) =>
    r.applied <= 0 ? 'Not applied' : r.unapplied > 0.005 ? 'Partly applied' : 'Fully applied';

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Receipts</h1>
          <p className="text-muted-foreground">Money received from insurers and where it was applied.</p>
        </div>
        <Button onClick={() => navigate('/receipts/new')}>
          <Plus className="w-4 h-4 mr-2" /> Record receipt
        </Button>
      </div>

      {unappliedCards.length > 0 && (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold tracking-tight">Unapplied money</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4">
            {unappliedCards.map(m => (
              <Card key={m.insurerId} className="bg-card">
                <CardContent className="p-4">
                  <div className="text-sm font-medium text-muted-foreground">{insurerName(m.insurerId)}</div>
                  <div className="text-lg font-bold">{formatCurrency(m.unapplied)}</div>
                  <div className="text-xs text-muted-foreground">Received, not yet applied</div>
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      )}

      <div className="flex flex-col sm:flex-row gap-4">
        <Select value={insurerId} onValueChange={setInsurerId}>
          <SelectTrigger className="w-[220px] bg-card"><SelectValue placeholder="Insurer" /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All insurers</SelectItem>
            {insurers?.map(i => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
          </SelectContent>
        </Select>
        <Input type="month" className="w-[180px] bg-card" value={month} onChange={(e) => setMonth(e.target.value)} aria-label="Month" />
        {month && <Button variant="ghost" onClick={() => setMonth('')}>Clear month</Button>}
      </div>

      <div className="border rounded-md bg-card overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Date</TableHead>
              <TableHead>Insurer</TableHead>
              <TableHead className="text-right">Amount</TableHead>
              <TableHead className="text-right">Applied</TableHead>
              <TableHead className="text-right">Unapplied</TableHead>
              <TableHead>Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow><TableCell colSpan={6} className="text-center py-8">Loading...</TableCell></TableRow>
            ) : !receipts || receipts.length === 0 ? (
              <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">No receipts found.</TableCell></TableRow>
            ) : (
              receipts.map(r => {
                const status = statusOf(r);
                return (
                  <TableRow key={r.id}>
                    <TableCell>
                      <Link href={`/receipts/${r.id}`} className="font-medium text-primary underline">{formatDate(r.received_on)}</Link>
                      {r.is_opening_balance && <Badge variant="secondary" className="ml-2 text-muted-foreground">Opening balance</Badge>}
                    </TableCell>
                    <TableCell>{r.insurer?.name ?? '-'}</TableCell>
                    <TableCell className="text-right font-medium">{formatCurrency(r.amount)}</TableCell>
                    <TableCell className="text-right">{formatCurrency(r.applied)}</TableCell>
                    <TableCell className="text-right">{formatCurrency(r.unapplied)}</TableCell>
                    <TableCell>
                      <Badge variant={status === 'Fully applied' ? 'success' : status === 'Partly applied' ? 'warning' : 'secondary'}>{status}</Badge>
                    </TableCell>
                  </TableRow>
                );
              })
            )}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
