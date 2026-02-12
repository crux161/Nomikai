import { useRef, useEffect, useState } from 'react';
import { useParams } from 'react-router';
import { Send, Image, Video, Smile, MoreVertical } from 'lucide-react';
import { listen } from '@tauri-apps/api/event'; // <--- NEW IMPORT

import { Button } from './ui/button';
import { Input } from './ui/input';
import { MessageBubble } from './MessageBubble';
import { useChatStore } from '../../core/store/chatStore';
import { chats } from '../../core/data/mockData'; 
import { Message } from '../../core/types';

import { invoke } from '@tauri-apps/api/core';

export function ChatView() {
  const { chatId } = useParams();
  const { messages, currentUser, addMessage } = useChatStore();
  const [newMessage, setNewMessage] = useState('');
  
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const videoInputRef = useRef<HTMLInputElement>(null);

  const chat = chats.find((c) => c.id === chatId);
  const chatMessages = messages.filter((m) => m.chatId === chatId);
  const otherUser = chat?.participants.find((p) => p.id !== currentUser.id);

  // --- NEW: Event Listener for Rust Stream ---
  //

  const handleSendMessage = async () => {
    if (!newMessage.trim()) return;

    // 1. Optimistic Update: Show the message immediately in our own UI
    const message: Message = {
      id: `msg-${Date.now()}`,
      chatId: chatId!,
      senderId: currentUser.id,
      type: 'text',
      content: newMessage,
      timestamp: new Date(),
    };
    addMessage(message);
    setNewMessage('');

    // 2. Send to the P2P Network via Rust
    try {
      await invoke('send_chat_message', { message: message.content });
    } catch (error) {
      console.error("Failed to publish message:", error);
    }
  };

  useEffect(() => {
    let unlisten: (() => void) | undefined;

    const setupListener = async () => {
      // Listen for 'stream-event' from Rust
      unlisten = await listen<string>('stream-event', (event) => {
        console.log('Received from Rust:', event.payload);
        
        // Push to the store
        // We use a safe check for chatId to avoid errors if user is on home screen
        if (chatId) {
            addMessage({
              id: `stream-${Date.now()}`,
              chatId: chatId, 
              senderId: 'system-stream', // distinct ID for styling if needed
              type: 'text',
              content: event.payload,
              timestamp: new Date(),
            });
        }
      });
    };

    setupListener();

    // Cleanup when component unmounts
    return () => {
      if (unlisten) unlisten();
    };
  }, [addMessage, chatId]);
  // -------------------------------------------

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [chatMessages]);

  if (!chat || !otherUser) {
    return (
      <div className="flex-1 flex items-center justify-center bg-gradient-to-br from-blue-50 to-cyan-50">
        <div className="text-center">
          <h2 className="text-2xl font-semibold text-gray-700 mb-2">Select a chat to start messaging</h2>
          <p className="text-gray-500">Choose from your existing conversations</p>
        </div>
      </div>
    );
  }


  const handleKeyPress = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
    }
  };

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>, type: 'image' | 'video') => {
    const file = e.target.files?.[0];
    if (file) {
      const reader = new FileReader();
      reader.onload = (event) => {
        const message: Message = {
          id: `msg-${Date.now()}`,
          chatId: chatId!,
          senderId: currentUser.id,
          type,
          content: event.target?.result as string,
          timestamp: new Date(),
        };
        addMessage(message);
      };
      reader.readAsDataURL(file);
    }
  };

  return (
    <div className="flex-1 flex flex-col h-screen">
      <div className="bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="relative">
            <img src={otherUser.avatar} alt={otherUser.name} className="w-10 h-10 rounded-full object-cover" />
            <div className={`absolute bottom-0 right-0 w-3 h-3 rounded-full border-2 border-white ${otherUser.status === 'online' ? 'bg-green-500' : otherUser.status === 'away' ? 'bg-yellow-500' : 'bg-gray-400'}`} />
          </div>
          <div>
            <h2 className="font-semibold">{otherUser.name}</h2>
            <p className="text-xs text-gray-500 capitalize">{otherUser.status}</p>
          </div>
        </div>
        <Button variant="ghost" size="icon"><MoreVertical className="w-5 h-5" /></Button>
      </div>

      <div className="flex-1 overflow-y-auto bg-gradient-to-br from-blue-50 to-cyan-50 px-6 py-4">
        {chatMessages.map((message) => {
          const sender = chat.participants.find((p) => p.id === message.senderId);
          // If sender is undefined (e.g. system-stream), mock a fallback
          const displayName = sender ? sender.name : "System Stream";
          const displayAvatar = sender ? sender.avatar : ""; 
          
          return (
            <MessageBubble
              key={message.id}
              message={message}
              isCurrentUser={message.senderId === currentUser.id}
              senderName={displayName}
              senderAvatar={displayAvatar}
            />
          );
        })}
        <div ref={messagesEndRef} />
      </div>

      <div className="bg-white border-t border-gray-200 px-6 py-4">
        <div className="flex items-center gap-2">
          <input type="file" ref={fileInputRef} onChange={(e) => handleFileUpload(e, 'image')} accept="image/*" className="hidden" />
          <input type="file" ref={videoInputRef} onChange={(e) => handleFileUpload(e, 'video')} accept="video/*" className="hidden" />
          
          <Button variant="ghost" size="icon" onClick={() => fileInputRef.current?.click()} className="text-blue-600 hover:text-blue-700 hover:bg-blue-50">
            <Image className="w-5 h-5" />
          </Button>
          <Button variant="ghost" size="icon" onClick={() => videoInputRef.current?.click()} className="text-blue-600 hover:text-blue-700 hover:bg-blue-50">
            <Video className="w-5 h-5" />
          </Button>
          <Button variant="ghost" size="icon" className="text-blue-600 hover:text-blue-700 hover:bg-blue-50">
            <Smile className="w-5 h-5" />
          </Button>
          <Input value={newMessage} onChange={(e) => setNewMessage(e.target.value)} onKeyPress={handleKeyPress} placeholder="Type a message..." className="flex-1 border-gray-300 focus:border-blue-500 focus:ring-blue-500" />
          <Button onClick={handleSendMessage} disabled={!newMessage.trim()} className="bg-gradient-to-r from-blue-500 to-blue-600 hover:from-blue-600 hover:to-blue-700">
            <Send className="w-5 h-5" />
          </Button>
        </div>
      </div>
    </div>
  );
}
