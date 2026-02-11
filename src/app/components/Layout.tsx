import { Outlet } from 'react-router';
import { ChatList } from './ChatList';

export function Layout() {
  return (
    <div className="flex h-screen overflow-hidden">
      <ChatList />
      <Outlet />
    </div>
  );
}
