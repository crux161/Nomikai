import { create } from 'zustand';
import { Message, User } from '../types';
import { messages as initialMessages, currentUser as initialUser } from '../data/mockData';

interface ChatState {
  currentUser: User;
  messages: Message[];
  
  // Actions
  addMessage: (msg: Message) => void;
  updateStatus: (status: User['status']) => void;
}

export const useChatStore = create<ChatState>((set) => ({
  currentUser: initialUser,
  messages: initialMessages,

  addMessage: (msg) => set((state) => ({ 
    messages: [...state.messages, msg] 
  })),

  updateStatus: (status) => set((state) => ({
    currentUser: { ...state.currentUser, status }
  })),
}));
