const BASE = '/api';

export async function api<T = Record<string, unknown>>(
  path: string,
  opts: RequestInit = {},
): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(opts.headers as Record<string, string> || {}),
  };
  const res = await fetch(`${BASE}${path}`, { ...opts, headers });
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new Error(`${res.status}: ${text}`);
  }
  return res.json();
}

export function appendDevice(path: string, device: string): string {
  if (!device) return path;
  const sep = path.includes('?') ? '&' : '?';
  return `${path}${sep}device=${encodeURIComponent(device)}`;
}

// ── Types ────────────────────────────────────────────────
export interface Device {
  name: string;
  type: string;
  online: boolean;
  ip?: string;
  tailscale_ip?: string;
}

export interface Org {
  name: string;
  ssh_host_alias?: string;
  default_branch?: string;
  repo_count?: number;
  cloned_count?: number;
}

export interface Repo {
  name: string;
  org: string;
  path?: string;
  branch?: string;
}

export interface Task {
  id: number;
  title: string;
  status: string;
  branch?: string;
  base_branch?: string;
  repo?: string;
  org?: string;
  context_type?: string;
  context_ref?: string;
  description?: string;
  instruction?: string;
  verification?: string;
  plan_document?: string;
  spec_document?: string;
  slug?: string;
  cli?: string;
  model?: string;
  github_issue?: string;
  conductor_track?: string;
  timelimit?: number;
  created_by?: string;
  created_at?: string;
}

export interface Subtask {
  id: number;
  task_id: number;
  title: string;
  phase: string;
  ordinal: number;
  status: string;
  checkpoint?: string;
  evidence?: string;
}

export interface Job {
  id: number;
  org: string;
  repo: string;
  branch: string;
  device: string;
  cli: string;
  status: string;
  action?: string;
  task_id?: number;
  task_title?: string;
  command?: string;
  tmux_session?: string;
  vt_url?: string;
  connect_cmd?: string;
  vt_session_id?: string;
  exit_code?: number;
  error?: string;
  agent_prompt?: string;
  started_at?: string;
  ended_at?: string;
}

export interface StatusData {
  version: string;
  running_jobs: number;
  total_tasks: number;
  active_device: string;
  devices: Device[];
  orgs: string[];
}
