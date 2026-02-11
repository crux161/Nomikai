import { Chat, User } from '../types';
import { Badge } from './ui/badge';

interface ChatListItemProps {
  chat: Chat;
  currentUserId: string;
  isActive?: boolean;
  onClick: () => void;
}

export function ChatListItem({ chat, currentUserId, isActive, onClick }: ChatListItemProps) {
  const otherUser = chat.participants.find((p) => p.id !== currentUserId) as User;
  
  const formatTime = (date: Date) => {
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    
    if (days === 0) {
      return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
    } else if (days === 1) {
      return 'Yesterday';
    } else if (days < 7) {
      return date.toLocaleDateString('en-US', { weekday: 'short' });
    } else {
      return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    }
  };

  const getMessagePreview = () => {
    if (!chat.lastMessage) return '';
    switch (chat.lastMessage.type) {
      case 'text':
        return chat.lastMessage.content;
      case 'image':
        return '[Image]';
      case 'video':
        return '[Video]';
      default:
        return '';
    }
  };

  return (
    <div
      onClick={onClick}
      className={`flex items-center gap-3 p-3 cursor-pointer transition-colors hover:bg-blue-50 ${
        isActive ? 'bg-blue-100' : ''
      }`}
    >
      <div className="relative flex-shrink-0">
        <img
          src={otherUser.avatar}
          alt={otherUser.name}
          className="w-12 h-12 rounded-full object-cover"
        />
        <div
          className={`absolute bottom-0 right-0 w-3 h-3 rounded-full border-2 border-white ${
            otherUser.status === 'online'
              ? 'bg-green-500'
              : otherUser.status === 'away'
              ? 'bg-yellow-500'
              : 'bg-gray-400'
          }`}
        />
      </div>
      
      <div className="flex-1 min-w-0">
        <div className="flex items-center justify-between mb-1">
          <h3 className="font-semibold text-sm truncate">{otherUser.name}</h3>
          {chat.lastMessage && (
            <span className="text-xs text-gray-500 flex-shrink-0 ml-2">
              {formatTime(chat.lastMessage.timestamp)}
            </span>
          )}
        </div>
        <div className="flex items-center justify-between">
          <p className="text-sm text-gray-600 truncate">{getMessagePreview()}</p>
          {chat.unreadCount > 0 && (
            <Badge className="ml-2 bg-red-500 hover:bg-red-600 text-white h-5 min-w-5 px-1.5">
              {chat.unreadCount}
            </Badge>
          )}
        </div>
      </div>
    </div>
  );
}
