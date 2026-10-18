export type Profile = {
  id: string;
  display_name: string;
  username?: string;
  email: string;
  avatar_url: string | null;
  bio?: string | null;
  profile_color?: string;
  equipped_title?: string | null;
  role: "user" | "admin" | "super_admin";
  visual_role?: "demo_admin" | "demo_owner" | null;
};

export type Wallet = {
  id: string;
  user_id: string;
  balance: number;
  credits?: number;
  created_at: string;
  updated_at: string;
  status?: "active" | "locked";
  locked_until?: string | null;
  lock_reason?: string | null;
};

export type Recipient = {
  id: string;
  display_name: string;
  email_hint: string;
  avatar_url: string | null;
  profile_color?: string | null;
};

export type Transaction = {
  id: string;
  sender_user_id: string | null;
  receiver_user_id: string | null;
  amount: number;
  previous_hash: string;
  hash: string;
  created_at: string;
  sender_label: string;
  receiver_label: string;
  type: string;
  note?: string | null;
};

export type Block = {
  height: number;
  previous_hash: string;
  merkle_root: string;
  first_chain_index: number | null;
  last_chain_index: number | null;
  tx_count: number;
  mined_at: string;
  difficulty_bits: number;
  nonce: number;
  hash: string;
  miner_user_id: string | null;
  miner_label: string;
  reward: number;
  reward_transaction_id: string | null;
  created_at: string;
};
