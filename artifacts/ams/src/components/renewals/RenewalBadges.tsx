import { Badge } from '@/components/ui/badge';
import type { PolicyRenewalInfo } from '@/hooks/renewals';
import { stageLabel } from '@/lib/renewals';

/**
 * Renewal stage badge plus "Renewed as / from" lines for one policy.
 * numberById maps policy ids on the page to their numbers; a linked term
 * that is not on the page is shown without its number.
 */
export function RenewalBadges({
  policyId,
  info,
  numberById,
}: {
  policyId: string;
  info: PolicyRenewalInfo | undefined;
  numberById: Record<string, string>;
}) {
  if (!info) return null;
  const stage = info.stage[policyId];
  const renewedAs = info.renewedAs[policyId];
  const renewedFrom = info.renewedFrom[policyId];
  if (!stage && !renewedFrom) return null;
  return (
    <div className="mt-1 flex flex-col items-start gap-1">
      {stage && (
        <Badge variant="outline" className="text-xs font-normal">
          Renewal: {stageLabel(stage)}
        </Badge>
      )}
      {renewedAs && (
        <span className="text-xs text-muted-foreground">
          Renewed as {numberById[renewedAs] ?? 'a new policy'}
        </span>
      )}
      {renewedFrom && (
        <span className="text-xs text-muted-foreground">
          Renewed from {numberById[renewedFrom] ?? 'an earlier policy'}
        </span>
      )}
    </div>
  );
}
