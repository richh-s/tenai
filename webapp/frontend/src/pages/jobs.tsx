import { useEffect, useState, useCallback, useRef } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import {
  Cpu,
  RotateCw,
  ExternalLink,
  Square,
  Copy,
  ClipboardCheck,
  Plug,
  ScrollText,
  FileText,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  ChevronUp,
  Filter,
  Plus,
  Trash2,
  Send,
  MessageSquare,
} from 'lucide-react';
import { ColumnView } from '@/components/column-view';
import { api, appendDevice, type Job } from '@/lib/api';
import { useApp } from '@/lib/store';

interface LogEntry {
  id: number;
  job_id: number;
  line: string;
  timestamp: string;
}

const STATUS_OPTIONS = ['all', 'running', 'completed', 'failed', 'killed', 'pending'] as const;

function statusColor(s: string) {
  const m: Record<string, string> = {
    running: 'bg-green-500/15 text-green-400 border-green-500/30',
    completed: 'bg-blue-500/15 text-blue-400 border-blue-500/30',
    failed: 'bg-red-500/15 text-red-400 border-red-500/30',
    killed: 'bg-yellow-500/15 text-yellow-400 border-yellow-500/30',
    pending: 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30',
  };
  return m[s] || 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30';
}

function statusDot(s: string) {
  if (s === 'running') return 'bg-green-400 animate-pulse';
  if (s === 'failed') return 'bg-red-400';
  if (s === 'completed') return 'bg-blue-400';
  if (s === 'killed') return 'bg-yellow-400';
  return 'bg-zinc-400';
}

function logLineColor(line: string) {
  if (line.startsWith('ERROR')) return 'text-red-400';
  if (line.startsWith('VT ')) return 'text-blue-400';
  return 'text-zinc-300';
}

export default function Jobs() {
  const navigate = useNavigate();
  const { device } = useApp();
  const [jobs, setJobs] = useState<Job[]>([]);
  const [total, setTotal] = useState(0);
  const [activeJob, setActiveJob] = useState<(Job & { logs?: LogEntry[]; task_title?: string; progress?: { total: number; completed: number; percent: number } }) | null>(null);
  const [detailTab, setDetailTab] = useState<'logs' | 'worktree' | 'interact'>('interact');
  const [worktreeMd, setWorktreeMd] = useState<string | null>(null);
  const [loadingWt, setLoadingWt] = useState(false);

  // Interact tab state
  const [interactMsg, setInteractMsg] = useState('');
  const [sendingMsg, setSendingMsg] = useState(false);
  const [tmuxOutput, setTmuxOutput] = useState('');
  const captureRef = useRef<HTMLPreElement>(null);
  const [headerExpanded, setHeaderExpanded] = useState(false);
  const logEndRef = useRef<HTMLDivElement>(null);
  const [ctrlMode, setCtrlMode] = useState(false);
  const [tmuxMode, setTmuxMode] = useState(false);

  // Filters & pagination
  const [filterStatus, setFilterStatus] = useState('all');
  const [filterOrg, setFilterOrg] = useState('');
  const [filterRepo, setFilterRepo] = useState('');
  const [pageSize, setPageSize] = useState(20);
  const [page, setPage] = useState(0);

  // Multi-select
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [deleting, setDeleting] = useState(false);

  // Filter options
  const [orgOptions, setOrgOptions] = useState<string[]>([]);
  const [repoOptions, setRepoOptions] = useState<string[]>([]);

  const toggleSelect = (id: number) => {
    setSelectedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };
  const toggleAll = () => {
    if (selectedIds.size === jobs.length) setSelectedIds(new Set());
    else setSelectedIds(new Set(jobs.map(j => j.id)));
  };
  const batchDelete = async () => {
    if (selectedIds.size === 0) return;
    if (!confirm(`Delete/kill ${selectedIds.size} job(s)?`)) return;
    setDeleting(true);
    try {
      await api(appendDevice('/jobs-batch-delete', device), {
        method: 'POST',
        body: JSON.stringify({ job_ids: Array.from(selectedIds) }),
      });
      setSelectedIds(new Set());
      load();
    } catch { /* ignore */ }
    setDeleting(false);
  };

  const load = useCallback(() => {
    const params = new URLSearchParams();
    if (device) params.set('device', device);
    if (filterStatus !== 'all') params.set('status', filterStatus);
    if (filterOrg) params.set('org', filterOrg);
    if (filterRepo) params.set('repo', filterRepo);
    params.set('limit', String(pageSize));
    params.set('offset', String(page * pageSize));

    api<{ jobs: Job[]; total: number }>(`/jobs?${params}`)
      .then(r => {
        setJobs(r.jobs || []);
        setTotal(r.total ?? r.jobs?.length ?? 0);
        const orgs = new Set<string>();
        const repos = new Set<string>();
        (r.jobs || []).forEach(j => {
          if (j.org) orgs.add(j.org);
          if (j.repo) repos.add(j.repo);
        });
        setOrgOptions(prev => {
          const merged = new Set([...prev, ...orgs]);
          return Array.from(merged).sort((a, b) => a.localeCompare(b));
        });
        setRepoOptions(prev => {
          const merged = new Set([...prev, ...repos]);
          return Array.from(merged).sort((a, b) => a.localeCompare(b));
        });
      })
      .catch(() => {});
  }, [device, filterStatus, filterOrg, filterRepo, pageSize, page]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => { setPage(0); }, [filterStatus, filterOrg, filterRepo]);

  // Deep-link: auto-open job from ?open=<id> URL param
  const [searchParams, setSearchParams] = useSearchParams();
  useEffect(() => {
    const openId = searchParams.get('open');
    if (openId && jobs.length > 0) {
      const target = jobs.find(j => j.id === Number(openId));
      if (target) {
        openJobDetail(target);
        setSearchParams({}, { replace: true }); // clean up URL
      }
    }
  }, [jobs, searchParams]);

  // Auto-refresh for running jobs
  useEffect(() => {
    const hasRunning = jobs.some(j => j.status === 'running');
    if (!hasRunning) return;
    const id = setInterval(() => {
      load();
      if (activeJob && activeJob.status === 'running') {
        refreshJobDetail(activeJob.id);
      }
    }, 10000);
    return () => clearInterval(id);
  }, [jobs, load, activeJob]);

  const refreshJobDetail = async (jobId: number) => {
    try {
      const r = await api<Job & { logs?: LogEntry[] }>(appendDevice(`/jobs/${jobId}`, device));
      setActiveJob(r);
    } catch { /* ignore */ }
  };

  const loadWorktreeMd = async (jobId: number, taskId?: number) => {
    setLoadingWt(true);
    try {
      // Try job-level worktree-md first (persisted in DB)
      const r = await api<{ content: string }>(appendDevice(`/jobs/${jobId}/worktree-md`, device));
      setWorktreeMd(r.content || 'No WORKTREE.md content');
    } catch {
      // Fallback to task-db endpoint if available
      if (taskId) {
        try {
          const r = await api<{ content: string }>(appendDevice(`/task-db/${taskId}/worktree-md`, device));
          setWorktreeMd(r.content || 'No WORKTREE.md content');
        } catch {
          setWorktreeMd('Could not load WORKTREE.md');
        }
      } else {
        setWorktreeMd('No WORKTREE.md content available');
      }
    }
    setLoadingWt(false);
  };

  const openJobDetail = async (j: Job) => {
    setDetailTab('interact');
    setWorktreeMd(null);
    try {
      const r = await api<Job & { logs?: LogEntry[]; task_id?: number }>(appendDevice(`/jobs/${j.id}`, device));
      setActiveJob(r);
      // Auto-fetch tmux capture since interact is the default tab
      if (r.tmux_session) {
        api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${r.id}/tmux-capture`, device))
          .then(cr => { if (cr.ok) setTmuxOutput(cr.output); })
          .catch(() => {});
      }
    } catch {
      setActiveJob({ ...j, logs: [] });
    }
  };

  const switchToWorktreeTab = () => {
    setDetailTab('worktree');
    if (activeJob && !worktreeMd) {
      loadWorktreeMd(activeJob.id, activeJob.task_id);
    }
  };

  const killJob = async (id: number) => {
    await api(appendDevice(`/jobs/${id}`, device), { method: 'DELETE' }).catch(() => {});
    load();
    if (activeJob?.id === id) setActiveJob(null);
  };

  const attachVT = async (id: number) => {
    try {
      const r = await api<{ vt_url?: string }>(appendDevice(`/jobs/${id}/vt-attach`, device), { method: 'POST' });
      if (r.vt_url) window.open(r.vt_url, '_blank');
      load();
      refreshJobDetail(id);
    } catch { /* ignore */ }
  };



  const totalPages = Math.ceil(total / pageSize);

  // ── Column 1: Job list (compact table) ──
  const listColumn = (
    <div className="flex flex-col h-full">
      <div className="flex items-center gap-2 px-4 pt-4 pb-2">
        <Cpu className="w-5 h-5" />
        <h1 className="text-lg font-bold flex-1">Jobs</h1>
        <span className="text-xs text-muted-foreground">{total} total</span>
        <Button variant="ghost" size="icon" onClick={load}><RotateCw className="w-4 h-4" /></Button>
        {selectedIds.size > 0 && (
          <Button variant="destructive" size="sm" className="h-7 gap-1 text-xs" disabled={deleting}
            onClick={batchDelete}>
            <Trash2 className="w-3 h-3" /> Delete {selectedIds.size}
          </Button>
        )}
        <Button variant="outline" size="sm" className="h-7 gap-1 text-xs" onClick={() => navigate('/jobs/launch')}>
          <Plus className="w-3 h-3" /> New Job
        </Button>
      </div>

      {/* Filter bar */}
      <div className="px-4 pb-2 flex flex-wrap items-center gap-2">
        <Filter className="w-3.5 h-3.5 text-muted-foreground" />
        <select className="h-7 text-xs bg-background border border-border rounded px-2 text-foreground" value={filterStatus} onChange={e => setFilterStatus(e.target.value)}>
          {STATUS_OPTIONS.map(s => (
            <option key={s} value={s}>{s === 'all' ? 'All Status' : s}</option>
          ))}
        </select>
        {orgOptions.length > 0 && (
          <select className="h-7 text-xs bg-background border border-border rounded px-2 text-foreground" value={filterOrg} onChange={e => setFilterOrg(e.target.value)}>
            <option value="">All Orgs</option>
            {orgOptions.map(o => <option key={o} value={o}>{o}</option>)}
          </select>
        )}
        {repoOptions.length > 0 && (
          <select className="h-7 text-xs bg-background border border-border rounded px-2 text-foreground" value={filterRepo} onChange={e => setFilterRepo(e.target.value)}>
            <option value="">All Repos</option>
            {repoOptions.map(r => <option key={r} value={r}>{r}</option>)}
          </select>
        )}
        <select className="h-7 text-xs bg-background border border-border rounded px-2 text-foreground ml-auto" value={pageSize} onChange={e => { setPageSize(Number(e.target.value)); setPage(0); }}>
          {[10, 20, 50, 100].map(n => (
            <option key={n} value={n}>{n}/page</option>
          ))}
        </select>
      </div>

      {/* Compact table */}
      <div className="flex-1 overflow-auto px-4 pb-2">
        {jobs.length === 0 ? (
          <div className="text-center text-muted-foreground py-16">
            <Cpu className="w-8 h-8 mx-auto mb-2 opacity-50" />
            <p className="text-sm">No jobs found</p>
          </div>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-8">
                  <input type="checkbox" className="accent-primary" checked={jobs.length > 0 && selectedIds.size === jobs.length}
                    onChange={toggleAll} onClick={e => e.stopPropagation()} />
                </TableHead>
                <TableHead className="w-6" />
                <TableHead className="w-10">#</TableHead>
                <TableHead>Repo</TableHead>
                <TableHead className="hidden lg:table-cell">Title</TableHead>
                <TableHead className="hidden md:table-cell">Info</TableHead>
                <TableHead className="w-20">Status</TableHead>
                <TableHead className="w-24 text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {jobs.map(j => (
                <TableRow key={j.id}
                  className={`cursor-pointer ${activeJob?.id === j.id ? 'bg-accent' : ''} ${selectedIds.has(j.id) ? 'bg-accent/50' : ''}`}
                  onClick={() => openJobDetail(j)}>
                  <TableCell onClick={e => e.stopPropagation()}>
                    <input type="checkbox" className="accent-primary" checked={selectedIds.has(j.id)}
                      onChange={() => toggleSelect(j.id)} />
                  </TableCell>
                  <TableCell>
                    <div className={`w-2 h-2 rounded-full ${statusDot(j.status)}`} />
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground">{j.id}</TableCell>
                  <TableCell>
                    <div className="text-sm truncate max-w-[200px]">{j.org ? `${j.org}/` : ''}{j.repo}</div>
                    <div className="text-[11px] text-muted-foreground md:hidden">{j.device} · {j.cli}{j.action ? ` · ${j.action}` : ''}</div>
                  </TableCell>
                  <TableCell className="hidden lg:table-cell">
                    {j.task_title ? (
                      <div className="text-xs truncate max-w-[180px]" title={j.task_title}>
                        {j.task_title.length > 20 ? j.task_title.slice(0, 20) + '…' : j.task_title}
                      </div>
                    ) : j.branch ? (
                      <div className="text-[11px] text-muted-foreground font-mono truncate max-w-[140px]" title={j.branch}>
                        {j.branch}
                      </div>
                    ) : null}
                  </TableCell>
                  <TableCell className="hidden md:table-cell text-xs text-muted-foreground">
                    {j.device} · {j.cli}{j.action ? ` · ${j.action}` : ''}
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline" className={`text-[10px] ${statusColor(j.status)}`}>{j.status}</Badge>
                  </TableCell>
                  <TableCell className="text-right" onClick={e => e.stopPropagation()}>
                    <div className="flex items-center justify-end gap-0.5">
                      {j.vt_url && j.status === 'running' && (
                        <Button variant="ghost" size="icon" className="h-6 w-6" title="Open VibeTunnel"
                          onClick={() => window.open(j.vt_url!, '_blank')}>
                          <ExternalLink className="w-3 h-3" />
                        </Button>
                      )}
                      <Button variant="ghost" size="icon" className="h-6 w-6" title="View Logs"
                        onClick={() => { openJobDetail(j); setDetailTab('logs'); }}>
                        <ScrollText className="w-3 h-3" />
                      </Button>
                      <Button variant="ghost" size="icon" className="h-6 w-6" title="WORKTREE.md"
                          onClick={() => { openJobDetail(j); setTimeout(() => switchToWorktreeTab(), 100); }}>
                          <FileText className="w-3 h-3" />
                        </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between px-4 py-2 border-t border-border text-xs text-muted-foreground">
          <span>Page {page + 1} of {totalPages}</span>
          <div className="flex gap-1">
            <Button variant="ghost" size="icon" className="h-6 w-6" disabled={page === 0} onClick={() => setPage(p => p - 1)}>
              <ChevronLeft className="w-3.5 h-3.5" />
            </Button>
            <Button variant="ghost" size="icon" className="h-6 w-6" disabled={page >= totalPages - 1} onClick={() => setPage(p => p + 1)}>
              <ChevronRight className="w-3.5 h-3.5" />
            </Button>
          </div>
        </div>
      )}
    </div>
  );

  // ── Column 2: Job detail with tabs ──
  const logs = activeJob?.logs || [];
  const detailColumn = activeJob ? (
    <div className="flex flex-col h-full">
      {/* Job info header — compact by default, expandable */}
      <div className="border-b border-border">
        {/* Always visible: compact summary line */}
        <button
          className="w-full flex items-center gap-2 px-4 py-2 text-left hover:bg-muted/30 transition-colors"
          onClick={() => setHeaderExpanded(h => !h)}
        >
          <Badge variant="outline" className={`${statusColor(activeJob.status)} shrink-0`}>{activeJob.status}</Badge>
          <span className="font-mono text-xs text-muted-foreground shrink-0">#{activeJob.id}</span>
          {activeJob.action && <Badge variant="secondary" className="text-[10px] shrink-0">{activeJob.action}</Badge>}
          <span className="text-xs font-medium truncate flex-1">
            {activeJob.task_title || `${activeJob.org}/${activeJob.repo}`}
          </span>
          {activeJob.progress && (
            <Badge variant="outline" className="text-[10px] shrink-0">
              {activeJob.progress.percent}%
            </Badge>
          )}
          {headerExpanded ? <ChevronUp className="w-3.5 h-3.5 shrink-0 text-muted-foreground" /> : <ChevronDown className="w-3.5 h-3.5 shrink-0 text-muted-foreground" />}
        </button>

        {/* Expandable details */}
        {headerExpanded && (
          <div className="px-4 pb-3 space-y-2">
            {activeJob.task_title && (
              <h2 className="text-sm font-semibold leading-tight">{activeJob.task_title}</h2>
            )}
            <div className="text-sm">
              <span className="font-medium">{activeJob.org}/{activeJob.repo}</span>
              <span className="text-muted-foreground ml-2">· {activeJob.device} · {activeJob.cli}</span>
            </div>
            {activeJob.branch && (
              <p className="text-xs font-mono text-muted-foreground">Branch: {activeJob.branch}</p>
            )}
            {activeJob.tmux_session && (
              <p className="text-xs text-muted-foreground">Session: {activeJob.tmux_session}</p>
            )}
            {activeJob.error && (
              <div className="bg-red-500/10 border border-red-500/30 rounded-lg p-2 text-sm text-red-400">{activeJob.error}</div>
            )}
            <div className="flex gap-2 flex-wrap">
              {!activeJob.vt_url && activeJob.status === 'running' && (
                <Button size="sm" variant="outline" className="gap-1 h-7 text-xs" onClick={() => attachVT(activeJob.id)}>
                  <Plug className="w-3 h-3" /> Attach VT
                </Button>
              )}
              {activeJob.agent_prompt ? (
                <Button size="sm" className="gap-1 h-7 text-xs" onClick={() => {
                  const text = activeJob.agent_prompt!;
                  if (navigator.clipboard?.writeText) {
                    navigator.clipboard.writeText(text).catch(() => {});
                  }
                }}>
                  <ClipboardCheck className="w-3 h-3" /> Copy Prompt
                </Button>
              ) : (
                <Button size="sm" variant="outline" className="gap-1 h-7 text-xs opacity-50" disabled>
                  <ClipboardCheck className="w-3 h-3" /> No Prompt
                </Button>
              )}
              {activeJob.connect_cmd && (
                <Button size="sm" variant="outline" className="gap-1 h-7 text-xs" onClick={() => {
                  const text = activeJob.connect_cmd!;
                  if (navigator.clipboard?.writeText) {
                    navigator.clipboard.writeText(text).catch(() => {
                      const ta = document.createElement('textarea');
                      ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
                      document.body.appendChild(ta); ta.select();
                      document.execCommand('copy'); document.body.removeChild(ta);
                    });
                  } else {
                    const ta = document.createElement('textarea');
                    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
                    document.body.appendChild(ta); ta.select();
                    document.execCommand('copy'); document.body.removeChild(ta);
                  }
                }}>
                  <Copy className="w-3 h-3" /> Copy SSH
                </Button>
              )}
              {activeJob.status === 'running' && (
                <Button size="sm" variant="destructive" className="gap-1 h-7 text-xs" onClick={() => killJob(activeJob.id)}>
                  <Square className="w-3 h-3" /> Kill
                </Button>
              )}
              <Button size="sm" variant="ghost" className="gap-1 h-7 text-xs" onClick={() => refreshJobDetail(activeJob.id)}>
                <RotateCw className="w-3 h-3" /> Refresh
              </Button>
            </div>
          </div>
        )}
      </div>

      {/* Tab bar */}
      <div className="flex border-b border-border">
        <button
          className={`flex items-center gap-1.5 px-4 py-2 text-xs font-medium border-b-2 transition-colors ${
            detailTab === 'logs' ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
          onClick={() => setDetailTab('logs')}
        >
          <ScrollText className="w-3.5 h-3.5" /> Logs ({logs.length})
        </button>
        <button
          className={`flex items-center gap-1.5 px-4 py-2 text-xs font-medium border-b-2 transition-colors ${
            detailTab === 'worktree' ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
          onClick={switchToWorktreeTab}
        >
          <FileText className="w-3.5 h-3.5" /> WORKTREE.md
        </button>
        {activeJob?.tmux_session && (
          <button
            className={`flex items-center gap-1.5 px-4 py-2 text-xs font-medium border-b-2 transition-colors ${
              detailTab === 'interact' ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
            onClick={() => {
              setDetailTab('interact');
              // Fetch initial tmux capture
              if (activeJob) {
                api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${activeJob.id}/tmux-capture`, device))
                  .then(r => { if (r.ok) setTmuxOutput(r.output); })
                  .catch(() => {});
              }
            }}
          >
            <MessageSquare className="w-3.5 h-3.5" /> Interact
          </button>
        )}
      </div>

      {/* Tab content */}
      {detailTab === 'logs' ? (
        <div className="flex-1 overflow-auto bg-zinc-950 font-mono text-xs">
          {logs.length === 0 ? (
            <div className="p-4 text-zinc-500 text-center">No log entries recorded</div>
          ) : (
            <div className="p-2 space-y-px">
              {logs.map(entry => (
                <div key={entry.id} className="flex gap-2 py-0.5 px-1 rounded hover:bg-zinc-900/50">
                  <span className="text-zinc-600 shrink-0 tabular-nums">
                    {new Date(entry.timestamp).toLocaleTimeString()}
                  </span>
                  <span className={`whitespace-pre-wrap break-all ${logLineColor(entry.line)}`}>
                    {entry.line}
                  </span>
                </div>
              ))}
              <div ref={logEndRef} />
            </div>
          )}
        </div>
      ) : detailTab === 'interact' ? (
        <div className="flex-1 flex flex-col overflow-hidden">
          {/* Tmux pane capture — takes all remaining space */}
          <div className="flex-1 overflow-auto bg-zinc-950 font-mono text-xs min-h-0 relative">
            <button className="sticky top-0 float-right z-10 p-1 rounded bg-zinc-800/80 hover:bg-zinc-700 text-zinc-400 hover:text-zinc-200 transition-colors" title="Refresh" onClick={() => {
              if (activeJob) {
                api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${activeJob.id}/tmux-capture`, device))
                  .then(r => { if (r.ok) { setTmuxOutput(r.output); captureRef.current?.scrollIntoView({ block: 'end' }); } })
                  .catch(() => {});
              }
            }}>
              <RotateCw className="w-3.5 h-3.5" />
            </button>
            {tmuxOutput ? (
              <pre ref={captureRef} className="whitespace-pre-wrap text-zinc-300">{tmuxOutput}</pre>
            ) : (
              <div className="text-zinc-500 text-center py-8">No terminal output captured. Tap Refresh to load.</div>
            )}
          </div>
          {/* Termux-style extra keys — two compact rows */}
          <div className="shrink-0 border-t border-zinc-800 bg-zinc-900">
            {[
              [
                { label: 'ESC', keys: 'Escape' },
                { label: '⏎', keys: 'Enter' },
                { label: 'Ctrl+C', keys: 'C-c' },
                { label: 'Ctrl+Z', keys: 'C-z' },
                { label: 'HOME', keys: 'Home' },
                { label: '↑', keys: 'Up' },
                { label: 'END', keys: 'End' },
              ],
              [
                { label: 'TAB', keys: 'Tab' },
                { label: ctrlMode ? 'CTRL+?' : 'CTRL', keys: '__ctrl__' },
                { label: 'Ctrl+L', keys: 'C-l' },
                { label: 'Ctrl+B', keys: '__tmux__' },
                { label: '←', keys: 'Left' },
                { label: '↓', keys: 'Down' },
                { label: '→', keys: 'Right' },
              ],
            ].map((row, ri) => (
              <div key={ri} className="flex border-b border-zinc-800 last:border-b-0">
                {row.map((k, ci) => (
                  <button
                    key={`${ri}-${ci}`}
                    className={`flex-1 py-2 text-[11px] font-medium transition-colors border-r border-zinc-800 last:border-r-0 select-none ${
                      k.keys === '__ctrl__' && ctrlMode
                        ? 'bg-blue-600 text-white'
                        : k.keys === '__tmux__' && tmuxMode
                          ? 'bg-green-600 text-white'
                          : 'text-zinc-300 hover:bg-zinc-700 active:bg-zinc-600'
                    }`}
                    onClick={() => {
                      if (!activeJob) return;
                      if (k.keys === '__ctrl__') {
                        setCtrlMode(prev => !prev);
                        setTmuxMode(false);
                        return;
                      }
                      if (k.keys === '__tmux__') {
                        // Send C-b immediately, then wait for next key
                        api(appendDevice(`/jobs/${activeJob.id}/send-special-key`, device), {
                          method: 'POST',
                          body: JSON.stringify({ device: device || '', session: activeJob.tmux_session || '', keys: 'C-b' }),
                        }).catch(() => {});
                        setTmuxMode(prev => !prev);
                        setCtrlMode(false);
                        return;
                      }
                      let keyToSend = k.keys;
                      if (ctrlMode && k.keys.length === 1) {
                        keyToSend = `C-${k.keys.toLowerCase()}`;
                        setCtrlMode(false);
                      } else if (ctrlMode) {
                        setCtrlMode(false);
                      }
                      if (tmuxMode) {
                        setTmuxMode(false);
                      }
                      api(appendDevice(`/jobs/${activeJob.id}/send-special-key`, device), {
                        method: 'POST',
                        body: JSON.stringify({ device: device || '', session: activeJob.tmux_session || '', keys: keyToSend }),
                      }).then(() => {
                        setTimeout(() => {
                          api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${activeJob.id}/tmux-capture`, device))
                            .then(r => { if (r.ok) setTmuxOutput(r.output); })
                            .catch(() => {});
                        }, 400);
                      }).catch(() => {});
                    }}
                  >{k.label}</button>
                ))}
              </div>
            ))}
          </div>
          {/* Message input + refresh — pinned above bottom nav */}
          <div className="shrink-0 border-t border-zinc-800 bg-zinc-900 pb-1 md:pb-1 pt-1.5 px-2">
            <div className="flex items-center gap-2">
              <input
                type="text"
                className="flex-1 h-10 md:h-8 text-sm bg-background border border-border rounded-lg px-3 text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-primary"
                placeholder="Send message to agent..."
                value={interactMsg}
                onChange={e => setInteractMsg(e.target.value)}
                onKeyDown={e => {
                  if (e.key === 'Enter' && !e.shiftKey && interactMsg.trim() && activeJob) {
                    e.preventDefault();
                    setSendingMsg(true);
                    api(appendDevice(`/jobs/${activeJob.id}/send-keys`, device), {
                      method: 'POST',
                      body: JSON.stringify({ device: device || '', session: activeJob.tmux_session || '', keys: interactMsg }),
                    }).then(() => {
                      setInteractMsg('');
                      setTimeout(() => {
                        api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${activeJob.id}/tmux-capture`, device))
                          .then(r => { if (r.ok) setTmuxOutput(r.output); })
                          .catch(() => {});
                      }, 2000);
                    }).catch(() => {}).finally(() => setSendingMsg(false));
                  }
                }}
                disabled={sendingMsg}
              />
              <Button size="sm" className="h-10 md:h-8 px-4 gap-1.5 shrink-0" disabled={sendingMsg || !interactMsg.trim()}
                onClick={() => {
                  if (!interactMsg.trim() || !activeJob) return;
                  setSendingMsg(true);
                  api(appendDevice(`/jobs/${activeJob.id}/send-keys`, device), {
                    method: 'POST',
                    body: JSON.stringify({ device: device || '', session: activeJob.tmux_session || '', keys: interactMsg }),
                  }).then(() => {
                    setInteractMsg('');
                    setTimeout(() => {
                      api<{ ok: boolean; output: string }>(appendDevice(`/jobs/${activeJob.id}/tmux-capture`, device))
                        .then(r => { if (r.ok) setTmuxOutput(r.output); })
                        .catch(() => {});
                    }, 2000);
                  }).catch(() => {}).finally(() => setSendingMsg(false));
                }}>
                <Send className="w-4 h-4" /> <span className="hidden sm:inline">Send</span>
              </Button>
            </div>
          </div>
        </div>
      ) : (
        <div className="flex-1 overflow-auto p-4">
          {loadingWt ? (
            <div className="text-center text-muted-foreground py-8">Loading WORKTREE.md…</div>
          ) : worktreeMd ? (
            <pre className="text-sm whitespace-pre-wrap font-sans leading-relaxed bg-muted/30 rounded-lg p-4">{worktreeMd}</pre>
          ) : (
            <div className="text-center text-muted-foreground py-8">
              <FileText className="w-6 h-6 mx-auto mb-2 opacity-50" />
              <p className="text-sm">No WORKTREE.md content available</p>
            </div>
          )}
        </div>
      )}
    </div>
  ) : null;

  const columns: { key: string; title?: string; content: React.ReactNode; width: string }[] = [{ key: 'list', content: listColumn, width: '1fr' }];
  if (activeJob && detailColumn) {
    columns.push({ key: 'detail', title: `Job #${activeJob.id}`, content: detailColumn, width: '480px' });
  }

  return (
    <div className="h-full">
      <ColumnView columns={columns} onBack={() => setActiveJob(null)} />
    </div>
  );
}
