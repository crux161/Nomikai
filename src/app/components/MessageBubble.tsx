import { Message } from '../types';
import { Play } from 'lucide-react';
import { useState } from 'react';

interface MessageBubbleProps {
  message: Message;
  isCurrentUser: boolean;
  senderName: string;
  senderAvatar: string;
}

export function MessageBubble({ message, isCurrentUser, senderName, senderAvatar }: MessageBubbleProps) {
  const [isVideoPlaying, setIsVideoPlaying] = useState(false);

  const formatTime = (date: Date) => {
    return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
  };

  return (
    <div className={`flex gap-2 mb-4 ${isCurrentUser ? 'flex-row-reverse' : 'flex-row'}`}>
      <img
        src={senderAvatar}
        alt={senderName}
        className="w-8 h-8 rounded-full object-cover flex-shrink-0"
      />
      
      <div className={`flex flex-col ${isCurrentUser ? 'items-end' : 'items-start'} max-w-[70%]`}>
        {!isCurrentUser && (
          <span className="text-xs text-gray-600 mb-1 px-2">{senderName}</span>
        )}
        
        <div className={`rounded-2xl px-4 py-2 ${
          isCurrentUser
            ? 'bg-gradient-to-r from-blue-500 to-blue-600 text-white'
            : 'bg-white border border-gray-200'
        }`}>
          {message.type === 'text' && (
            <p className="break-words">{message.content}</p>
          )}
          
          {message.type === 'image' && (
            <img
              src={message.content}
              alt="Shared image"
              className="rounded-lg max-w-full h-auto"
            />
          )}
          
          {message.type === 'video' && (
            <div className="relative rounded-lg overflow-hidden">
              {!isVideoPlaying ? (
                <div className="relative">
                  <video
                    src={message.content}
                    className="w-full max-w-sm rounded-lg"
                    preload="metadata"
                  />
                  <button
                    onClick={() => setIsVideoPlaying(true)}
                    className="absolute inset-0 flex items-center justify-center bg-black bg-opacity-30 hover:bg-opacity-40 transition-all"
                  >
                    <div className="w-16 h-16 rounded-full bg-white bg-opacity-90 flex items-center justify-center">
                      <Play className="w-8 h-8 text-blue-600 ml-1" fill="currentColor" />
                    </div>
                  </button>
                </div>
              ) : (
                <video
                  src={message.content}
                  controls
                  autoPlay
                  className="w-full max-w-sm rounded-lg"
                  onEnded={() => setIsVideoPlaying(false)}
                />
              )}
            </div>
          )}
        </div>
        
        <span className="text-xs text-gray-500 mt-1 px-2">
          {formatTime(message.timestamp)}
        </span>
      </div>
    </div>
  );
}
