import { useNavigate, useParams } from 'react-router';
import { Search, MessageSquarePlus, Settings, Network, Users } from 'lucide-react'; // Add Network, Users icons
import { Input } from './ui/input';
import { Button } from './ui/button';
import { ChatListItem } from './ChatListItem';
import { useState, useEffect } from 'react'; // Add useEffect
import { invoke } from '@tauri-apps/api/core'; // Import invoke
import { listen } from '@tauri-apps/api/event'; // Import listen

import { useChatStore } from '../../core/store/chatStore';
import { chats } from '../../core/data/mockData';

export function ChatList() {
  const navigate = useNavigate();
  const { chatId } = useParams();
  const [searchQuery, setSearchQuery] = useState('');
  
  // New P2P State
  const [peerId, setPeerId] = useState<string>('');
  const [peerCount, setPeerCount] = useState(0);
  const [isListening, setIsListening] = useState(false);

  const { currentUser } = useChatStore();

  const filteredChats = chats.filter((chat) => {
    const otherUser = chat.participants.find((p) => p.id !== currentUser.id);
    return otherUser?.name.toLowerCase().includes(searchQuery.toLowerCase());
  });

  // --- P2P Initialization ---
  useEffect(() => {
    async function initP2P() {
      // 1. Get our own Identity
      try {
        const id = await invoke<string>('get_peer_id');
        setPeerId(id);
        setIsListening(true);
      } catch (e) {
        console.error("Failed to get Peer ID", e);
      }

      // 2. Listen for Peer Discovery
      const unlistenDiscovery = await listen('peer-discovery', () => {
        setPeerCount(prev => prev + 1);
      });

      return () => {
        unlistenDiscovery();
      };
    }
    
    initP2P();
  }, []);

  // Helper to truncate long Peer IDs (e.g., 12D3K... -> 12D3...K8s)
  const formatPeerId = (id: string) => {
    if (!id) return 'Initializing...';
    return `${id.substring(0, 6)}...${id.substring(id.length - 4)}`;
  };

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
              
              {/* P2P Status Indicator */}
              <div className="flex flex-col gap-0.5">
                <div className="flex items-center gap-1.5">
                  <span className="relative flex h-2 w-2">
                    <span className={`animate-ping absolute inline-flex h-full w-full rounded-full opacity-75 ${isListening ? 'bg-green-400' : 'bg-orange-400'}`}></span>
                    <span className={`relative inline-flex rounded-full h-2 w-2 ${isListening ? 'bg-green-400' : 'bg-orange-400'}`}></span>
                  </span>
                  <p className="text-xs text-blue-100 font-mono opacity-90">
                    {formatPeerId(peerId)}
                  </p>
                </div>
                
                {/* Peer Count */}
                {peerCount > 0 && (
                   <div className="flex items-center gap-1 text-xs text-blue-200">
                     <Users className="w-3 h-3" />
                     <span>{peerCount} peers active</span>
                   </div>
                )}
              </div>

            </div>
          </div>
          <Button variant="ghost" size="icon" className="text-white hover:bg-blue-600">
            <Settings className="w-5 h-5" />
          </Button>
        </div>
        
        {/* Search Bar (Existing) */}
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

      {/* Existing Chat List... */}
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

      <div className="p-4 border-t border-gray-200">
        <Button className="w-full bg-gradient-to-r from-blue-500 to-blue-600 hover:from-blue-600 hover:to-blue-700">
          <MessageSquarePlus className="w-5 h-5 mr-2" />
          New Chat
        </Button>
      </div>
    </div>
  );
}
