import { useEffect, useState, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Rocket, ChevronLeft, Loader2, GitBranch, Server, Building2,
  FolderGit2, Terminal, Bot, ClipboardList, ArrowDownToLine, Search, Check,
  ListChecks, X, FileKey2,
} from 'lucide-react';
import { api, appendDevice } from '@/lib/api';
import { useApp } from '@/lib/store';

interface DeviceInfo { name: string; type: string; online: boolean }
interface OrgInfo { name: string; repo_count?: number }
interface RepoInfo { name: string; default_branch?: string }
interface TaskInfo {
  id: number;
  title: string;
  repo: string;
  branch?: string;
  description?: string;
  status?: string;
  subtasks?: { id: number; title: string; status: string; phase: string }[];
}

const ACTIONS = [
  { value: 'dispatch', label: 'Dispatch Agent', icon: Rocket, desc: 'Launch AI agent to complete a task autonomously' },
  { value: 'shell', label: 'Interactive Shell', icon: Terminal, desc: 'Open an interactive shell (auto-clones repo)' },
  { value: 'conductor', label: 'Start Conductor', icon: Bot, desc: 'Start a Gemini conductor session' },
  { value: 'clone', label: 'Clone Repo', icon: FolderGit2, desc: 'Clone repository to device' },
  { value: 'pull', label: 'Pull Only', icon: ArrowDownToLine, desc: 'Pull latest code on existing clone' },
] as const;

export default function Launch() {
  const navigate = useNavigate();
  const { device, cli } = useApp();

  // Form state
  const [selDevice, setSelDevice] = useState(device || '');
  const [selOrg, setSelOrg] = useState('');
  const [selRepo, setSelRepo] = useState('');
  const [repoSearch, setRepoSearch] = useState('');
  const [selBranch, setSelBranch] = useState('');
  const [selBaseBranch, setSelBaseBranch] = useState('');
  const [selAction, setSelAction] = useState('dispatch');
  const [selCli, setSelCli] = useState(cli || 'claude');
  const [pullLatest, setPullLatest] = useState(true);
  const [openVibeTunnel, setOpenVibeTunnel] = useState(false);
  const [taskTitle, setTaskTitle] = useState('');
  const [taskDesc, setTaskDesc] = useState('');

  // Task selector
  const [selTask, setSelTask] = useState<TaskInfo | null>(null);
  const [taskSearch, setTaskSearch] = useState('');
  const [taskResults, setTaskResults] = useState<TaskInfo[]>([]);
  const [taskDropdownOpen, setTaskDropdownOpen] = useState(false);
  const [loadingTasks, setLoadingTasks] = useState(false);
  const taskDropdownRef = useRef<HTMLDivElement>(null);
  const taskSearchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Env file selector
  const [envFiles, setEnvFiles] = useState<{name: string}[]>([]);
  const [selEnvFile, setSelEnvFile] = useState<string>('');  // '' = auto-detect
  const [loadingEnvFiles, setLoadingEnvFiles] = useState(false);

  // Data
  const [devices, setDevices] = useState<DeviceInfo[]>([]);
  const [orgs, setOrgs] = useState<OrgInfo[]>([]);
  const [repos, setRepos] = useState<RepoInfo[]>([]);
  const [branches, setBranches] = useState<string[]>([]);
  const [defaultBranch, setDefaultBranch] = useState('main');

  // Loading states
  const [loadingRepos, setLoadingRepos] = useState(false);
  const [loadingBranches, setLoadingBranches] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  // Dropdown visibility
  const [repoDropdownOpen, setRepoDropdownOpen] = useState(false);
  const repoDropdownRef = useRef<HTMLDivElement>(null);

  // Toast
  const [toast, setToast] = useState<{ msg: string; type: 'ok' | 'err' } | null>(null);
  const showToast = (msg: string, type: 'ok' | 'err' = 'ok') => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 6000);
  };

  // Load devices, orgs, and saved defaults on mount
  useEffect(() => {
    api<{ devices: DeviceInfo[] }>('/devices/refresh')
      .then(r => setDevices(r.devices || []))
      .catch(() => {});
    api<{ orgs: OrgInfo[] }>(appendDevice('/orgs', device))
      .then(r => setOrgs(r.orgs || []))
      .catch(() => {});
    // Load saved defaults for this device
    if (device) {
      api<{ settings: Record<string, string> }>('/settings')
        .then(r => {
          const s = r.settings || {};
          const prefix = `${device}:`;
          const lastOrg = s[`${prefix}last_org`];
          const lastRepo = s[`${prefix}last_repo`];
          const lastAction = s[`${prefix}last_action`];
          const lastCli = s[`${prefix}last_cli`];
          if (lastOrg) setSelOrg(lastOrg);
          if (lastRepo) setSelRepo(lastRepo);
          if (lastAction) setSelAction(lastAction);
          if (lastCli && !cli) setSelCli(lastCli);
          // Load repos for the saved org
          if (lastOrg) {
            // Inline repo load (loadRepos not yet defined at this point)
            api<{ repos: RepoInfo[] }>(appendDevice(`/repos?org=${encodeURIComponent(lastOrg)}`, device))
              .then(rr => setRepos(rr.repos || []))
              .catch(() => {});
          }
        })
        .catch(() => {});
    }
  }, [device]);

  // Set device from global
  useEffect(() => { if (device) setSelDevice(device); }, [device]);
  useEffect(() => { if (cli) setSelCli(cli); }, [cli]);

  // Load repos when org changes
  const loadRepos = useCallback(async (org: string) => {
    setRepos([]);
    setSelRepo('');
    setRepoSearch('');
    setBranches([]);
    setSelBranch('');
    if (!org || !selDevice) return;

    setLoadingRepos(true);
    try {
      await api(`/orgs/${org}/sync?device=${selDevice}`, { method: 'POST' }).catch(() => {});
      const data = await api<{ repos: RepoInfo[] }>(`/orgs/${org}/repos`);
      setRepos(data.repos || []);
    } catch {
      showToast('Failed to load repos', 'err');
    }
    setLoadingRepos(false);
  }, [selDevice]);

  useEffect(() => { if (selOrg) loadRepos(selOrg); }, [selOrg, loadRepos]);

  // Load branches when repo changes
  const loadBranches = useCallback(async (org: string, repo: string) => {
    setBranches([]);
    setSelBranch('');
    if (!org || !repo || !selDevice) return;

    setLoadingBranches(true);
    try {
      const data = await api<{ branches: string[]; default?: string }>(
        `/repos/${org}/${repo}/branches?device=${selDevice}`
      );
      setBranches(data.branches || []);
      const defBranch = data.default || 'main';
      setDefaultBranch(defBranch);
      setSelBaseBranch(defBranch);
      // Only set work branch for non-dispatch actions; dispatch auto-generates
    } catch {
      setBranches([]);
      setSelBranch('main');
    }
    setLoadingBranches(false);
  }, [selDevice]);

  useEffect(() => {
    if (selOrg && selRepo) loadBranches(selOrg, selRepo);
  }, [selOrg, selRepo, loadBranches]);

  // Search tasks (debounced)
  const searchTasks = useCallback(async (query: string) => {
    if (!selRepo) return;
    setLoadingTasks(true);
    try {
      const params = new URLSearchParams();
      params.set('repo', selRepo);
      if (query) params.set('pattern', query);
      params.set('limit', '15');
      if (device) params.set('device', device);
      const data = await api<{ tasks: TaskInfo[] }>(`/task-db?${params}`);
      setTaskResults(data.tasks || []);
    } catch {
      setTaskResults([]);
    }
    setLoadingTasks(false);
  }, [selRepo, device]);

  const onTaskSearchInput = (val: string) => {
    setTaskSearch(val);
    setTaskDropdownOpen(true);
    if (taskSearchTimer.current) clearTimeout(taskSearchTimer.current);
    taskSearchTimer.current = setTimeout(() => searchTasks(val), 300);
  };

  // Load tasks when repo changes
  useEffect(() => {
    if (selRepo) searchTasks('');
  }, [selRepo, searchTasks]);

  // Close dropdowns on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (repoDropdownRef.current && !repoDropdownRef.current.contains(e.target as Node)) {
        setRepoDropdownOpen(false);
      }
      if (taskDropdownRef.current && !taskDropdownRef.current.contains(e.target as Node)) {
        setTaskDropdownOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  // Filtered repos
  const filteredRepos = repos.filter(r =>
    r.name.toLowerCase().includes(repoSearch.toLowerCase())
  );

  // When task is selected, fill in branch and title
  const selectTask = (t: TaskInfo) => {
    setSelTask(t);
    setTaskSearch(t.title);
    setTaskDropdownOpen(false);
    if (t.branch) setSelBranch(t.branch);  // task branch → work branch
    if (t.title && !taskTitle) setTaskTitle(t.title);
    if (t.description && !taskDesc) setTaskDesc(t.description);
  };

  const clearTask = () => {
    setSelTask(null);
    setTaskSearch('');
  };

  // Action-specific field visibility
  const showCli = selAction === 'dispatch';
  const showBranch = ['dispatch', 'clone', 'shell', 'conductor'].includes(selAction);
  const showTask = selAction === 'dispatch';
  const showPull = ['shell', 'conductor', 'dispatch'].includes(selAction);

  // Submit
  const submit = async () => {
    if (!selDevice) { showToast('Select a device', 'err'); return; }
    if (!selOrg) { showToast('Select an organization', 'err'); return; }
    if (!selRepo) { showToast('Select a repository', 'err'); return; }
    if (selAction === 'dispatch' && !selTask && !taskTitle && !taskDesc) {
      showToast('Provide a task title or description, or select an existing task', 'err');
      return;
    }

    setSubmitting(true);

    // Save selections as defaults for next launch (even if job fails)
    const prefix = `${selDevice}:`;
    api('/settings-batch', {
      method: 'PUT',
      body: JSON.stringify({ settings: {
        [`${prefix}last_org`]: selOrg,
        [`${prefix}last_repo`]: selRepo,
        [`${prefix}last_action`]: selAction,
        [`${prefix}last_cli`]: showCli ? selCli : (cli || ''),
      } }),
    }).catch(() => {});

    try {
      const payload: Record<string, unknown> = {
        device: selDevice,
        org: selOrg,
        repo: selRepo,
        action: selAction,
        cli: showCli ? selCli : cli,
        branch: selBranch || undefined,
        base_branch: selBaseBranch || undefined,
        title: taskTitle || undefined,
        task: taskDesc || undefined,
        task_id: selTask?.id || undefined,
        pull_latest: pullLatest,
        env_file: selEnvFile || undefined,
      };
      const r = await api<{ ok?: boolean; job_id?: number; already_running?: boolean; vt_url?: string; stderr?: string }>(
        '/jobs', { method: 'POST', body: JSON.stringify(payload) }
      );
      if (r.ok) {
        showToast(`Job #${r.job_id} launched on ${selDevice}`, 'ok');
        if (r.vt_url && openVibeTunnel) window.open(r.vt_url, '_blank');
        setTimeout(() => navigate('/jobs'), 1500);
      } else if (r.already_running) {
        showToast(`Already running — job #${r.job_id}`, 'ok');
        setTimeout(() => navigate('/jobs'), 1500);
      } else if (r.job_id) {
        // Job was created but SSH chain returned non-zero (partial success)
        showToast(`Job #${r.job_id} created with warnings${r.stderr ? ': ' + r.stderr : ''}`, 'ok');
        setTimeout(() => navigate('/jobs'), 1500);
      } else {
        showToast(`Job failed: ${r.stderr || 'unknown error'}`, 'err');
      }
    } catch {
      showToast('Failed to launch job', 'err');
    }
    setSubmitting(false);
  };

  const sortedDevices = [...devices].sort((a, b) => (b.online ? 1 : 0) - (a.online ? 1 : 0));

  return (
    <div className="flex flex-col h-full overflow-y-auto">
      {/* Header */}
      <div className="flex items-center gap-3 px-4 md:px-6 pt-4 pb-3 border-b border-border">
        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={() => navigate('/jobs')}>
          <ChevronLeft className="w-4 h-4" />
        </Button>
        <Rocket className="w-5 h-5 text-primary" />
        <h1 className="text-lg font-bold flex-1">Launch New Job</h1>
      </div>

      {/* Toast */}
      {toast && (
        <div className={`mx-4 md:mx-6 mt-3 px-4 py-3 rounded-lg text-sm flex items-center gap-2 ${
          toast.type === 'ok' ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30' :
          'bg-red-500/15 text-red-400 border border-red-500/30'
        }`}>
          {toast.msg}
        </div>
      )}

      {/* Form */}
      <div className="flex-1 p-4 md:p-6 max-w-2xl mx-auto w-full space-y-5">

        {/* Device */}
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
            <Server className="w-3.5 h-3.5" /> Device
          </label>
          <select
            className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
            value={selDevice}
            onChange={e => setSelDevice(e.target.value)}
          >
            <option value="">— Select device —</option>
            {sortedDevices.map(d => (
              <option key={d.name} value={d.name}>
                {d.online ? '🟢' : '🔴'} {d.name} ({d.type})
              </option>
            ))}
          </select>
        </div>

        {/* Organization */}
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
            <Building2 className="w-3.5 h-3.5" /> Organization
          </label>
          <select
            className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
            value={selOrg}
            onChange={e => setSelOrg(e.target.value)}
          >
            <option value="">— Select organization —</option>
            {orgs.map(o => (
              <option key={o.name} value={o.name}>
                {o.name} {o.repo_count ? `(${o.repo_count} repos)` : ''}
              </option>
            ))}
          </select>
        </div>

        {/* Repository — searchable dropdown */}
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
            <FolderGit2 className="w-3.5 h-3.5" /> Repository
            {loadingRepos && <Loader2 className="w-3 h-3 animate-spin text-primary" />}
          </label>
          <div className="relative" ref={repoDropdownRef}>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted-foreground pointer-events-none" />
              <input
                type="text"
                className="w-full h-10 text-sm bg-background border border-border rounded-lg pl-9 pr-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                placeholder={
                  !selOrg ? '— Select org first —' :
                  loadingRepos ? 'Loading repos...' :
                  repos.length > 0 ? `Search ${repos.length} repos...` : 'No repos found'
                }
                value={repoSearch}
                onChange={e => { setRepoSearch(e.target.value); setRepoDropdownOpen(true); }}
                onFocus={() => setRepoDropdownOpen(true)}
                disabled={!selOrg || loadingRepos}
              />
              {selRepo && (
                <Badge variant="secondary" className="absolute right-2 top-1/2 -translate-y-1/2 text-[10px] py-0 gap-1">
                  <Check className="w-2.5 h-2.5" /> {selRepo}
                </Badge>
              )}
            </div>
            {repoDropdownOpen && filteredRepos.length > 0 && (
              <div className="absolute z-50 top-full left-0 right-0 mt-1 max-h-56 overflow-y-auto bg-popover border border-border rounded-lg shadow-xl">
                {filteredRepos.map(r => (
                  <button
                    key={r.name}
                    className={`w-full text-left px-3 py-2 text-sm hover:bg-accent/50 transition-colors truncate flex items-center gap-2 ${
                      r.name === selRepo ? 'bg-primary/10 text-primary font-medium' : 'text-foreground'
                    }`}
                    onClick={() => {
                      setSelRepo(r.name);
                      setRepoSearch(r.name);
                      setRepoDropdownOpen(false);
                    }}
                  >
                    {r.name === selRepo && <Check className="w-3 h-3 shrink-0" />}
                    <span className="truncate">{r.name}</span>
                  </button>
                ))}
              </div>
            )}
            {repoDropdownOpen && selOrg && !loadingRepos && filteredRepos.length === 0 && (
              <div className="absolute z-50 top-full left-0 right-0 mt-1 bg-popover border border-border rounded-lg shadow-xl p-4 text-center text-xs text-muted-foreground">
                No repos match &quot;{repoSearch}&quot;
              </div>
            )}
          </div>
        </div>

        {/* Action */}
        <div className="space-y-1.5">
          <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
            <ClipboardList className="w-3.5 h-3.5" /> Action
          </label>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
            {ACTIONS.map(a => {
              const Icon = a.icon;
              return (
                <button
                  key={a.value}
                  className={`flex items-start gap-3 p-3 rounded-lg border text-left transition-all ${
                    selAction === a.value
                      ? 'border-primary bg-primary/10 ring-1 ring-primary/30'
                      : 'border-border hover:border-primary/40 hover:bg-muted/30'
                  }`}
                  onClick={() => setSelAction(a.value)}
                >
                  <Icon className={`w-4 h-4 mt-0.5 shrink-0 ${selAction === a.value ? 'text-primary' : 'text-muted-foreground'}`} />
                  <div>
                    <div className={`text-sm font-medium ${selAction === a.value ? 'text-primary' : ''}`}>{a.label}</div>
                    <div className="text-[11px] text-muted-foreground leading-tight mt-0.5">{a.desc}</div>
                  </div>
                </button>
              );
            })}
          </div>
        </div>

        {/* CLI Agent — shown for dispatch */}
        {showCli && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
              <Bot className="w-3.5 h-3.5" /> CLI Agent
            </label>
            <div className="flex gap-2">
              {(['claude', 'gemini', 'codex'] as const).map(c => (
                <button
                  key={c}
                  className={`flex-1 h-9 text-sm rounded-lg border transition-all font-medium capitalize ${
                    selCli === c
                      ? 'border-primary bg-primary/10 text-primary ring-1 ring-primary/30'
                      : 'border-border hover:border-primary/40 text-muted-foreground hover:text-foreground'
                  }`}
                  onClick={() => setSelCli(c)}
                >
                  {c}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Existing Task — searchable dropdown (shown for dispatch) */}
        {showTask && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
              <ListChecks className="w-3.5 h-3.5" /> Existing Task
              <span className="text-[10px] font-normal normal-case tracking-normal text-muted-foreground/60">(optional — select or create new below)</span>
              {loadingTasks && <Loader2 className="w-3 h-3 animate-spin text-primary" />}
            </label>
            <div className="relative" ref={taskDropdownRef}>
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted-foreground pointer-events-none" />
                <input
                  type="text"
                  className="w-full h-10 text-sm bg-background border border-border rounded-lg pl-9 pr-20 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                  placeholder={!selRepo ? '— Select repo first —' : 'Search existing tasks...'}
                  value={taskSearch}
                  onChange={e => onTaskSearchInput(e.target.value)}
                  onFocus={() => { setTaskDropdownOpen(true); if (selRepo && taskResults.length === 0) searchTasks(''); }}
                  disabled={!selRepo}
                />
                {selTask && (
                  <button
                    onClick={clearTask}
                    className="absolute right-2 top-1/2 -translate-y-1/2 flex items-center gap-1"
                  >
                    <Badge variant="secondary" className="text-[10px] py-0 gap-1 cursor-pointer hover:bg-destructive/20">
                      <Check className="w-2.5 h-2.5" /> #{selTask.id}
                      <X className="w-2.5 h-2.5 ml-0.5" />
                    </Badge>
                  </button>
                )}
              </div>

              {taskDropdownOpen && taskResults.length > 0 && (
                <div className="absolute z-50 top-full left-0 right-0 mt-1 max-h-64 overflow-y-auto bg-popover border border-border rounded-lg shadow-xl">
                  {taskResults.map(t => (
                    <button
                      key={t.id}
                      className={`w-full text-left px-3 py-2.5 hover:bg-accent/50 transition-colors border-b border-border/50 last:border-0 ${
                        selTask?.id === t.id ? 'bg-primary/10' : ''
                      }`}
                      onClick={() => selectTask(t)}
                    >
                      <div className="flex items-center gap-2">
                        <span className="text-[11px] text-muted-foreground font-mono shrink-0">#{t.id}</span>
                        <span className="text-sm font-medium truncate flex-1">{t.title}</span>
                        {t.status && (
                          <Badge variant="outline" className="text-[10px] py-0 shrink-0">
                            {t.status}
                          </Badge>
                        )}
                      </div>
                      {t.branch && (
                        <div className="text-[11px] text-muted-foreground mt-0.5 flex items-center gap-1">
                          <GitBranch className="w-2.5 h-2.5" /> {t.branch}
                        </div>
                      )}
                    </button>
                  ))}
                </div>
              )}
              {taskDropdownOpen && selRepo && !loadingTasks && taskResults.length === 0 && taskSearch && (
                <div className="absolute z-50 top-full left-0 right-0 mt-1 bg-popover border border-border rounded-lg shadow-xl p-4 text-center text-xs text-muted-foreground">
                  No tasks found — fill in title &amp; description below to auto-create
                </div>
              )}
            </div>

            {/* Selected task preview */}
            {selTask && (
              <div className="bg-muted/30 border border-primary/20 rounded-lg p-3 space-y-2">
                <div className="flex items-center gap-2">
                  <ListChecks className="w-3.5 h-3.5 text-primary shrink-0" />
                  <span className="text-sm font-medium">{selTask.title}</span>
                </div>
                {selTask.description && (
                  <p className="text-xs text-muted-foreground line-clamp-2">{selTask.description}</p>
                )}
                {selTask.subtasks && selTask.subtasks.length > 0 && (
                  <div className="text-[11px] text-muted-foreground">
                    {selTask.subtasks.length} subtasks · {selTask.subtasks.filter(s => s.status === 'done').length} done
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        {/* Base Branch — dropdown from API branches */}
        {showBranch && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
              <GitBranch className="w-3.5 h-3.5" /> Base Branch
              {loadingBranches && <Loader2 className="w-3 h-3 animate-spin text-primary" />}
              <span className="text-[10px] font-normal normal-case tracking-normal text-muted-foreground/60">(branch to create worktree from)</span>
            </label>
            {branches.length > 0 ? (
              <select
                className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                value={selBaseBranch}
                onChange={e => setSelBaseBranch(e.target.value)}
              >
                {branches.map(b => (
                  <option key={b} value={b}>
                    {b}{b === defaultBranch ? ' (default)' : ''}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                placeholder={selRepo ? 'Type base branch name (e.g. main)' : '— Select repo first —'}
                value={selBaseBranch}
                onChange={e => setSelBaseBranch(e.target.value)}
                disabled={!selRepo}
              />
            )}
          </div>
        )}

        {/* Work Branch — text input for dispatch, dropdown for others */}
        {showBranch && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
              <GitBranch className="w-3.5 h-3.5" /> Work Branch
              <span className="text-[10px] font-normal normal-case tracking-normal text-muted-foreground/60">
                {selAction === 'dispatch' ? '(auto-generated from task if empty)' : '(same as base if empty)'}
              </span>
            </label>
            <input
              type="text"
              className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors placeholder:text-muted-foreground/50"
              placeholder={selAction === 'dispatch' ? 'Leave empty to auto-generate from task title' : `Same as base branch (${selBaseBranch || 'main'})`}
              value={selBranch}
              onChange={e => setSelBranch(e.target.value)}
              disabled={!selRepo}
            />
          </div>
        )}

        {/* Pull latest */}
        {showPull && (
          <label className="flex items-center gap-3 p-3 rounded-lg border border-border hover:bg-muted/20 cursor-pointer transition-colors">
            <input
              type="checkbox"
              className="w-4 h-4 accent-primary rounded"
              checked={pullLatest}
              onChange={e => setPullLatest(e.target.checked)}
            />
            <div>
              <div className="text-sm font-medium">Pull latest code</div>
              <div className="text-[11px] text-muted-foreground">If repo is already cloned, pull newest changes before starting</div>
            </div>
          </label>
        )}

        {/* Open VibeTunnel */}
        {showPull && (
          <label className="flex items-center gap-3 p-3 rounded-lg border border-border hover:bg-muted/20 cursor-pointer transition-colors">
            <input
              type="checkbox"
              className="w-4 h-4 accent-primary rounded"
              checked={openVibeTunnel}
              onChange={e => setOpenVibeTunnel(e.target.checked)}
            />
            <div>
              <div className="text-sm font-medium">Open VibeTunnel</div>
              <div className="text-[11px] text-muted-foreground">Open tmux session viewer in a new tab after launch</div>
            </div>
          </label>
        )}

        {/* Env file selector — shown for dispatch */}
        {showPull && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider flex items-center gap-1.5">
              <FileKey2 size={12} /> Env File
            </label>
            <div className="flex items-center gap-2">
              <select
                className="flex-1 h-9 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                value={selEnvFile}
                onChange={e => setSelEnvFile(e.target.value)}
              >
                <option value="">Auto-detect (repo-named)</option>
                <option value="none">None — no env file</option>
                {envFiles.map(f => (
                  <option key={f.name} value={f.name}>{f.name}</option>
                ))}
              </select>
              <button
                type="button"
                className="h-9 px-3 text-xs bg-muted/30 border border-border rounded-lg hover:bg-muted/50 transition-colors"
                onClick={async () => {
                  if (!selDevice) return;
                  setLoadingEnvFiles(true);
                  try {
                    const r = await api<{files: {name: string}[]}>(`/env-files?device=${selDevice}`);
                    setEnvFiles(r.files || []);
                    // Auto-select if repo-named file exists
                    const orgRepo = `${selOrg}--${selRepo}.env`;
                    const repoOnly = `${selRepo}.env`;
                    const match = (r.files || []).find(f => f.name === orgRepo || f.name === repoOnly);
                    if (match && !selEnvFile) setSelEnvFile(match.name);
                  } catch { setEnvFiles([]); }
                  setLoadingEnvFiles(false);
                }}
                disabled={!selDevice || loadingEnvFiles}
              >
                {loadingEnvFiles ? <Loader2 size={12} className="animate-spin" /> : 'Refresh'}
              </button>
            </div>
            {selEnvFile && selEnvFile !== 'none' && (
              <div className="text-[11px] text-emerald-500">✓ Will attach: {selEnvFile}</div>
            )}
          </div>
        )}

        {/* Title + Description — shown for dispatch when no existing task selected */}
        {showTask && (
          <div className="space-y-3">
            <div className="space-y-1.5">
              <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                Task Title {!selTask && <span className="text-primary/60">(required if no task selected)</span>}
              </label>
              <input
                type="text"
                className="w-full h-10 text-sm bg-background border border-border rounded-lg px-3 text-foreground focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                placeholder="e.g. Implement user authentication module"
                value={taskTitle}
                onChange={e => setTaskTitle(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                Task Description
              </label>
              <textarea
                className="w-full h-28 text-sm bg-background border border-border rounded-lg px-3 py-2.5 text-foreground resize-y focus:ring-2 focus:ring-primary/30 focus:border-primary transition-colors"
                placeholder="Detailed description of what the agent should implement. If no subtasks exist, the agent will auto-generate them."
                value={taskDesc}
                onChange={e => setTaskDesc(e.target.value)}
              />
            </div>
          </div>
        )}

        {/* Summary */}
        {selDevice && selOrg && selRepo && (
          <div className="bg-muted/30 border border-border rounded-lg p-3 space-y-1.5">
            <div className="text-[10px] font-semibold text-muted-foreground uppercase tracking-wider">Launch Summary</div>
            <div className="text-sm">
              <span className="font-medium">{ACTIONS.find(a => a.value === selAction)?.label}</span>
              {showCli && <> with <span className="font-medium capitalize">{selCli}</span></>}
              {' on '}
              <span className="font-medium">{selDevice}</span>
            </div>
            <div className="text-xs text-muted-foreground font-mono">
              {selOrg}/{selRepo} · base: {selBaseBranch || defaultBranch} → work: {selBranch || 'auto-generated'}
            </div>
            {selTask && (
              <div className="text-xs text-muted-foreground">
                📋 Task #{selTask.id}: {selTask.title}
              </div>
            )}
            {!selTask && taskTitle && (
              <div className="text-xs text-muted-foreground">
                ✨ New task: {taskTitle} (auto-created + subtasks generated)
              </div>
            )}
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-3 pb-8 pt-2">
          <Button variant="outline" className="flex-1 h-11" onClick={() => navigate('/jobs')}>
            Cancel
          </Button>
          <Button
            className="flex-1 h-11 gap-2 font-semibold"
            disabled={!selDevice || !selOrg || !selRepo || submitting}
            onClick={submit}
          >
            {submitting ? (
              <><Loader2 className="w-4 h-4 animate-spin" /> Launching...</>
            ) : (
              <><Rocket className="w-4 h-4" /> Launch Job</>
            )}
          </Button>
        </div>

      </div>
    </div>
  );
}
