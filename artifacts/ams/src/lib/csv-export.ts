/**
 * Flattens a record so nested objects become dot-notation keys.
 * e.g. { client: { name: "Jane" } } → { "client.name": "Jane" }
 */
function flattenRow(obj: Record<string, unknown>, prefix = ''): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, val] of Object.entries(obj)) {
    const fullKey = prefix ? `${prefix}.${key}` : key;
    if (val !== null && val !== undefined && typeof val === 'object' && !Array.isArray(val)) {
      Object.assign(out, flattenRow(val as Record<string, unknown>, fullKey));
    } else if (val === null || val === undefined) {
      out[fullKey] = '';
    } else {
      out[fullKey] = String(val);
    }
  }
  return out;
}

function escapeCell(val: string): string {
  if (val.includes(',') || val.includes('"') || val.includes('\n')) {
    return `"${val.replace(/"/g, '""')}"`;
  }
  return val;
}

/**
 * Downloads rows as a CSV file.
 * Nested relation objects are automatically flattened to dot-notation columns.
 *
 * @param filename  File name without the .csv extension
 * @param rows      Array of row objects (may include nested relations)
 * @param columns   Optional explicit column whitelist — pass to control order and exclude internals.
 *                  Each item: a key (dotted path after flatten) and an optional label.
 *                  e.g. [{ key: 'client.name', label: 'Client' }, { key: 'premium_amount', label: 'Premium (KES)' }]
 */
export function exportToCsv(
  filename: string,
  rows: Record<string, unknown>[],
  columns?: { key: string; label?: string }[],
): void {
  if (!rows || rows.length === 0) return;

  const flat = rows.map(r => flattenRow(r));

  // Determine headers
  const allKeys = columns
    ? columns.map(c => c.key)
    : Object.keys(flat[0] ?? {});

  const headers = columns
    ? columns.map(c => c.label ?? c.key)
    : allKeys;

  const csvLines = [
    headers.map(escapeCell).join(','),
    ...flat.map(row =>
      allKeys.map(k => escapeCell(row[k] ?? '')).join(',')
    ),
  ];

  const blob = new Blob([csvLines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.setAttribute('href', url);
  link.setAttribute('download', `${filename}.csv`);
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}
