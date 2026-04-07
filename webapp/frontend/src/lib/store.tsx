import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from 'react';
import { api, appendDevice, type Device, type StatusData } from './api';

interface AppCtx {
  device: string;
  setDevice: (d: string) => void;
  cli: string;
  setCli: (c: string) => void;
  devices: Device[];
  status: StatusData | null;
  refresh: () => void;
}

const Ctx = createContext<AppCtx | null>(null);

export function AppProvider({ children }: { children: ReactNode }) {
  const [device, setDeviceState] = useState('');
  const [cli, setCliState] = useState('claude');
  const [devices, setDevices] = useState<Device[]>([]);
  const [status, setStatus] = useState<StatusData | null>(null);

  const setDevice = useCallback((d: string) => {
    setDeviceState(d);
    // Sync remote device DB before reading (fire-and-forget)
    api('/sync-device-db?device=' + encodeURIComponent(d), { method: 'POST' }).catch(() => {});
    api('/settings/default_device', {
      method: 'PUT',
      body: JSON.stringify({ value: d }),
    }).catch(() => {});
  }, []);

  const setCli = useCallback((c: string) => {
    setCliState(c);
    api('/settings/default_cli', {
      method: 'PUT',
      body: JSON.stringify({ value: c }),
    }).catch(() => {});
  }, []);

  const refresh = useCallback(() => {
    api<{ devices: Device[] }>('/devices/refresh')
      .then(r => {
        setDevices(r.devices || []);
        // auto-select first if none
        setDeviceState(prev => {
          if (!prev && r.devices?.length) return r.devices[0].name;
          return prev;
        });
      })
      .catch(() => {});
    api<StatusData>('/status').then(setStatus).catch(() => {});
  }, []);

  // Load saved settings on mount
  useEffect(() => {
    api<{ value?: string }>('/settings/default_device')
      .then(r => { if (r.value) setDeviceState(r.value); })
      .catch(() => {});
    api<{ value?: string }>('/settings/default_cli')
      .then(r => { if (r.value) setCliState(r.value); })
      .catch(() => {});
    refresh();
    const id = setInterval(refresh, 30000);
    return () => clearInterval(id);
  }, [refresh]);

  return (
    <Ctx.Provider value={{ device, setDevice, cli, setCli, devices, status, refresh }}>
      {children}
    </Ctx.Provider>
  );
}

export function useApp() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useApp must be inside AppProvider');
  return ctx;
}

export function useDeviceApi() {
  const { device } = useApp();
  return useCallback(
    (path: string) => appendDevice(path, device),
    [device],
  );
}
