import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { AppProvider } from '@/lib/store';
import { Toaster } from '@/components/ui/sonner';
import Layout from '@/components/layout';
import Dashboard from '@/pages/dashboard';
import Tasks from '@/pages/tasks';
import Jobs from '@/pages/jobs';
import Launch from '@/pages/launch';
import Devices from '@/pages/devices';
import Settings from '@/pages/settings';

export default function App() {
  return (
    <AppProvider>
      <BrowserRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<Dashboard />} />
            <Route path="tasks" element={<Tasks />} />
            <Route path="jobs" element={<Jobs />} />
            <Route path="jobs/launch" element={<Launch />} />
            <Route path="devices" element={<Devices />} />
            <Route path="settings" element={<Settings />} />
          </Route>
        </Routes>
      </BrowserRouter>
      <Toaster />
    </AppProvider>
  );
}
