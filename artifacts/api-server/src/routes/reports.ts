import { Router } from "express";
import { supabaseAdmin } from "../lib/supabase-admin";
import { z } from "zod";

const router = Router();

const bodySchema = z.object({
  month: z.number().int().min(1).max(12).optional(),
  year:  z.number().int().min(2020).optional(),
});

router.post("/api/reports/generate", async (req, res) => {
  // ── Auth ────────────────────────────────────────────────────────────────
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) return res.status(401).json({ error: "Unauthorized" });

  const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !user) return res.status(401).json({ error: "Invalid token" });

  const { data: profile } = await supabaseAdmin
    .from("users")
    .select("agency_id, role")
    .eq("id", user.id)
    .single();

  if (!profile) return res.status(403).json({ error: "No profile found" });
  if (!["owner", "admin"].includes(profile.role))
    return res.status(403).json({ error: "Only owners and admins can generate reports" });

  // ── Period ───────────────────────────────────────────────────────────────
  const parsed = bodySchema.safeParse(req.body);
  const prev   = new Date();
  prev.setMonth(prev.getMonth() - 1);

  const month = parsed.success && parsed.data.month ? parsed.data.month : prev.getMonth() + 1;
  const year  = parsed.success && parsed.data.year  ? parsed.data.year  : prev.getFullYear();

  const startDate = `${year}-${String(month).padStart(2, "0")}-01`;
  const lastDay   = new Date(year, month, 0).getDate();
  const endDate   = `${year}-${String(month).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}`;

  const { agency_id } = profile;

  // ── Queries (parallel) ──────────────────────────────────────────────────
  const [
    { data: policies },
    { data: commissions },
    { data: newClients },
    { data: renewalsDue30 },
    { data: allActivePolicies },
  ] = await Promise.all([
    supabaseAdmin
      .from("policies")
      .select("id, status, premium_amount, commission_expected, commission_received")
      .eq("agency_id", agency_id)
      .gte("start_date", startDate)
      .lte("start_date", endDate),

    supabaseAdmin
      .from("commission_transactions")
      .select("id, amount, status")
      .eq("agency_id", agency_id)
      .gte("created_at", `${startDate}T00:00:00Z`)
      .lte("created_at", `${endDate}T23:59:59Z`),

    supabaseAdmin
      .from("clients")
      .select("id")
      .eq("agency_id", agency_id)
      .gte("created_at", `${startDate}T00:00:00Z`)
      .lte("created_at", `${endDate}T23:59:59Z`),

    supabaseAdmin
      .from("policies")
      .select("id")
      .eq("agency_id", agency_id)
      .eq("status", "active")
      .gte("expiry_date", new Date().toISOString().split("T")[0])
      .lte("expiry_date", new Date(Date.now() + 30 * 86_400_000).toISOString().split("T")[0]),

    supabaseAdmin
      .from("policies")
      .select("id, status")
      .eq("agency_id", agency_id),
  ]);

  const totalPoliciesWritten = policies?.length ?? 0;
  const totalPremium         = policies?.reduce((s, p) => s + (Number(p.premium_amount) || 0), 0) ?? 0;
  const commExpected         = policies?.reduce((s, p) => s + (Number(p.commission_expected) || 0), 0) ?? 0;
  const commReceived         = commissions?.filter(c => c.status === "received").reduce((s, c) => s + (Number(c.amount) || 0), 0) ?? 0;

  const totalActive    = allActivePolicies?.filter(p => p.status === "active").length ?? 0;
  const totalExpired   = allActivePolicies?.filter(p => p.status === "expired").length ?? 0;
  const totalCancelled = allActivePolicies?.filter(p => p.status === "cancelled").length ?? 0;

  const metadata = {
    month, year,
    total_policies_written:   totalPoliciesWritten,
    total_premium_kes:        totalPremium,
    commission_expected_kes:  commExpected,
    commission_received_kes:  commReceived,
    collection_rate_pct:      commExpected > 0 ? Math.round((commReceived / commExpected) * 1000) / 10 : 0,
    new_clients:              newClients?.length ?? 0,
    renewals_due_30d:         renewalsDue30?.length ?? 0,
    portfolio_active:         totalActive,
    portfolio_expired:        totalExpired,
    portfolio_cancelled:      totalCancelled,
    generated_at:             new Date().toISOString(),
  };

  // ── Store ────────────────────────────────────────────────────────────────
  const { data: report, error: insertErr } = await supabaseAdmin
    .from("reports")
    .insert({ agency_id, month, year, metadata, generated_at: new Date().toISOString() })
    .select()
    .single();

  if (insertErr) return res.status(500).json({ error: insertErr.message });
  return res.json({ report, metadata });
});

router.get("/api/reports", async (req, res) => {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) return res.status(401).json({ error: "Unauthorized" });

  const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !user) return res.status(401).json({ error: "Invalid token" });

  const { data: profile } = await supabaseAdmin
    .from("users")
    .select("agency_id")
    .eq("id", user.id)
    .single();

  if (!profile) return res.status(403).json({ error: "No profile" });

  const { data, error } = await supabaseAdmin
    .from("reports")
    .select("*")
    .eq("agency_id", profile.agency_id)
    .order("year", { ascending: false })
    .order("month", { ascending: false });

  if (error) return res.status(500).json({ error: error.message });
  return res.json({ reports: data });
});

export default router;
