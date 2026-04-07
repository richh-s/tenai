import { useEffect, useState, useCallback } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {
  ListTodo,
  Search,
  RotateCw,
  Play,
  Trash2,
  MoreVertical,
  ChevronLeft,
  ChevronRight,
  Filter,
  X,
  GitBranch,
  Clock,
  CheckCircle2,
  Circle,
  AlertCircle,
  Loader2,
  Copy,
  Plus,
  FileText,
  ChevronDown,
} from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import { ColumnView } from '@/components/column-view';
import { api, appendDevice, type Task, type Subtask } from '@/lib/api';
import { useApp } from '@/lib/store';

const STATUS_FILTERS = [
  { value: '', label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'dispatched', label: 'Dispatched' },
  { value: 'running', label: 'Running' },
  { value: 'done', label: 'Done' },
  { value: 'failed', label: 'Failed' },
];

function statusColor(s: string) {
  const m: Record<string, string> = {
    active: 'bg-emerald-500/15 text-emerald-400 border-emerald-500/30',
    dispatched: 'bg-blue-500/15 text-blue-400 border-blue-500/30',
    running: 'bg-yellow-500/15 text-yellow-400 border-yellow-500/30',
    done: 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30',
    failed: 'bg-red-500/15 text-red-400 border-red-500/30',
    pending: 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30',
    in_progress: 'bg-yellow-500/15 text-yellow-400 border-yellow-500/30',
    completed: 'bg-emerald-500/15 text-emerald-400 border-emerald-500/30',
  };
  return m[s] || 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30';
}

function subtaskIcon(s: string) {
  if (s === 'completed' || s === 'done') return <CheckCircle2 className="w-3.5 h-3.5 text-emerald-400" />;
  if (s === 'in_progress' || s === 'running') return <Loader2 className="w-3.5 h-3.5 text-yellow-400 animate-spin" />;
  if (s === 'failed') return <AlertCircle className="w-3.5 h-3.5 text-red-400" />;
  return <Circle className="w-3.5 h-3.5 text-zinc-500" />;
}

export default function Tasks() {
  const { device, cli, devices } = useApp();
  const [tasks, setTasks] = useState<Task[]>([]);
  const [repos, setRepos] = useState<string[]>([]);
  const [repo, setRepo] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(0);
  const [total, setTotal] = useState(0);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [activeTask, setActiveTask] = useState<Task | null>(null);
  const [subtasks, setSubtasks] = useState<Subtask[]>([]);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [toast, setToast] = useState<{ msg: string; type: 'ok' | 'warn' | 'err' } | null>(null);
  const [dispatching, setDispatching] = useState(false);
  const [newTaskOpen, setNewTaskOpen] = useState(false);
  const perPage = 20;

  const showToast = (msg: string, type: 'ok' | 'warn' | 'err' = 'ok') => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 5000);
  };

  const loadRepos = useCallback(() => {
    api<{ repos: string[] }>(appendDevice('/task-db/repos', device))
      .then(r => setRepos(r.repos || []))
      .catch(() => {});
  }, [device]);

  const loadTasks = useCallback(() => {
    const params = new URLSearchParams();
    if (repo) params.set('repo', repo);
    if (statusFilter) params.set('status', statusFilter);
    if (search) params.set('pattern', search);
    params.set('limit', String(perPage));
    params.set('offset', String(page * perPage));
    if (device) params.set('device', device);
    api<{ tasks: Task[]; total: number }>(`/task-db?${params}`)
      .then(r => { setTasks(r.tasks || []); setTotal(r.total || 0); })
      .catch(() => {});
  }, [repo, statusFilter, search, page, device]);

  useEffect(() => { loadRepos(); }, [loadRepos]);
  useEffect(() => { loadTasks(); }, [loadTasks]);

  const toggle = (id: number) => {
    setSelected(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const dispatch = async (taskItems: Task[]) => {
    if (dispatching) return;
    setDispatching(true);
    const onlineDevice = devices.find(d => d.online) || devices[0];
    if (!onlineDevice) { showToast('No online device found', 'err'); return; }
    const devName = device || onlineDevice.name;
    let ok = 0, fail = 0, alreadyRunning = 0;
    const results: string[] = [];
    for (const t of taskItems) {
      if (!t.branch) { fail++; results.push(`#${t.id}: no branch`); continue; }
      if (!t.org) { fail++; results.push(`#${t.id}: no org`); continue; }
      try {
        const r = await api<{ job_id?: number; already_running?: boolean; message?: string }>(appendDevice('/jobs', device), {
          method: 'POST',
          body: JSON.stringify({
            device: devName, org: t.org, repo: t.repo, cli,
            action: 'dispatch', branch: t.branch,
            task: t.description || t.title,
            task_id: t.id,
          }),
        });
        if (r.already_running) {
          alreadyRunning++;
          results.push(`#${t.id}: already running (job ${r.job_id})`);
        } else {
          ok++;
          results.push(`#${t.id}: dispatched → job ${r.job_id}`);
        }
        await api(appendDevice(`/task-db/${t.id}`, device), {
          method: 'PATCH',
          body: JSON.stringify({ status: 'dispatched' }),
        }).catch(() => {});
      } catch { fail++; results.push(`#${t.id}: failed`); }
    }
    setDispatching(false);
    setSelected(new Set());
    loadTasks();
    // Show summary toast
    const parts: string[] = [];
    if (ok > 0) parts.push(`${ok} dispatched`);
    if (alreadyRunning > 0) parts.push(`${alreadyRunning} already running`);
    if (fail > 0) parts.push(`${fail} failed`);
    const type = fail > 0 ? 'err' : alreadyRunning > 0 ? 'warn' : 'ok';
    showToast(parts.join(', ') + (taskItems.length === 1 && results[0] ? ` — ${results[0]}` : ''), type);
  };

  const deleteTask = async (id: number) => {
    if (!confirm('Delete this task? Associated jobs will NOT be deleted but will be unlinked.')) return;
    await api(appendDevice(`/task-db/${id}`, device), { method: 'DELETE' }).catch(() => {});
    if (activeTask?.id === id) setActiveTask(null);
    loadTasks();
    showToast('Task deleted', 'ok');
  };

  const duplicateTask = async (id: number) => {
    try {
      const r = await api<{ new_task_id: number }>(appendDevice(`/task-db/${id}/duplicate`, device), { method: 'POST', body: JSON.stringify({}) });
      loadTasks();
      showToast(`Task duplicated as #${r.new_task_id}`, 'ok');
    } catch { showToast('Failed to duplicate task', 'err'); }
  };

  const bulkDelete = async () => {
    const count = selected.size;
    if (!confirm(`Delete ${count} task(s)? Their subtasks will also be deleted. Associated jobs will be unlinked.`)) return;
    await api(appendDevice('/task-db/bulk-delete', device), {
      method: 'POST',
      body: JSON.stringify({ task_ids: Array.from(selected) }),
    }).catch(() => {});
    setSelected(new Set());
    if (activeTask && selected.has(activeTask.id)) setActiveTask(null);
    loadTasks();
    showToast(`${count} task(s) deleted`, 'ok');
  };

  const openTaskDetail = async (t: Task) => {
    setActiveTask(t);
    setSubtasks([]);
    try {
      const r = await api<{ subtasks: Subtask[] }>(appendDevice(`/task-db/${t.id}/subtasks`, device));
      setSubtasks(r.subtasks || []);
    } catch { /* no subtasks */ }
  };

  const generateSubtasks = async (taskId: number) => {
    showToast('Generating subtasks via LLM...', 'ok');
    try {
      const r = await api<{ subtasks: Subtask[]; count: number }>(appendDevice(`/task-db/${taskId}/generate-subtasks`, device), {
        method: 'POST',
        body: JSON.stringify({}),
      });
      setSubtasks(r.subtasks || []);
      showToast(`Generated ${r.count} subtask(s)`, 'ok');
    } catch {
      showToast('Subtask generation failed — check API key', 'err');
    }
  };

  const maxPage = Math.max(0, Math.ceil(total / perPage) - 1);

  // ── Column 1: Task list ──
  const listColumn = (
    <div className="flex flex-col h-full">
      <div className="flex items-center gap-2 px-4 pt-4 pb-2">
        <ListTodo className="w-5 h-5" />
        <h1 className="text-lg font-bold flex-1">Tasks</h1>
        <span className="text-xs text-muted-foreground">{total} total</span>
        <Button variant="default" size="sm" className="h-7 text-xs gap-1" onClick={() => setNewTaskOpen(true)}>
          <Plus className="w-3.5 h-3.5" /> New Task
        </Button>
        <Button variant="ghost" size="icon" onClick={loadTasks}><RotateCw className="w-4 h-4" /></Button>
        <Button variant="ghost" size="icon" className="md:hidden" onClick={() => setFiltersOpen(!filtersOpen)}>
          {filtersOpen ? <X className="w-4 h-4" /> : <Filter className="w-4 h-4" />}
        </Button>
      </div>

      {toast && (
        <div className={`mx-4 mb-2 px-3 py-2 rounded-lg text-xs flex items-center gap-2 animate-in fade-in slide-in-from-top-1 ${
          toast.type === 'ok' ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30' :
          toast.type === 'warn' ? 'bg-yellow-500/15 text-yellow-400 border border-yellow-500/30' :
          'bg-red-500/15 text-red-400 border border-red-500/30'
        }`}>
          <span className="flex-1">{toast.msg}</span>
          <button onClick={() => setToast(null)} className="shrink-0 opacity-60 hover:opacity-100">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      <div className={`px-4 pb-2 space-y-2 ${filtersOpen ? '' : 'hidden md:block'}`}>
        <div className="flex gap-2 flex-wrap">
          <Select value={repo || '__all__'} onValueChange={v => { setRepo(v === '__all__' ? '' : v); setPage(0); }}>
            <SelectTrigger className="h-8 w-40 text-xs"><SelectValue placeholder="All repos" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="__all__">All repos</SelectItem>
              {repos.map(r => <SelectItem key={r} value={r}>{r}</SelectItem>)}
            </SelectContent>
          </Select>
          <div className="relative flex-1 min-w-[140px]">
            <Search className="absolute left-2 top-2 w-3.5 h-3.5 text-muted-foreground" />
            <Input value={search} onChange={e => { setSearch(e.target.value); setPage(0); }} placeholder="Search…" className="h-8 pl-7 text-xs" />
          </div>
        </div>
        <div className="flex gap-1.5 flex-wrap">
          {STATUS_FILTERS.map(f => (
            <Button key={f.value} variant={statusFilter === f.value ? 'default' : 'outline'} size="sm"
              className="h-6 text-xs px-2" onClick={() => { setStatusFilter(f.value); setPage(0); }}>
              {f.label}
            </Button>
          ))}
        </div>
      </div>

      {selected.size > 0 && (
        <div className="px-4 pb-2 flex items-center gap-2">
          <Badge variant="secondary">{selected.size} selected</Badge>
          <Button size="sm" onClick={() => dispatch(tasks.filter(t => selected.has(t.id)))} disabled={dispatching} className="h-7 text-xs gap-1">
            {dispatching ? <Loader2 className="w-3 h-3 animate-spin" /> : <Play className="w-3 h-3" />} {dispatching ? 'Dispatching…' : `Dispatch (${cli})`}
          </Button>
          <Button size="sm" variant="destructive" onClick={bulkDelete} className="h-7 text-xs gap-1">
            <Trash2 className="w-3 h-3" /> Delete ({selected.size})
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setSelected(new Set())} className="h-7 text-xs">Clear</Button>
        </div>
      )}

      <div className="flex-1 overflow-auto px-4">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-8">
                <input type="checkbox" className="rounded" checked={selected.size > 0 && selected.size === tasks.length}
                  onChange={e => { if (e.target.checked) setSelected(new Set(tasks.map(t => t.id))); else setSelected(new Set()); }} />
              </TableHead>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Title</TableHead>
              <TableHead className="hidden lg:table-cell">Repo</TableHead>
              <TableHead className="hidden lg:table-cell">Branch</TableHead>
              <TableHead className="w-10" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {tasks.length === 0 ? (
              <TableRow><TableCell colSpan={7} className="text-center text-muted-foreground py-12">No tasks found</TableCell></TableRow>
            ) : tasks.map(t => (
              <TableRow key={t.id} className={`cursor-pointer ${activeTask?.id === t.id ? 'bg-accent' : ''}`}
                onClick={() => openTaskDetail(t)}>
                <TableCell onClick={e => e.stopPropagation()}>
                  <input type="checkbox" className="rounded" checked={selected.has(t.id)} onChange={() => toggle(t.id)} />
                </TableCell>
                <TableCell className="font-mono text-xs">{t.id}</TableCell>
                <TableCell><Badge variant="outline" className={`text-[10px] ${statusColor(t.status)}`}>{t.status}</Badge></TableCell>
                <TableCell className="max-w-[200px] truncate text-sm">{t.title}</TableCell>
                <TableCell className="hidden lg:table-cell text-xs text-muted-foreground">{t.org ? `${t.org}/` : ''}{t.repo || '—'}</TableCell>
                <TableCell className="hidden lg:table-cell text-xs text-muted-foreground font-mono">{t.branch || '—'}</TableCell>
                <TableCell onClick={e => e.stopPropagation()}>
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild><Button variant="ghost" size="icon" className="h-7 w-7"><MoreVertical className="w-3.5 h-3.5" /></Button></DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem disabled={dispatching} onClick={() => dispatch([t])}>
                        {dispatching ? <Loader2 className="w-3.5 h-3.5 mr-2 animate-spin" /> : <Play className="w-3.5 h-3.5 mr-2" />}
                        {dispatching ? 'Dispatching…' : 'Dispatch'}
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => duplicateTask(t.id)}><Copy className="w-3.5 h-3.5 mr-2" /> Duplicate</DropdownMenuItem>
                      <DropdownMenuItem className="text-destructive" onClick={() => deleteTask(t.id)}><Trash2 className="w-3.5 h-3.5 mr-2" /> Delete</DropdownMenuItem>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <div className="flex items-center justify-between px-4 py-2 border-t border-border text-xs text-muted-foreground">
        <span>{total} task{total !== 1 ? 's' : ''}</span>
        <div className="flex items-center gap-1">
          <Button variant="ghost" size="icon" className="h-7 w-7" disabled={page === 0} onClick={() => setPage(p => p - 1)}>
            <ChevronLeft className="w-4 h-4" />
          </Button>
          <span>Page {page + 1}/{maxPage + 1}</span>
          <Button variant="ghost" size="icon" className="h-7 w-7" disabled={page >= maxPage} onClick={() => setPage(p => p + 1)}>
            <ChevronRight className="w-4 h-4" />
          </Button>
        </div>
      </div>
    </div>
  );

  // ── Column 2: Task Detail + Subtasks ──
  const detailColumn = activeTask ? (
    <div className="flex flex-col h-full overflow-y-auto">
      <div className="p-4 space-y-4">
        {/* Task header */}
        <div>
          <div className="flex items-center gap-2 mb-1">
            <Badge variant="outline" className={statusColor(activeTask.status)}>{activeTask.status}</Badge>
            <span className="text-xs text-muted-foreground font-mono">#{activeTask.id}</span>
          </div>
          <h2 className="text-base font-semibold">{activeTask.title}</h2>
        </div>

        {/* Metadata grid */}
        <div className="grid grid-cols-2 gap-3 text-sm">
          <div>
            <p className="text-xs text-muted-foreground">Repo</p>
            <p>{activeTask.org ? `${activeTask.org}/` : ''}{activeTask.repo || '—'}</p>
          </div>
          {activeTask.branch && (
            <div>
              <p className="text-xs text-muted-foreground">Branch</p>
              <p className="font-mono text-xs flex items-center gap-1"><GitBranch className="w-3 h-3" />{activeTask.branch}</p>
            </div>
          )}
          {activeTask.base_branch && (
            <div>
              <p className="text-xs text-muted-foreground">Base Branch</p>
              <p className="font-mono text-xs">{activeTask.base_branch}</p>
            </div>
          )}
          {activeTask.cli && (
            <div>
              <p className="text-xs text-muted-foreground">CLI</p>
              <p>{activeTask.cli}</p>
            </div>
          )}
          {activeTask.created_at && (
            <div>
              <p className="text-xs text-muted-foreground">Created</p>
              <p className="flex items-center gap-1"><Clock className="w-3 h-3" />{new Date(activeTask.created_at).toLocaleDateString()}</p>
            </div>
          )}
        </div>

        {/* Instruction (unfolded by default) */}
        {activeTask.instruction && (
          <div>
            <p className="text-xs text-muted-foreground mb-1 flex items-center gap-1"><FileText className="w-3 h-3" /> Instruction</p>
            <pre className="text-sm whitespace-pre-wrap bg-muted/50 rounded-lg p-3 font-sans leading-relaxed max-h-[300px] overflow-y-auto">{activeTask.instruction}</pre>
          </div>
        )}

        {/* Description (folded by default, only if different from instruction) */}
        {activeTask.description && activeTask.description !== activeTask.instruction && (
          <details className="group">
            <summary className="text-xs text-muted-foreground cursor-pointer flex items-center gap-1 mb-1">
              <ChevronDown className="w-3 h-3 transition-transform group-open:rotate-180" />
              Description (human context)
            </summary>
            <pre className="text-sm whitespace-pre-wrap bg-muted/50 rounded-lg p-3 font-sans leading-relaxed max-h-[200px] overflow-y-auto mt-1">{activeTask.description}</pre>
          </details>
        )}

        {/* Plan / Spec documents */}
        {(activeTask.plan_document || activeTask.spec_document) && (
          <div className="flex gap-2 flex-wrap">
            {activeTask.plan_document && (
              <Badge variant="outline" className="text-[10px] gap-1"><FileText className="w-3 h-3" /> {activeTask.plan_document}</Badge>
            )}
            {activeTask.spec_document && (
              <Badge variant="outline" className="text-[10px] gap-1"><FileText className="w-3 h-3" /> {activeTask.spec_document}</Badge>
            )}
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-2 flex-wrap">
          <Button size="sm" onClick={() => { dispatch([activeTask]); }} className="gap-1">
            <Play className="w-3.5 h-3.5" /> Dispatch ({cli})
          </Button>
          <Button size="sm" variant="outline" onClick={() => duplicateTask(activeTask.id)} className="gap-1">
            <Copy className="w-3.5 h-3.5" /> Save as New
          </Button>
          <Button size="sm" variant="destructive" onClick={() => deleteTask(activeTask.id)}>
            <Trash2 className="w-3.5 h-3.5" />
          </Button>
        </div>

        {/* ── Subtasks section ── */}
        <div className="border-t border-border pt-4">
          <h3 className="text-sm font-medium mb-3 flex items-center gap-2">
            <CheckCircle2 className="w-4 h-4" />
            Subtasks ({subtasks.length})
            <Button size="sm" variant="outline" className="ml-auto h-6 text-[10px] gap-1"
              onClick={() => generateSubtasks(activeTask.id)}>
              <Plus className="w-3 h-3" /> Generate
            </Button>
          </h3>
          {subtasks.length === 0 ? (
            <p className="text-xs text-muted-foreground">No subtasks for this task</p>
          ) : (
            <div className="space-y-1.5">
              {subtasks.map(s => (
                <div key={s.id} className="flex items-start gap-2 p-2.5 rounded-lg bg-muted/30 hover:bg-muted/50 transition-colors">
                  {subtaskIcon(s.status)}
                  <div className="flex-1 min-w-0">
                    <p className="text-sm leading-tight">{s.title}</p>
                    <div className="flex items-center gap-2 mt-0.5">
                      {s.phase && <span className="text-[10px] text-muted-foreground">{s.phase}</span>}
                      <Badge variant="outline" className={`text-[9px] py-0 ${statusColor(s.status)}`}>{s.status}</Badge>
                    </div>
                    {s.evidence && (
                      <p className="text-xs text-muted-foreground mt-1 italic">{s.evidence}</p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  ) : null;

  // Build columns array
  const columns: { key: string; title?: string; content: React.ReactNode; width: string }[] = [{ key: 'list', content: listColumn, width: '1fr' }];
  if (activeTask && detailColumn) {
    columns.push({ key: 'detail', title: `Task #${activeTask.id}`, content: detailColumn, width: '420px' });
  }

  return (
    <div className="h-full">
      <ColumnView columns={columns} onBack={() => setActiveTask(null)} />
      <NewTaskDialog
        open={newTaskOpen}
        onOpenChange={setNewTaskOpen}
        device={device}
        onCreated={(id) => {
          showToast(`Task #${id} created`, 'ok');
          loadTasks();
        }}
      />
    </div>
  );
}

// ── New Task Dialog ──────────────────────────────────────────────────────────

const CONTEXT_TYPES = [
  { value: 'inline', label: 'Inline / Adhoc', hint: 'Simple task — all context in description' },
  { value: 'conductor', label: 'Conductor Track', hint: 'References plan.md and spec.md in a conductor track' },
  { value: 'github', label: 'GitHub Issue', hint: 'Task sourced from a GitHub issue' },
  { value: 'ai-dlc', label: 'AI-DLC', hint: 'AI Development Lifecycle measurement task' },
];

function NewTaskDialog({
  open, onOpenChange, device, onCreated,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  device: string;
  onCreated: (id: number) => void;
}) {
  const [contextType, setContextType] = useState('inline');
  const [title, setTitle] = useState('');
  const [selectedOrg, setSelectedOrg] = useState('');
  const [selectedRepo, setSelectedRepo] = useState('');
  const [orgs, setOrgs] = useState<{ name: string }[]>([]);
  const [orgRepos, setOrgRepos] = useState<{ name: string }[]>([]);
  const [loadingRepos, setLoadingRepos] = useState(false);
  const [description, setDescription] = useState('');
  const [verification, setVerification] = useState('');
  const [contextRef, setContextRef] = useState('');
  const [planDocument, setPlanDocument] = useState('');
  const [specDocument, setSpecDocument] = useState('');
  const [conductorTrack, setConductorTrack] = useState('');
  const [timelimit, setTimelimit] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');

  // Load orgs when dialog opens
  useEffect(() => {
    if (open) {
      api<{ orgs: { name: string }[] }>(appendDevice('/orgs', device))
        .then(r => setOrgs(r.orgs || []))
        .catch(() => {});
    }
  }, [open, device]);

  // Load repos when org changes
  useEffect(() => {
    if (!selectedOrg) { setOrgRepos([]); return; }
    setLoadingRepos(true);
    setSelectedRepo('');
    api<{ repos: { name: string }[] }>(appendDevice(`/orgs/${selectedOrg}/repos`, device))
      .then(r => setOrgRepos(r.repos || []))
      .catch(() => setOrgRepos([]))
      .finally(() => setLoadingRepos(false));
  }, [selectedOrg, device]);

  const resetForm = () => {
    setContextType('inline'); setTitle(''); setSelectedOrg(''); setSelectedRepo('');
    setDescription(''); setVerification('');
    setContextRef(''); setPlanDocument(''); setSpecDocument(''); setConductorTrack('');
    setTimelimit(''); setError('');
  };

  const handleContextTypeChange = (ct: string) => {
    setContextType(ct);
    if (ct === 'conductor' && conductorTrack) {
      setContextRef(`conductor/tracks/${conductorTrack}`);
      setPlanDocument(`conductor/tracks/${conductorTrack}/plan.md`);
      setSpecDocument(`conductor/tracks/${conductorTrack}/spec.md`);
    }
  };

  const handleConductorTrackChange = (track: string) => {
    setConductorTrack(track);
    if (track) {
      setContextRef(`conductor/tracks/${track}`);
      setPlanDocument(`conductor/tracks/${track}/plan.md`);
      setSpecDocument(`conductor/tracks/${track}/spec.md`);
    }
  };

  const submit = async () => {
    if (!title.trim()) { setError('Title is required'); return; }
    if (!selectedOrg.trim()) { setError('Org is required'); return; }
    if (!selectedRepo.trim()) { setError('Repo is required'); return; }
    setSubmitting(true);
    setError('');
    try {
      const body: Record<string, unknown> = {
        org: selectedOrg, repo: selectedRepo, title: title.trim(),
        description, verification,
        context_ref: contextRef, conductor_track: conductorTrack,
        plan_document: planDocument, spec_document: specDocument,
      };
      if (timelimit) body.timelimit = parseInt(timelimit, 10);
      const r = await api<{ ok: boolean; task_id: number }>(appendDevice('/task-db', device), {
        method: 'POST', body: JSON.stringify(body),
      });
      resetForm();
      onOpenChange(false);
      onCreated(r.task_id);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to create task');
    } finally {
      setSubmitting(false);
    }
  };

  const selectedHint = CONTEXT_TYPES.find(c => c.value === contextType)?.hint || '';

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) resetForm(); onOpenChange(v); }}>
      <DialogContent className="sm:max-w-xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Create New Task</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          {error && (
            <div className="px-3 py-2 rounded-lg text-xs bg-red-500/15 text-red-400 border border-red-500/30">
              {error}
            </div>
          )}

          {/* Context Type */}
          <div className="space-y-1.5">
            <Label className="text-xs">Context Type</Label>
            <Select value={contextType} onValueChange={handleContextTypeChange}>
              <SelectTrigger className="h-8 text-xs">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CONTEXT_TYPES.map(ct => (
                  <SelectItem key={ct.value} value={ct.value}>{ct.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-[10px] text-muted-foreground">{selectedHint}</p>
          </div>

          {/* Title */}
          <div className="space-y-1.5">
            <Label className="text-xs">Title *</Label>
            <Input value={title} onChange={e => setTitle(e.target.value)} placeholder="e.g. Fix authentication flow" className="h-8 text-xs" />
          </div>

          {/* Org + Repo + Timelimit */}
          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-1.5">
              <Label className="text-xs">Org *</Label>
              <Select value={selectedOrg || '__pick__'} onValueChange={v => setSelectedOrg(v === '__pick__' ? '' : v)}>
                <SelectTrigger className="h-8 text-xs">
                  <SelectValue placeholder="Select org" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__pick__" disabled>Select org</SelectItem>
                  {orgs.map(o => <SelectItem key={o.name} value={o.name}>{o.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label className="text-xs">Repo *</Label>
              <Select value={selectedRepo || '__pick__'} onValueChange={v => setSelectedRepo(v === '__pick__' ? '' : v)} disabled={!selectedOrg || loadingRepos}>
                <SelectTrigger className="h-8 text-xs">
                  <SelectValue placeholder={loadingRepos ? 'Loading…' : 'Select repo'} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__pick__" disabled>Select repo</SelectItem>
                  {orgRepos.map(r => <SelectItem key={r.name} value={r.name}>{r.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label className="text-xs">Time Limit (min)</Label>
              <Input value={timelimit} onChange={e => setTimelimit(e.target.value)} placeholder="120" type="number" className="h-8 text-xs" />
            </div>
          </div>

          {/* Description */}
          <div className="space-y-1.5">
            <Label className="text-xs">Description</Label>
            <textarea
              value={description}
              onChange={e => setDescription(e.target.value)}
              placeholder={contextType === 'inline' ? 'Describe the task for the agent...' : 'Human-readable context (optional — instruction auto-generated)'}
              className="w-full h-24 rounded-lg border border-input bg-background px-3 py-2 text-xs resize-y focus:outline-none focus:ring-1 focus:ring-ring"
            />
          </div>

          {/* Conductor-specific fields */}
          {contextType === 'conductor' && (
            <div className="space-y-3 p-3 rounded-lg border border-dashed border-blue-500/30 bg-blue-500/5">
              <p className="text-[10px] font-medium text-blue-400">Conductor Track Settings</p>
              <div className="space-y-1.5">
                <Label className="text-xs">Track ID</Label>
                <Input value={conductorTrack} onChange={e => handleConductorTrackChange(e.target.value)}
                  placeholder="e.g. agent_asset_injection_system_20260312" className="h-8 text-xs font-mono" />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label className="text-xs">Plan Document</Label>
                  <Input value={planDocument} onChange={e => setPlanDocument(e.target.value)}
                    placeholder="conductor/tracks/.../plan.md" className="h-8 text-xs font-mono" />
                </div>
                <div className="space-y-1.5">
                  <Label className="text-xs">Spec Document</Label>
                  <Input value={specDocument} onChange={e => setSpecDocument(e.target.value)}
                    placeholder="conductor/tracks/.../spec.md" className="h-8 text-xs font-mono" />
                </div>
              </div>
            </div>
          )}

          {/* GitHub-specific fields */}
          {contextType === 'github' && (
            <div className="space-y-3 p-3 rounded-lg border border-dashed border-purple-500/30 bg-purple-500/5">
              <p className="text-[10px] font-medium text-purple-400">GitHub Issue</p>
              <div className="space-y-1.5">
                <Label className="text-xs">Issue Reference</Label>
                <Input value={contextRef} onChange={e => setContextRef(e.target.value)}
                  placeholder="org/repo#123" className="h-8 text-xs font-mono" />
              </div>
            </div>
          )}

          {/* AI-DLC specific fields */}
          {contextType === 'ai-dlc' && (
            <div className="space-y-3 p-3 rounded-lg border border-dashed border-amber-500/30 bg-amber-500/5">
              <p className="text-[10px] font-medium text-amber-400">AI-DLC Plan</p>
              <div className="space-y-1.5">
                <Label className="text-xs">Plan Document Path</Label>
                <Input value={planDocument} onChange={e => setPlanDocument(e.target.value)}
                  placeholder="docs/plans/ai_dlc_kpi.md" className="h-8 text-xs font-mono" />
              </div>
            </div>
          )}

          {/* Verification */}
          <div className="space-y-1.5">
            <Label className="text-xs">Verification Command</Label>
            <Input value={verification} onChange={e => setVerification(e.target.value)}
              placeholder="make lint && make test (default if empty)" className="h-8 text-xs font-mono" />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" size="sm" onClick={() => { resetForm(); onOpenChange(false); }}>Cancel</Button>
          <Button size="sm" onClick={submit} disabled={submitting} className="gap-1">
            {submitting ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Plus className="w-3.5 h-3.5" />}
            {submitting ? 'Creating…' : 'Create Task'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
