import { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import {
  LayoutDashboard,
  ListTodo,
  Cpu,
  Monitor,
  Zap,
  FolderGit2,
  RotateCw,
  ChevronDown,
  ChevronRight,
  Loader2,
  GitBranch,
  ExternalLink,
} from 'lucide-react';
import { api, appendDevice, type Job, type Org, type Repo } from '@/lib/api';
import { useApp } from '@/lib/store';

function statusColor(s: string) {
  const m: Record<string, string> = {
    running: 'bg-green-500/15 text-green-400 border-green-500/30',
    completed: 'bg-blue-500/15 text-blue-400 border-blue-500/30',
    failed: 'bg-red-500/15 text-red-400 border-red-500/30',
    killed: 'bg-yellow-500/15 text-yellow-400 border-yellow-500/30',
  };
  return m[s] || 'bg-zinc-500/15 text-zinc-400 border-zinc-500/30';
}

export default function Dashboard() {
  const { device, status, devices, refresh } = useApp();
  const navigate = useNavigate();
  const [orgs, setOrgs] = useState<Org[]>([]);
  const [repos, setRepos] = useState<Repo[]>([]);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [expandedOrg, setExpandedOrg] = useState<string | null>(null);
  const [orgRepos, setOrgRepos] = useState<Repo[]>([]);
  const [loadingOrgRepos, setLoadingOrgRepos] = useState(false);
  const [syncingOrg, setSyncingOrg] = useState<string | null>(null);

  useEffect(() => {
    if (!device) return;
    api<{ orgs: Org[] }>(appendDevice('/orgs', device)).then(r => setOrgs(r.orgs || [])).catch(() => {});
    api<{ repos: Repo[] }>(appendDevice('/repos/cloned', device)).then(r => setRepos(r.repos || [])).catch(() => {});
    api<{ jobs: Job[] }>(appendDevice('/jobs?limit=5', device)).then(r => setJobs(r.jobs || [])).catch(() => {});
  }, [device]);

  const stats = [
    { icon: Zap, label: 'Orgs', value: orgs.length },
    { icon: ListTodo, label: 'Tasks', value: status?.total_tasks || 0 },
    { icon: Cpu, label: 'Running', value: status?.running_jobs || 0 },
    { icon: Monitor, label: 'Devices', value: devices.length },
  ];

  const syncOrg = async (org: string) => {
    setSyncingOrg(org);
    try {
      await api(appendDevice(`/orgs/${org}/sync`, device), { method: 'POST' });
      // Refresh org list to get updated repo_count
      const r = await api<{ orgs: Org[] }>(appendDevice('/orgs', device));
      setOrgs(r.orgs || []);
      // Refresh cloned repos list
      const rr = await api<{ repos: Repo[] }>(appendDevice('/repos', device));
      setRepos(rr.repos || []);
      // Refresh expanded org repos if viewing this one
      if (expandedOrg === org) {
        const or = await api<{ repos: Repo[] }>(appendDevice(`/orgs/${org}/repos`, device));
        setOrgRepos(or.repos || []);
      }
    } catch { /* ignore */ }
    setSyncingOrg(null);
  };

  const toggleOrg = useCallback(async (orgName: string) => {
    if (expandedOrg === orgName) {
      setExpandedOrg(null);
      setOrgRepos([]);
      return;
    }
    setExpandedOrg(orgName);
    setLoadingOrgRepos(true);
    try {
      const r = await api<{ repos: Repo[] }>(appendDevice(`/orgs/${orgName}/repos`, device));
      setOrgRepos(r.repos || []);
    } catch {
      setOrgRepos([]);
    }
    setLoadingOrgRepos(false);
  }, [device, expandedOrg]);

  return (
    <div className="p-4 md:p-6 space-y-4">
      <div className="flex items-center gap-2">
        <LayoutDashboard className="w-5 h-5" />
        <h1 className="text-xl font-bold flex-1">Dashboard</h1>
        <Button variant="ghost" size="icon" onClick={refresh}><RotateCw className="w-4 h-4" /></Button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {stats.map(s => (
          <Card key={s.label} className="bg-card">
            <CardContent className="p-4 flex items-center gap-3">
              <div className="p-2 rounded-lg bg-primary/10">
                <s.icon className="w-4 h-4 text-primary" />
              </div>
              <div>
                <p className="text-2xl font-bold">{s.value}</p>
                <p className="text-xs text-muted-foreground">{s.label}</p>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* VibeTunnel Quick Link */}
      <Card className="bg-gradient-to-r from-emerald-500/10 to-blue-500/10 border-emerald-500/20">
        <CardContent className="p-4 flex items-center gap-3">
          <div className="p-2 rounded-lg bg-emerald-500/15">
            <ExternalLink className="w-4 h-4 text-emerald-400" />
          </div>
          <div className="flex-1">
            <p className="text-sm font-medium">VibeTunnel Dashboard</p>
            <p className="text-xs text-muted-foreground">Terminal sessions & agent monitoring</p>
          </div>
          <Button size="sm" variant="outline" className="gap-1 text-xs"
            onClick={() => {
              const host = device || 'localhost';
              window.open(`http://${host}:4020`, '_blank');
            }}
          >
            <ExternalLink className="w-3 h-3" /> Open VT
          </Button>
        </CardContent>
      </Card>

      {/* Recent Jobs */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm font-medium">Recent Jobs</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {jobs.length === 0 ? (
            <p className="text-sm text-muted-foreground p-4">No jobs yet</p>
          ) : (
            <div className="divide-y divide-border">
              {jobs.map(j => (
                <div key={j.id} className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-accent/30 transition-colors"
                  onClick={() => navigate(`/jobs?open=${j.id}`)}>
                  <span className="text-xs text-muted-foreground font-mono">#{j.id}</span>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm truncate">{j.org ? `${j.org}/` : ''}{j.repo || 'unknown'}</p>
                    <p className="text-xs text-muted-foreground">{j.device} · {j.cli}</p>
                  </div>
                  <Badge variant="outline" className={statusColor(j.status)}>
                    {j.status}
                  </Badge>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Organizations with expandable repos */}
      {orgs.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm font-medium flex items-center gap-2">
              <FolderGit2 className="w-4 h-4" /> Organizations ({orgs.length})
            </CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <div className="divide-y divide-border">
              {orgs.map(o => (
                <div key={o.name}>
                  <div
                    className="flex items-center gap-3 px-4 py-2.5 cursor-pointer hover:bg-accent/30 transition-colors"
                    onClick={() => toggleOrg(o.name)}
                  >
                    {expandedOrg === o.name
                      ? <ChevronDown className="w-4 h-4 text-muted-foreground" />
                      : <ChevronRight className="w-4 h-4 text-muted-foreground" />}
                    <span className="text-sm font-medium flex-1">{o.name}</span>
                    {(o.cloned_count !== undefined || o.repo_count !== undefined) && (
                      <Badge variant="secondary" className="text-[10px]">
                        {o.cloned_count ?? 0} cloned{o.repo_count ? ` / ${o.repo_count} avail` : ''}
                      </Badge>
                    )}
                    {o.ssh_host_alias && (
                      <span className="text-xs text-muted-foreground font-mono hidden sm:inline">{o.ssh_host_alias}</span>
                    )}
                    <Button
                      size="sm" variant="ghost" className="h-6 text-xs"
                      onClick={e => { e.stopPropagation(); syncOrg(o.name); }}
                      disabled={syncingOrg === o.name}
                    >
                      {syncingOrg === o.name ? <Loader2 className="w-3 h-3 animate-spin" /> : 'Sync'}
                    </Button>
                  </div>
                  {/* Expanded org repos list */}
                  {expandedOrg === o.name && (
                    <div className="bg-muted/20 border-t border-border">
                      {loadingOrgRepos ? (
                        <div className="flex items-center justify-center py-4">
                          <Loader2 className="w-4 h-4 animate-spin text-muted-foreground" />
                        </div>
                      ) : orgRepos.length === 0 ? (
                        <p className="text-xs text-muted-foreground p-4">No repos synced yet. Click Sync to discover repositories.</p>
                      ) : (
                        <div className="divide-y divide-border/50">
                          {orgRepos.map(r => (
                            <div key={`${r.org}/${r.name}`} className="flex items-center gap-2 px-6 py-2">
                              <FolderGit2 className="w-3.5 h-3.5 text-muted-foreground" />
                              <span className="text-sm flex-1">{r.name}</span>
                              {r.branch && (
                                <span className="flex items-center gap-1 text-xs text-muted-foreground font-mono">
                                  <GitBranch className="w-3 h-3" />{r.branch}
                                </span>
                              )}
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Cloned Repositories on Device */}
      {repos.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm font-medium">
              Cloned on Device ({repos.length})
            </CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <div className="divide-y divide-border">
              {repos.slice(0, 15).map(r => (
                <div key={`${r.org}/${r.name}`} className="flex items-center gap-3 px-4 py-2">
                  <FolderGit2 className="w-3.5 h-3.5 text-muted-foreground" />
                  <span className="text-sm flex-1">{r.org}/{r.name}</span>
                  {r.branch && (
                    <Badge variant="outline" className="text-xs">{r.branch}</Badge>
                  )}
                </div>
              ))}
              {repos.length > 15 && (
                <p className="text-xs text-muted-foreground p-3 text-center">
                  and {repos.length - 15} more…
                </p>
              )}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
