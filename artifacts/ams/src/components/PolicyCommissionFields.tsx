import { useEffect, useRef } from 'react';
import type { UseFormReturn } from 'react-hook-form';
import { FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { autoCommissionBasis } from '@/lib/policy-form';

/** Commission type + per-premium fields. The form needs product_line_id and the fields from lib/policy-form. */
export function PolicyCommissionFields({
  form,
  productLines,
  keepInitialBasis = false,
}: {
  form: UseFormReturn<any>;
  productLines: { id: string; name: string }[] | undefined;
  /** Pre-filled forms (e.g. Renew): keep the loaded commission type until the user picks another product line. */
  keepInitialBasis?: boolean;
}) {
  const manual = useRef(false);
  const initialLine = useRef<string | null>(null);
  const productLineId: string = form.watch('product_line_id');
  const basis: string = form.watch('commission_basis');

  useEffect(() => {
    if (!productLineId) {
      manual.current = false; // form was reset
      initialLine.current = null;
      return;
    }
    if (keepInitialBasis && (initialLine.current === null || initialLine.current === productLineId)) {
      initialLine.current = productLineId;
      return;
    }
    const name = productLines?.find((p) => p.id === productLineId)?.name;
    const next = autoCommissionBasis(name, manual.current);
    if (next) form.setValue('commission_basis', next);
  }, [productLineId, productLines, form, keepInitialBasis]);

  return (
    <div className="space-y-4">
      <FormField
        control={form.control}
        name="commission_basis"
        render={({ field }) => (
          <FormItem>
            <FormLabel>Commission type</FormLabel>
            <Select
              value={field.value}
              onValueChange={(v) => {
                manual.current = true;
                field.onChange(v);
              }}
            >
              <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
              <SelectContent>
                <SelectItem value="annual">Annual</SelectItem>
                <SelectItem value="per_premium">Per premium</SelectItem>
              </SelectContent>
            </Select>
            <FormMessage />
          </FormItem>
        )}
      />
      {basis === 'per_premium' && (
        <div className="grid grid-cols-3 gap-4">
          <FormField
            control={form.control}
            name="premium_frequency"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Payment frequency</FormLabel>
                <Select value={field.value || ''} onValueChange={field.onChange}>
                  <FormControl><SelectTrigger><SelectValue placeholder="Select" /></SelectTrigger></FormControl>
                  <SelectContent>
                    <SelectItem value="monthly">Monthly</SelectItem>
                    <SelectItem value="quarterly">Quarterly</SelectItem>
                    <SelectItem value="half_yearly">Half-yearly</SelectItem>
                    <SelectItem value="yearly">Yearly</SelectItem>
                  </SelectContent>
                </Select>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="instalment_premium"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Amount per payment</FormLabel>
                <FormControl><Input type="number" step="0.01" {...field} value={field.value ?? ''} /></FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="renewal_commission_rate"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Later-years rate (%)</FormLabel>
                <FormControl><Input type="number" step="0.1" placeholder="Optional" {...field} value={field.value ?? ''} /></FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
      )}
    </div>
  );
}
