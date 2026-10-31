// ============================================================
// AMS Database Types — matches supabase/migrations/001_initial_schema.sql
// ============================================================

export type AgencySubscriptionTier = 'starter' | 'pro' | 'enterprise';

export interface Agency {
  id: string;
  name: string;
  logo_url?: string | null;
  primary_color: string;
  email?: string | null;
  phone?: string | null;
  address?: string | null;
  subscription_tier: AgencySubscriptionTier;
  created_at: string;
}

export type UserRole = 'owner' | 'manager' | 'agent';

export interface AgencyUser {
  id: string;
  agency_id: string;
  role: UserRole;
  full_name: string;
  phone?: string | null;
  email?: string | null;
  deactivated_at: string | null;
  created_at: string;
}

export interface AgencyInvite {
  id: string;
  agency_id: string;
  email: string;
  role: 'manager' | 'agent';
  invited_by: string;
  created_at: string;
  expires_at: string;
  accepted_at: string | null;
  accepted_by: string | null;
  revoked_at: string | null;
}

export interface Insurer {
  id: string;
  agency_id: string;
  name: string;
  contact_email?: string | null;
  contact_phone?: string | null;
  website?: string | null;
  is_active: boolean;
  created_at: string;
}

export interface ProductLine {
  id: string;
  agency_id: string;
  name: string;
  description?: string | null;
  is_active: boolean;
  created_at: string;
}

export type ClientType = 'individual' | 'corporate';

export interface Client {
  id: string;
  agency_id: string;
  type: ClientType;
  name: string;
  phone?: string | null;
  email?: string | null;
  kra_pin?: string | null;
  id_or_reg_number?: string | null;
  address?: string | null;
  assigned_agent_id: string;
  created_at: string;
}

export interface ClientWithAgent extends Client {
  assigned_agent: { id: string; full_name: string } | null;
}

export type PolicyStatus = 'active' | 'expired' | 'cancelled' | 'pending';

export interface Policy {
  id: string;
  agency_id: string;
  client_id: string;
  insurer_id: string;
  product_line_id: string;
  agent_id: string;
  policy_number: string;
  premium_amount: number;
  commission_rate: number;
  commission_expected: number;
  commission_received: number;
  start_date: string;
  expiry_date: string;
  status: PolicyStatus;
  notes?: string | null;
  created_at: string;
  updated_at: string;
}

// Joined policy (with nested objects)
export interface PolicyWithRelations extends Policy {
  // null when RLS hides the client (e.g. it was reassigned away from this agent)
  client: Pick<Client, 'id' | 'name' | 'type' | 'phone' | 'email'> | null;
  insurer: Pick<Insurer, 'id' | 'name'>;
  product_line: Pick<ProductLine, 'id' | 'name'>;
  agent: Pick<AgencyUser, 'id' | 'full_name'>;
}

export type CommissionStatus = 'pending' | 'received' | 'overdue';

export interface CommissionTransaction {
  id: string;
  policy_id: string;
  agency_id: string;
  amount: number;
  expected_date?: string | null;
  received_date?: string | null;
  status: CommissionStatus;
  notes?: string | null;
  created_at: string;
}

export type ReminderChannel = 'whatsapp' | 'email' | 'sms';

export interface RenewalReminder {
  id: string;
  policy_id: string;
  agency_id: string;
  reminder_date: string;
  channel: ReminderChannel;
  sent: boolean;
  sent_at?: string | null;
  notes?: string | null;
  created_at: string;
}

export interface Report {
  id: string;
  agency_id: string;
  month: number;
  year: number;
  generated_at: string;
  file_url?: string | null;
  metadata?: Record<string, unknown> | null;
}

// ============================================================
// Auth / Session Types
// ============================================================

export interface AuthSession {
  user: {
    id: string;
    email: string;
  };
  profile: AgencyUser;
  agency: Agency;
}
