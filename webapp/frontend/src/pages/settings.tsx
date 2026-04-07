import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Settings as SettingsIcon,
  Save,
  RotateCw,
  Check,
  Trash2,
  ChevronDown,
  ChevronUp,
  Database,
} from 'lucide-react';
import { useApp } from '@/lib/store';
import { api } from '@/lib/api';
import { useState, useEffect, useCallback } from 'react';

// Known device-scoped setting keys
const DEVICE_KEYS = [
  { key: 'last_org', label: 'Organization', desc: 'Last selected org for job launch' },
  { key: 'last_repo', label: 'Repository', desc: 'Last selected repo for job launch' },
  { key: 'last_action', label: 'Action', desc: 'Last selected action (dispatch, shell, etc.)' },
  { key: 'last_cli', label: 'CLI Agent', desc: 'Last selected CLI for job launch' },
] as const;

export default function SettingsPage() {
  const { device, setDevice, cli, setCli, devices } = useApp();
  const [saved, setSaved] = useState(false);
  const [allSettings, setAllSettings] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<Record<string, string>>({});
  const [showRaw, setShowRaw] = useState(false);

  const loadSettings = useCallback(() => {
    api<{ settings: Record<string, string> }>('/settings')
      .then(r => setAllSettings(r.settings || {}))
      .catch(() => {});
  }, []);

  useEffect(() => { loadSettings(); }, [loadSettings]);

  const save = () => {
    setDevice(device);
    setCli(cli);
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  const updateSetting = (key: string, value: string) => {
    api(`/settings/${encodeURIComponent(key)}`, {
      method: 'PUT',
      body: JSON.stringify({ value }),
    }).then(() => {
      setAllSettings(prev => ({ ...prev, [key]: value }));
      setEditing(prev => { const n = { ...prev }; delete n[key]; return n; });
    }).catch(() => {});
  };

  const deleteSetting = (key: string) => {
    api(`/settings/${encodeURIComponent(key)}`, { method: 'DELETE' })
      .then(() => {
        setAllSettings(prev => { const n = { ...prev }; delete n[key]; return n; });
      }).catch(() => {});
  };

  // Group settings by device prefix
  const deviceNames = devices.map(d => d.name);
  const deviceSettings: Record<string, Record<string, string>> = {};
  const globalSettings: Record<string, string> = {};

  for (const [k, v] of Object.entries(allSettings)) {
    const colonIdx = k.indexOf(':');
    if (colonIdx > 0) {
      const devName = k.substring(0, colonIdx);
      const settingKey = k.substring(colonIdx + 1);
      if (!deviceSettings[devName]) deviceSettings[devName] = {};
      deviceSettings[devName][settingKey] = v;
    } else {
      globalSettings[k] = v;
    }
  }

  return (
    <div className="p-4 md:p-6 space-y-4 max-w-xl pb-24 md:pb-6">
      <div className="flex items-center gap-2">
        <SettingsIcon className="w-5 h-5" />
        <h1 className="text-lg font-bold">Settings</h1>
      </div>

      {/* Global Defaults */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Global Defaults</CardTitle>
        </CardHeader>
        <CardContent className="space-y-5">
          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1.5">Default Device</label>
            <Select value={device} onValueChange={setDevice}>
              <SelectTrigger>
                <SelectValue placeholder="Select device…" />
              </SelectTrigger>
              <SelectContent>
                {devices.map(d => (
                  <SelectItem key={d.name} value={d.name}>
                    <span className={`inline-block w-2 h-2 rounded-full mr-2 ${d.online ? 'bg-green-500' : 'bg-zinc-500'}`} />
                    {d.name}
                    <Badge variant="outline" className="ml-2 text-[9px]">{d.type}</Badge>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground mt-1">Device used for all data queries.</p>
          </div>

          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1.5">Default CLI Agent</label>
            <Select value={cli} onValueChange={setCli}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="claude">Claude Code</SelectItem>
                <SelectItem value="gemini">Gemini CLI</SelectItem>
                <SelectItem value="codex">Codex CLI</SelectItem>
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground mt-1">CLI agent for dispatch operations.</p>
          </div>

          <div className="flex items-center gap-2 pt-2">
            <Button onClick={save} className="gap-1.5">
              {saved ? <Check className="w-4 h-4" /> : <Save className="w-4 h-4" />}
              {saved ? 'Saved' : 'Save'}
            </Button>
            <Button variant="outline" className="gap-1.5" onClick={() => {
              if (devices.length) setDevice(devices[0].name);
              setCli('claude');
            }}>
              <RotateCw className="w-4 h-4" /> Reset
            </Button>
          </div>
        </CardContent>
      </Card>

      {/* Device-specific Defaults */}
      {deviceNames.filter(dn => deviceSettings[dn]).map(devName => (
        <Card key={devName}>
          <CardHeader>
            <CardTitle className="text-sm flex items-center gap-2">
              <span className={`inline-block w-2 h-2 rounded-full ${devices.find(d => d.name === devName)?.online ? 'bg-green-500' : 'bg-zinc-500'}`} />
              {devName}
              <Badge variant="outline" className="text-[9px] font-normal">device defaults</Badge>
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {DEVICE_KEYS.map(({ key, label, desc }) => {
              const fullKey = `${devName}:${key}`;
              const value = allSettings[fullKey];
              if (!value && !(fullKey in editing)) return null;
              const isEditing = fullKey in editing;
              return (
                <div key={key} className="space-y-1">
                  <div className="flex items-center justify-between">
                    <label className="text-xs font-medium text-muted-foreground">{label}</label>
                    <div className="flex items-center gap-1">
                      {isEditing ? (
                        <>
                          <Button size="sm" variant="ghost" className="h-6 text-xs px-2"
                            onClick={() => { updateSetting(fullKey, editing[fullKey]); }}>
                            <Check className="w-3 h-3" />
                          </Button>
                          <Button size="sm" variant="ghost" className="h-6 text-xs px-2"
                            onClick={() => setEditing(prev => { const n = { ...prev }; delete n[fullKey]; return n; })}>
                            ✕
                          </Button>
                        </>
                      ) : (
                        <Button size="sm" variant="ghost" className="h-6 text-xs px-2 text-red-400 hover:text-red-300"
                          onClick={() => deleteSetting(fullKey)}>
                          <Trash2 className="w-3 h-3" />
                        </Button>
                      )}
                    </div>
                  </div>
                  {isEditing ? (
                    <input
                      type="text"
                      className="w-full h-8 text-sm bg-background border border-border rounded px-3 text-foreground focus:outline-none focus:ring-1 focus:ring-primary"
                      value={editing[fullKey]}
                      onChange={e => setEditing(prev => ({ ...prev, [fullKey]: e.target.value }))}
                      onKeyDown={e => { if (e.key === 'Enter') updateSetting(fullKey, editing[fullKey]); }}
                    />
                  ) : (
                    <button
                      className="w-full text-left text-sm bg-muted/30 rounded px-3 py-1.5 text-foreground hover:bg-muted/50 transition-colors"
                      onClick={() => setEditing(prev => ({ ...prev, [fullKey]: value || '' }))}
                    >
                      {value || <span className="text-muted-foreground italic">not set</span>}
                    </button>
                  )}
                  <p className="text-[10px] text-muted-foreground">{desc}</p>
                </div>
              );
            })}
            <Button size="sm" variant="outline" className="gap-1 h-7 text-xs text-red-400 hover:text-red-300 mt-2"
              onClick={() => {
                DEVICE_KEYS.forEach(({ key }) => {
                  const fullKey = `${devName}:${key}`;
                  if (allSettings[fullKey]) deleteSetting(fullKey);
                });
              }}>
              <Trash2 className="w-3 h-3" /> Clear all {devName} defaults
            </Button>
          </CardContent>
        </Card>
      ))}

      {/* Raw Settings Viewer */}
      <Card>
        <CardHeader>
          <button
            className="w-full flex items-center gap-2 text-left"
            onClick={() => setShowRaw(!showRaw)}
          >
            <Database className="w-4 h-4 text-muted-foreground" />
            <CardTitle className="text-sm flex-1">All Stored Settings</CardTitle>
            <Badge variant="outline" className="text-[9px]">{Object.keys(allSettings).length}</Badge>
            {showRaw ? <ChevronUp className="w-4 h-4 text-muted-foreground" /> : <ChevronDown className="w-4 h-4 text-muted-foreground" />}
          </button>
        </CardHeader>
        {showRaw && (
          <CardContent>
            {Object.keys(allSettings).length === 0 ? (
              <p className="text-sm text-muted-foreground">No settings stored</p>
            ) : (
              <div className="space-y-1">
                {Object.entries(allSettings).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => (
                  <div key={k} className="flex items-center gap-2 text-xs group">
                    <code className="font-mono text-muted-foreground shrink-0">{k}</code>
                    <span className="text-foreground truncate flex-1">{v}</span>
                    <Button size="sm" variant="ghost"
                      className="h-5 w-5 p-0 opacity-0 group-hover:opacity-100 text-red-400"
                      onClick={() => deleteSetting(k)}>
                      <Trash2 className="w-3 h-3" />
                    </Button>
                  </div>
                ))}
              </div>
            )}
            <div className="flex gap-2 mt-3">
              <Button size="sm" variant="ghost" className="h-7 text-xs gap-1" onClick={loadSettings}>
                <RotateCw className="w-3 h-3" /> Reload
              </Button>
            </div>
          </CardContent>
        )}
      </Card>
    </div>
  );
}
