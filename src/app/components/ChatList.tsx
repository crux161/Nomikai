import { useNavigate, useParams } from 'react-router';
import { Search, MessageSquarePlus, Settings, Users, Link as LinkIcon, Copy } from 'lucide-react';
import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

import { Input } from './ui/input';
import { Button } from './ui/button';
import { ChatListItem } from './ChatListItem';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "./ui/dialog";

// Make sure your import paths match where you moved these files
import { useChatStore } from '../../core/store/chatStore';
import { chats } from '../../core/data/mockData';

export function ChatList() {
  const navigate = useNavigate();
  const { chatId } = useParams();
  
  // UI State
  const [searchQuery, setSearchQuery] = useState('');
  
  // P2P State
  const [peerId, setPeerId] = useState<string>('');
  const [peerCount, setPeerCount] = useState(0);
  const [isListening, setIsListening] = useState(false);
  const [targetAddress, setTargetAddress] = useState('');
  const [myAddresses, setMyAddresses] = useState<string[]>([]);

  const { currentUser } = useChatStore();

  const filteredChats = chats.filter((chat) => {
    const otherUser = chat.participants.find((p) => p.id !== currentUser.id);
    return otherUser?.name.toLowerCase().includes(searchQuery.toLowerCase());
  });

  // --- P2P Initialization ---
  useEffect(() => {
    let unlistenDiscovery: () => void;
    let unlistenStatus: () => void;

    async function initP2P() {
      // 1. Get our own Identity
      try {
        const id = await invoke<string>('get_peer_id');
        setPeerId(id);
        setIsListening(true);
      } catch (e) {
        console.error("Failed to get Peer ID", e);
      }

      // 2. Listen for Peer Discovery (Automatic mDNS)
      unlistenDiscovery = await listen('peer-discovery', () => {
        setPeerCount(prev => prev + 1);
      });

      // 3. Listen for Status Updates (To catch our own IP addresses)
      unlistenStatus = await listen<string>('p2p-status', (event) => {
        const msg = event.payload;
        if (msg.includes("Listening on")) {
          // Parse out the address from the log message
          const addr = msg.replace("Listening on ", "").trim();
          setMyAddresses(prev => {
            if (prev.includes(addr)) return prev;
            return [...prev, addr];
          });
        }
      });
    }
    
    initP2P();

    return () => {
      if (unlistenDiscovery) unlistenDiscovery();
      if (unlistenStatus) unlistenStatus();
    };
  }, []);

  // --- Actions ---

  const handleConnect = async () => {
    if (!targetAddress) return;
    try {
      await invoke('connect_to_peer', { address: targetAddress.trim() });
      setTargetAddress('');
      alert("Dial command sent successfully!");
    } catch (e) {
      console.error(e);
      alert("Failed to dial: " + e);
    }
  };

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

          <div className="flex gap-1">
            {/* Connection Manager Dialog */}
            <Dialog>
              <DialogTrigger asChild>
                <Button variant="ghost" size="icon" className="text-white hover:bg-blue-600">
                  <LinkIcon className="w-5 h-5" />
                </Button>
              </DialogTrigger>
              <DialogContent className="bg-white sm:max-w-md">
                <DialogHeader>
                  <DialogTitle>P2P Connection Manager</DialogTitle>
                </DialogHeader>
                
                <div className="space-y-6 py-4">
                  {/* Manual Connect */}
                  <div className="space-y-2">
                    <p className="text-sm font-medium text-gray-700">Connect to Peer</p>
                    <div className="flex gap-2">
                      <Input 
                        placeholder="/ip4/192.168.1.X/tcp/XXXX" 
                        value={targetAddress}
                        onChange={e => setTargetAddress(e.target.value)}
                        className="font-mono text-xs"
                      />
                      <Button onClick={handleConnect} size="sm">Connect</Button>
                    </div>
                  </div>

                  {/* My Addresses */}
                  <div className="space-y-2">
                     <p className="text-sm font-medium text-gray-700">My Addresses (Share these)</p>
                     <div className="bg-gray-100 p-2 rounded-md text-xs font-mono break-all space-y-1 max-h-40 overflow-y-auto">
                       {myAddresses.length === 0 ? (
                         <span className="text-gray-400">Waiting for network...</span>
                       ) : (
                         myAddresses.map((addr, i) => (
                           <div key={i} className="flex justify-between items-center group hover:bg-gray-200 p-1 rounded">
                             <span className="truncate mr-2">{addr}</span>
                             <Button 
                               variant="ghost" 
                               size="icon" 
                               className="h-5 w-5 opacity-0 group-hover:opacity-100"
                               onClick={() => {
                                 navigator.clipboard.writeText(addr);
                                 // Optional: Show a toast here
                               }}
                             >
                               <Copy className="w-3 h-3" />
                             </Button>
                           </div>
                         ))
                       )}
                     </div>
                  </div>
                </div>
              </DialogContent>
            </Dialog>

            <Button variant="ghost" size="icon" className="text-white hover:bg-blue-600">
              <Settings className="w-5 h-5" />
            </Button>
          </div>
        </div>
        
        {/* Search Bar */}
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
