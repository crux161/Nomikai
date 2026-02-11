import { User, Message, Chat } from '../types';

export const currentUser: User = {
  id: 'user-1',
  name: 'You',
  avatar: 'https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?w=100&h=100&fit=crop',
  status: 'online',
};

export const users: User[] = [
  {
    id: 'user-2',
    name: 'Alice Chen',
    avatar: 'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=100&h=100&fit=crop',
    status: 'online',
  },
  {
    id: 'user-3',
    name: 'Bob Zhang',
    avatar: 'https://images.unsplash.com/photo-1599566150163-29194dcaad36?w=100&h=100&fit=crop',
    status: 'away',
  },
  {
    id: 'user-4',
    name: 'Carol Wang',
    avatar: 'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=100&h=100&fit=crop',
    status: 'online',
  },
  {
    id: 'user-5',
    name: 'David Liu',
    avatar: 'https://images.unsplash.com/photo-1570295999919-56ceb5ecca61?w=100&h=100&fit=crop',
    status: 'offline',
  },
  {
    id: 'user-6',
    name: 'Emma Yang',
    avatar: 'https://images.unsplash.com/photo-1544005313-94ddf0286df2?w=100&h=100&fit=crop',
    status: 'online',
  },
];

export const messages: Message[] = [
  // Chat with Alice
  {
    id: 'msg-1',
    chatId: 'chat-1',
    senderId: 'user-2',
    type: 'text',
    content: 'Hey! How are you doing?',
    timestamp: new Date('2026-02-11T10:30:00'),
  },
  {
    id: 'msg-2',
    chatId: 'chat-1',
    senderId: 'user-1',
    type: 'text',
    content: "I'm doing great! Just working on a new project",
    timestamp: new Date('2026-02-11T10:31:00'),
  },
  {
    id: 'msg-3',
    chatId: 'chat-1',
    senderId: 'user-2',
    type: 'text',
    content: 'That sounds exciting! What kind of project?',
    timestamp: new Date('2026-02-11T10:32:00'),
  },
  {
    id: 'msg-4',
    chatId: 'chat-1',
    senderId: 'user-1',
    type: 'image',
    content: 'https://images.unsplash.com/photo-1498050108023-c5249f4df085?w=400&h=300&fit=crop',
    timestamp: new Date('2026-02-11T10:33:00'),
  },
  {
    id: 'msg-5',
    chatId: 'chat-1',
    senderId: 'user-1',
    type: 'text',
    content: 'Building a chat application! Here\'s a screenshot',
    timestamp: new Date('2026-02-11T10:33:30'),
  },
  {
    id: 'msg-6',
    chatId: 'chat-1',
    senderId: 'user-2',
    type: 'video',
    content: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    timestamp: new Date('2026-02-11T10:35:00'),
  },
  {
    id: 'msg-7',
    chatId: 'chat-1',
    senderId: 'user-2',
    type: 'text',
    content: 'Check out this video I made! 🎥',
    timestamp: new Date('2026-02-11T10:35:30'),
  },
  // Chat with Bob
  {
    id: 'msg-8',
    chatId: 'chat-2',
    senderId: 'user-3',
    type: 'text',
    content: 'Are we still meeting tomorrow?',
    timestamp: new Date('2026-02-10T15:20:00'),
  },
  {
    id: 'msg-9',
    chatId: 'chat-2',
    senderId: 'user-1',
    type: 'text',
    content: 'Yes! 10 AM at the usual place',
    timestamp: new Date('2026-02-10T15:25:00'),
  },
  // Chat with Carol
  {
    id: 'msg-10',
    chatId: 'chat-3',
    senderId: 'user-4',
    type: 'text',
    content: 'Thanks for your help earlier! 😊',
    timestamp: new Date('2026-02-10T12:00:00'),
  },
  {
    id: 'msg-11',
    chatId: 'chat-3',
    senderId: 'user-1',
    type: 'text',
    content: 'Anytime! Happy to help',
    timestamp: new Date('2026-02-10T12:05:00'),
  },
  // Chat with David
  {
    id: 'msg-12',
    chatId: 'chat-4',
    senderId: 'user-5',
    type: 'text',
    content: 'Did you see the latest update?',
    timestamp: new Date('2026-02-09T18:30:00'),
  },
  // Chat with Emma
  {
    id: 'msg-13',
    chatId: 'chat-5',
    senderId: 'user-6',
    type: 'image',
    content: 'https://images.unsplash.com/photo-1506744038136-46273834b3fb?w=400&h=300&fit=crop',
    timestamp: new Date('2026-02-11T09:00:00'),
  },
  {
    id: 'msg-14',
    chatId: 'chat-5',
    senderId: 'user-6',
    type: 'text',
    content: 'Look at this beautiful view! 🏔️',
    timestamp: new Date('2026-02-11T09:01:00'),
  },
  {
    id: 'msg-15',
    chatId: 'chat-5',
    senderId: 'user-1',
    type: 'text',
    content: 'Wow! Where is this?',
    timestamp: new Date('2026-02-11T09:05:00'),
  },
];

export const chats: Chat[] = [
  {
    id: 'chat-1',
    participants: [currentUser, users[0]],
    lastMessage: messages[6],
    unreadCount: 2,
  },
  {
    id: 'chat-2',
    participants: [currentUser, users[1]],
    lastMessage: messages[8],
    unreadCount: 0,
  },
  {
    id: 'chat-3',
    participants: [currentUser, users[2]],
    lastMessage: messages[10],
    unreadCount: 0,
  },
  {
    id: 'chat-4',
    participants: [currentUser, users[3]],
    lastMessage: messages[11],
    unreadCount: 1,
  },
  {
    id: 'chat-5',
    participants: [currentUser, users[4]],
    lastMessage: messages[14],
    unreadCount: 0,
  },
];
