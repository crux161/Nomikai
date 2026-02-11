import { createBrowserRouter } from 'react-router';
import { Layout } from './components/Layout';
import { ChatView } from './components/ChatView';

export const router = createBrowserRouter([
  {
    path: '/',
    Component: Layout,
    children: [
      {
        index: true,
        Component: ChatView,
      },
      {
        path: 'chat/:chatId',
        Component: ChatView,
      },
    ],
  },
]);
