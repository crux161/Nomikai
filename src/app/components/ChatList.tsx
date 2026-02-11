import { useNavigate, useParams } from 'react-router'; // 'react-router' v7
import { Search, MessageSquarePlus, Settings } from 'lucide-react';
import { Input } from './ui/input';
import { Button } from './ui/button';
import { ChatListItem } from './ChatListItem';
import { useState } from 'react';

// Use store for currentUser, but keep static chats for now
import { useChatStore } from '../../core/store/chatStore';
import { chats } from '../../core/data/mockData';

export function ChatList() {
  const navigate = useNavigate();
  const { chatId } = useParams();
  const [searchQuery, setSearchQuery] = useState('');
  
  // Get currentUser from store
  const { currentUser } = useChatStore();

  const filteredChats = chats.filter((chat) => {
    const otherUser = chat.participants.find((p) => p.id !== currentUser.id);
    return otherUser?.name.toLowerCase().includes(searchQuery.toLowerCase());
  });

  return (
    <div className="w-80 bg-white border-r border-gray-200 flex flex-col h-screen">
      {/* Header */}
      <div className="p-4 bg-gradient-to-r from-blue-500 to-blue-600">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-3">
            <img
              src={currentUser.avatar}
              alt={currentUser.name}
              className="w-10 h-10 rounded-full object-cover border-2 border-white"
            />
            <div>
              <h1 className="font-semibold text-white">Nomikai</h1>
              <p className="text-xs text-blue-100">{currentUser.name}</p>
            </div>
          </div>
          <Button variant="ghost" size="icon" className="text-white hover:bg-blue-600">
            <Settings className="w-5 h-5" />
          </Button>
        </div>
        
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
          <Input
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Search conversations..."
            className="pl-10 bg-white border-0 focus:ring-2 focus:ring-blue-300"
          />
        </div>
      </div>

      {/* Chat List */}
      <div className="flex-1 overflow-y-auto">
        {filteredChats.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-gray-500">
            <MessageSquarePlus className="w-12 h-12 mb-2 text-gray-400" />
            <p>No conversations found</p>
          </div>
        ) : (
          <div className="divide-y divide-gray-100">
            {filteredChats.map((chat) => (
              <ChatListItem
                key={chat.id}
                chat={chat}
                currentUserId={currentUser.id}
                isActive={chat.id === chatId}
                onClick={() => navigate(`/chat/${chat.id}`)}
              />
            ))}
          </div>
        )}
      </div>

      {/* New Chat Button */}
      <div className="p-4 border-t border-gray-200">
        <Button className="w-full bg-gradient-to-r from-blue-500 to-blue-600 hover:from-blue-600 hover:to-blue-700">
          <MessageSquarePlus className="w-5 h-5 mr-2" />
          New Chat
        </Button>
      </div>
    </div>
  );
}
