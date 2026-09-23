# DjChat - Simple AI Context Vibecoding Expert for Delphi IDE

BPL plugin for Delphi 12+ that integrates Ollama AI directly into the IDE.

![Screenshot](Docs/Screenshots/1.png)

## ✨ Features

- **Chat with AI** directly in Delphi (Tools → DjChat)
- **Code analysis** of selected text or entire files  
- **Context-aware** with smart conversation history summarization
- **Supports any local or cloud Ollama models**
- **It is free**

You may use any of free or semi-free models from Ollama
https://ollama.com/search
including popular DeepSeek, GLM, Qwen ets.

## 🤔 Why This Exists

In the beginning of 2026, Delphi 12 Community Edition has no proper vibecoding support. So I built this project to bring modern AI-assisted coding to Delphi developers.

**How it works:** The plugin connects to your local Ollama, which can run either local or cloud models. 

**Local models** are free but require >8GB GPU VRAM and are slower (10-20 seconds per tiny response). For example, rnj-1.

**Cloud Ollama** works excellently; the free tier has limits (but they're more than sufficient). For example, qwen3-coder.

**Context management challenge:** Maintaining context is non-trivial and is handled by the client (plugin), not Ollama. The plugin sends the ENTIRE conversation history to the model, along with every question, occasionally compressing and summarizing context. The compression threshold depends on token limits (see Prefs):
- **4k-8k tokens** is enough for an hour-long conversation with different code snippets
- **30k-60k tokens** is needed for large multi-page files

## 🚀 Quick Install

1. Download `Bin/DjChat.bpl`
2. In Delphi: **Component → Install Packages → Add**
3. Select the `.bpl` file
4. Restart Delphi, find **Tools → DjChat**

## 🔧 Building from Source

1. Open `Source/DjChat.dpk`
2. Build for your Delphi version (tested in Delphi 12 and 13)
3. Install in Project manager

## 📖 Usage

1. Set your Ollama URL (default: http://localhost:11434) in Prefs. Test connection.
2. Select model from dropdown and limit (match with your Ollama)
3. Type your question or select code and click "Ask"
4. Repeat important context if the model seems to lose track

## 📋 TODO / Roadmap

- [ ] **Better UI design** (more modern interface)
- [ ] **Code completion** (like GitHub Copilot)
- [ ] **Smarter summarization** (more intelligent context compression)
- [ ] **Delphi version detection** (auto-adjust syntax for different Delphi versions)
- [ ] **Export conversations** to markdown/docs

## 🤝 Contributing

Found a bug? Want a feature? Open an Issue or PR!

## 📄 License

MIT License 
