import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Monitor, Wifi, WifiOff, RotateCw, Signal } from 'lucide-react';
import { useApp } from '@/lib/store';
import { api, appendDevice } from '@/lib/api';

const TYPE_COLORS: Record<string, string> = {
  server: 'bg-blue-500/15 text-blue-400 border-blue-500/30',
  mac: 'bg-violet-500/15 text-violet-400 border-violet-500/30',
  android: 'bg-green-500/15 text-green-400 border-green-500/30',
  ios_ish: 'bg-orange-500/15 text-orange-400 border-orange-500/30',
  windows: 'bg-cyan-500/15 text-cyan-400 border-cyan-500/30',
};

export default function Devices() {
  const { devices, device: activeDevice, setDevice, refresh } = useApp();

  const pingDevice = async (name: string) => {
    await api(appendDevice(`/devices/${name}/ping`, ''), { method: 'POST' }).catch(() => {});
    refresh();
  };

  const pingAll = async () => {
    await api('/devices/ping-all', { method: 'POST' }).catch(() => {});
    refresh();
  };

  return (
    <div className="p-4 md:p-6 space-y-4">
      <div className="flex items-center gap-2">
        <Monitor className="w-5 h-5" />
        <h1 className="text-lg font-bold flex-1">Devices ({devices.length})</h1>
        <Button variant="outline" size="sm" className="gap-1 h-7 text-xs" onClick={pingAll}>
          <Signal className="w-3 h-3" /> Ping All
        </Button>
        <Button variant="ghost" size="icon" onClick={refresh}><RotateCw className="w-4 h-4" /></Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {devices.map(d => (
          <Card
            key={d.name}
            className={`cursor-pointer transition-all hover:bg-accent/50 ${
              d.name === activeDevice ? 'ring-2 ring-primary' : ''
            }`}
            onClick={() => setDevice(d.name)}
          >
            <CardContent className="p-4 flex items-start gap-3">
              <div className={`p-2 rounded-lg ${d.online ? 'bg-green-500/10' : 'bg-zinc-500/10'}`}>
                {d.online ? (
                  <Wifi className="w-4 h-4 text-green-400" />
                ) : (
                  <WifiOff className="w-4 h-4 text-zinc-500" />
                )}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <p className="font-medium text-sm">{d.name}</p>
                  {d.name === activeDevice && (
                    <Badge variant="default" className="text-[9px] px-1.5 py-0">active</Badge>
                  )}
                </div>
                <div className="flex items-center gap-2 mt-1">
                  <Badge variant="outline" className={`text-[10px] ${TYPE_COLORS[d.type] || ''}`}>
                    {d.type}
                  </Badge>
                  {d.tailscale_ip && (
                    <span className="text-[10px] text-muted-foreground font-mono">{d.tailscale_ip}</span>
                  )}
                </div>
              </div>
              <Button
                variant="ghost"
                size="icon"
                className="h-7 w-7"
                onClick={e => { e.stopPropagation(); pingDevice(d.name); }}
              >
                <Signal className="w-3.5 h-3.5" />
              </Button>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
