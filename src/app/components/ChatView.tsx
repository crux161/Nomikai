import { useRef, useEffect, useState } from 'react';
import { useParams } from 'react-router'; // 'react-router' v7
import { Send, Image, Video, Smile, MoreVertical } from 'lucide-react';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { MessageBubble } from './MessageBubble';
// Import the store instead of static messages
import { useChatStore } from '../../core/store/chatStore';
// Import static "chats" for metadata, but use store for "currentUser"
import { chats } from '../../core/data/mockData'; 
import { Message } from '../../core/types';

export function ChatView() {
  const { chatId } = useParams();
  
  // Connect to the store
  const { messages, currentUser, addMessage } = useChatStore();
  
  const [newMessage, setNewMessage] = useState('');
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const videoInputRef = useRef<HTMLInputElement>(null);

  // Derive state from the store
  const chat = chats.find((c) => c.id === chatId);
  const chatMessages = messages.filter((m) => m.chatId === chatId);
  const otherUser = chat?.participants.find((p) => p.id !== currentUser.id);

  // Auto-scroll to bottom when new messages arrive
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

  const handleSendMessage = () => {
    if (!newMessage.trim()) return;

    const message: Message = {
      id: `msg-${Date.now()}`,
      chatId: chatId!,
      senderId: currentUser.id,
      type: 'text',
      content: newMessage,
      timestamp: new Date(),
    };

    addMessage(message); // Uses the store action
    setNewMessage('');
  };

  const handleKeyPress = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
    }
  };

  // Helper to handle file uploads generically
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
      {/* Chat Header */}
      <div className="bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="relative">
            <img
              src={otherUser.avatar}
              alt={otherUser.name}
              className="w-10 h-10 rounded-full object-cover"
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
          <div>
            <h2 className="font-semibold">{otherUser.name}</h2>
            <p className="text-xs text-gray-500 capitalize">{otherUser.status}</p>
          </div>
        </div>
        
        <Button variant="ghost" size="icon">
          <MoreVertical className="w-5 h-5" />
        </Button>
      </div>

      {/* Messages Area */}
      <div className="flex-1 overflow-y-auto bg-gradient-to-br from-blue-50 to-cyan-50 px-6 py-4">
        {chatMessages.map((message) => {
          const sender = chat.participants.find((p) => p.id === message.senderId);
          return (
            <MessageBubble
              key={message.id}
              message={message}
              isCurrentUser={message.senderId === currentUser.id}
              senderName={sender?.name || ''}
              senderAvatar={sender?.avatar || ''}
            />
          );
        })}
        <div ref={messagesEndRef} />
      </div>

      {/* Input Area */}
      <div className="bg-white border-t border-gray-200 px-6 py-4">
        <div className="flex items-center gap-2">
          <input
            type="file"
            ref={fileInputRef}
            onChange={(e) => handleFileUpload(e, 'image')}
            accept="image/*"
            className="hidden"
          />
          <input
            type="file"
            ref={videoInputRef}
            onChange={(e) => handleFileUpload(e, 'video')}
            accept="video/*"
            className="hidden"
          />
          
          <Button
            variant="ghost"
            size="icon"
            onClick={() => fileInputRef.current?.click()}
            className="text-blue-600 hover:text-blue-700 hover:bg-blue-50"
          >
            <Image className="w-5 h-5" />
          </Button>
          
          <Button
            variant="ghost"
            size="icon"
            onClick={() => videoInputRef.current?.click()}
            className="text-blue-600 hover:text-blue-700 hover:bg-blue-50"
          >
            <Video className="w-5 h-5" />
          </Button>
          
          <Button
            variant="ghost"
            size="icon"
            className="text-blue-600 hover:text-blue-700 hover:bg-blue-50"
          >
            <Smile className="w-5 h-5" />
          </Button>

          <Input
            value={newMessage}
            onChange={(e) => setNewMessage(e.target.value)}
            onKeyPress={handleKeyPress}
            placeholder="Type a message..."
            className="flex-1 border-gray-300 focus:border-blue-500 focus:ring-blue-500"
          />

          <Button
            onClick={handleSendMessage}
            disabled={!newMessage.trim()}
            className="bg-gradient-to-r from-blue-500 to-blue-600 hover:from-blue-600 hover:to-blue-700"
          >
            <Send className="w-5 h-5" />
          </Button>
        </div>
      </div>
    </div>
  );
}
