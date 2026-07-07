import { Router } from "express";
import { supabaseAdmin } from "../lib/supabase-admin";
import { z } from "zod";

const router = Router();

const setupSchema = z.object({
  agency_name: z.string().min(2, "Agency name is required"),
  owner_name: z.string().min(2, "Your name is required"),
  owner_phone: z.string().optional(),
});

/**
 * POST /api/agency/setup
 *
 * Called immediately after Supabase Auth signup. Creates the agency,
 * owner user profile, and seeds default Kenyan product lines.
 *
 * Requires: Authorization: Bearer <supabase-jwt>
 */
router.post("/agency/setup", async (req, res) => {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid Authorization header" });
  }

  const token = authHeader.slice(7);

  // Verify the JWT and get the authenticated user
  const { data: userData, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !userData.user) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }

  const parsed = setupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message ?? "Invalid input" });
  }

  const { agency_name, owner_name, owner_phone } = parsed.data;
  const authUser = userData.user;

  // Check if user already has a profile (prevent duplicate setups)
  const { data: existingUser } = await supabaseAdmin
    .from("users")
    .select("id, agency_id")
    .eq("id", authUser.id)
    .single();

  if (existingUser) {
    return res.json({ agency_id: existingUser.agency_id, already_setup: true });
  }

  // Create agency + owner profile + seed product lines atomically via RPC
  const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
    "create_agency_with_owner",
    {
      p_auth_user_id: authUser.id,
      p_agency_name: agency_name,
      p_owner_name: owner_name,
      p_owner_email: authUser.email ?? "",
      p_owner_phone: owner_phone ?? null,
    },
  );

  if (rpcError) {
    req.log.error({ err: rpcError }, "Agency setup RPC failed");
    return res.status(500).json({ error: "Failed to create agency. Please try again." });
  }

  return res.status(201).json(rpcResult);
});

export default router;
