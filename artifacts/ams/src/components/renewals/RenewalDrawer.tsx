import { Link } from 'wouter';
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { Badge } from '@/components/ui/badge';
import { usePolicyForRenewal, useRenewalActivities } from '@/hooks/renewals';
import { channelLabel, lostReasonLabel, stageLabel } from '@/lib/renewals';
import { formatCurrency, formatDate } from '@/lib/utils';
import type { RenewalActivity, RenewalRow } from '@/lib/types';

function describe(a: RenewalActivity): string {
  switch (a.kind) {
    case 'contact':
      return `Contacted by ${a.channel ? channelLabel(a.channel) : 'unknown channel'}`;
    case 'quote':
      return `Quoted ${formatCurrency(a.premium)}${a.insurer?.name ? ` with ${a.insurer.name}` : ''}`;
    case 'renewed':
      return `Renewed${a.premium != null ? ` at ${formatCurrency(a.premium)}` : ''}${a.insurer?.name ? ` with ${a.insurer.name}` : ''}`;
    case 'lost':
      return `Lost: ${a.lost_reason ? lostReasonLabel(a.lost_reason) : 'no reason'}`;
    case 'reopened':
      return 'Reopened';
    case 'reset':
      return 'Renewal undone (new policy deleted)';
  }
}

export function RenewalDrawer({ row, onClose }: { row: RenewalRow | null; onClose: () => void }) {
  const { data: activities, isLoading } = useRenewalActivities(row?.renewal_id);
  const { data: newPolicy } = usePolicyForRenewal(row?.renewed_policy_id);

  return (
    <Sheet open={!!row} onOpenChange={(o) => !o && onClose()}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader>
          <SheetTitle>{row?.client_name ?? 'Client'}</SheetTitle>
          <SheetDescription>
            {row?.policy_number} · {row?.product_line_name} · {row?.insurer_name}
          </SheetDescription>
        </SheetHeader>
        {row && (
          <div className="mt-6 space-y-6 text-sm">
            <div className="grid grid-cols-2 gap-3">
              <div>
                <div className="text-muted-foreground">Stage</div>
                <Badge variant="secondary">{stageLabel(row.stage)}</Badge>
              </div>
              <div>
                <div className="text-muted-foreground">Expiry</div>
                <div>{formatDate(row.expiry_date)}</div>
              </div>
              <div>
                <div className="text-muted-foreground">Premium</div>
                <div>{formatCurrency(row.premium_amount)}</div>
              </div>
              <div>
                <div className="text-muted-foreground">Agent</div>
                <div>{row.agent_name ?? '—'}</div>
              </div>
              {row.quoted_premium != null && (
                <div className="col-span-2">
                  <div className="text-muted-foreground">Latest quote</div>
                  <div>
                    {formatCurrency(row.quoted_premium)}
                    {row.quoted_insurer_name ? ` · ${row.quoted_insurer_name}` : ''}
                  </div>
                </div>
              )}
              {row.renewed_policy_id && (
                <div className="col-span-2">
                  <div className="text-muted-foreground">Renewed as</div>
                  <div>
                    {newPolicy
                      ? `${newPolicy.policy_number} · ${formatDate(newPolicy.start_date)} – ${formatDate(newPolicy.expiry_date)}`
                      : 'New policy'}
                  </div>
                </div>
              )}
            </div>
            <Link href={`/clients/${row.client_id}`} className="text-primary underline-offset-4 hover:underline">
              Open client
            </Link>
            <div>
              <h3 className="mb-3 font-semibold">History</h3>
              {!row.renewal_id ? (
                <p className="text-muted-foreground">Nothing logged yet.</p>
              ) : isLoading ? (
                <p className="text-muted-foreground">Loading…</p>
              ) : (
                <ol className="space-y-3">
                  {(activities ?? []).map((a) => (
                    <li key={a.id} className="border-l-2 pl-3">
                      <div className="font-medium">{describe(a)}</div>
                      <div className="text-xs text-muted-foreground">
                        {formatDate(a.occurred_on)}
                        {a.author?.full_name ? ` · ${a.author.full_name}` : ''}
                      </div>
                      {a.note && <p className="mt-1 whitespace-pre-wrap">{a.note}</p>}
                    </li>
                  ))}
                </ol>
              )}
            </div>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}
