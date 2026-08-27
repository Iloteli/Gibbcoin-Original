export type Profile = {
  id: string;
  display_name: string;
  email: string;
  avatar_url: string | null;
  role: "user" | "admin" | "super_admin";
  visual_role?: "demo_admin" | "demo_owner" | null;
};

export type Wallet = {
  id: string;
  user_id: string;
  balance: number;
  created_at: string;
  updated_at: string;
  status?: "active" | "locked";
};

export type Recipient = {
  id: string;
  display_name: string;
  email_hint: string;
  avatar_url: string | null;
};

export type Transaction = {
  id: string;
  sender_user_id: string | null;
  receiver_user_id: string;
  amount: number;
  previous_hash: string;
  hash: string;
  created_at: string;
  sender_label: string;
  receiver_label: string;
  type: string;
};
