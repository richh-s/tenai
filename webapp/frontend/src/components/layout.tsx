import { NavLink, Outlet } from 'react-router-dom';
import {
  LayoutDashboard,
  ListTodo,
  Cpu,
  Monitor,
  Settings,
} from 'lucide-react';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useApp } from '@/lib/store';

const NAV = [
  { to: '/', icon: LayoutDashboard, label: 'Dashboard' },
  { to: '/tasks', icon: ListTodo, label: 'Tasks' },
  { to: '/jobs', icon: Cpu, label: 'Jobs' },
  { to: '/devices', icon: Monitor, label: 'Devices' },
  { to: '/settings', icon: Settings, label: 'Settings' },
] as const;

export default function Layout() {
  const { device, setDevice, cli, setCli, devices } = useApp();

  return (
    <div className="flex h-dvh bg-background text-foreground">
      {/* Desktop Sidebar */}
      <aside className="hidden md:flex w-56 flex-col border-r border-border bg-card">
        <div className="p-4 border-b border-border">
          <h1 className="text-lg font-bold tracking-tight">⚡ TenAI</h1>
          <p className="text-xs text-muted-foreground">Control Plane</p>
          <Select value={device} onValueChange={setDevice}>
            <SelectTrigger className="mt-3 h-8 text-xs">
              <SelectValue placeholder="Select device…" />
            </SelectTrigger>
            <SelectContent>
              {devices.map(d => (
                <SelectItem key={d.name} value={d.name}>
                  <span className={`inline-block w-2 h-2 rounded-full mr-2 ${d.online ? 'bg-green-500' : 'bg-zinc-500'}`} />
                  {d.name}
                  <span className="ml-1 text-muted-foreground text-[10px]">{d.type}</span>
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <nav className="flex-1 p-2 space-y-0.5">
          {NAV.map(n => (
            <NavLink
              key={n.to}
              to={n.to}
              end={n.to === '/'}
              className={({ isActive }) =>
                `flex items-center gap-3 px-3 py-2 rounded-lg text-sm transition-colors ${
                  isActive
                    ? 'bg-accent text-accent-foreground font-medium'
                    : 'text-muted-foreground hover:text-foreground hover:bg-accent/50'
                }`
              }
            >
              <n.icon className="w-4 h-4" />
              {n.label}
            </NavLink>
          ))}
        </nav>
      </aside>

      {/* Main area */}
      <div className="flex-1 flex flex-col min-w-0">
        {/* Mobile top bar */}
        <header className="md:hidden flex items-center gap-2 px-3 py-2 border-b border-border bg-card">
          <span className="font-bold text-sm">⚡ TenAI</span>
          <div className="flex-1" />
          <Select value={device} onValueChange={setDevice}>
            <SelectTrigger className="h-8 w-28 text-xs">
              <SelectValue placeholder="Device" />
            </SelectTrigger>
            <SelectContent>
              {devices.map(d => (
                <SelectItem key={d.name} value={d.name}>
                  <span className={`inline-block w-1.5 h-1.5 rounded-full mr-1 ${d.online ? 'bg-green-500' : 'bg-zinc-500'}`} />
                  {d.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select value={cli} onValueChange={setCli}>
            <SelectTrigger className="h-8 w-24 text-xs">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="claude">Claude</SelectItem>
              <SelectItem value="gemini">Gemini</SelectItem>
              <SelectItem value="codex">Codex</SelectItem>
            </SelectContent>
          </Select>
        </header>

        {/* Page content */}
        <main className="flex-1 overflow-y-auto pb-16 md:pb-0">
          <Outlet />
        </main>

        {/* Mobile bottom nav */}
        <nav className="md:hidden fixed bottom-0 left-0 right-0 flex bg-card border-t border-border z-50 pb-[env(safe-area-inset-bottom)]">
          {NAV.map(n => (
            <NavLink
              key={n.to}
              to={n.to}
              end={n.to === '/'}
              className={({ isActive }) =>
                `flex-1 flex flex-col items-center gap-0.5 py-2 text-[10px] transition-colors ${
                  isActive ? 'text-primary' : 'text-muted-foreground'
                }`
              }
            >
              <n.icon className="w-5 h-5" />
              {n.label}
            </NavLink>
          ))}
        </nav>
      </div>
    </div>
  );
}
