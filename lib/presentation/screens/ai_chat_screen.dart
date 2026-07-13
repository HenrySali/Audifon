import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/services/ai_chat_service.dart';

/// Pantalla de chat AI para consultas sobre el audífono digital.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  AiChatService? _chatService;
  bool _isLoading = false;
  bool _needsApiKey = true;
  final TextEditingController _apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Intentar cargar API key guardada
    _checkApiKey();
  }

  void _checkApiKey() {
    // Por ahora pedir al usuario. En producción se guardaría en secure storage.
    setState(() => _needsApiKey = true);
  }

  void _initService(String apiKey) {
    _chatService = AiChatService(apiKey: apiKey.trim());
    setState(() {
      _needsApiKey = false;
      _messages.add(_ChatMessage(
        text: '¡Hola! Soy el asistente AI del audífono PSK. '
            'Tengo acceso a toda la documentación técnica y clínica del proyecto. '
            'Puedo ayudarte con configuración, prescripción, '
            'diagnóstico y cualquier duda. ¿En qué puedo ayudarte?',
        isUser: false,
      ));
    });
    // Verificar conexión al servidor
    _chatService!.checkServer().then((ok) {
      if (!ok && mounted) {
        setState(() {
          _messages.add(_ChatMessage(
            text: '⚠️ No se pudo conectar al servidor RAG (localhost:8080). '
                'Asegurate de ejecutar: cd web-simulator && node src/server.js',
            isUser: false,
          ));
        });
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _chatService == null) return;

    setState(() {
      _messages.add(_ChatMessage(text: text.trim(), isUser: true));
      _isLoading = true;
    });
    _controller.clear();
    _scrollToBottom();

    final response = await _chatService!.sendMessage(text.trim());

    setState(() {
      _messages.add(_ChatMessage(
        text: response.answer,
        isUser: false,
        sources: response.sources,
      ));
      _isLoading = false;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Row(
          children: [
            Icon(Icons.smart_toy, color: Colors.cyan, size: 24),
            SizedBox(width: 8),
            Text('AI Assistant', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        actions: [
          if (!_needsApiKey)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white70),
              tooltip: 'Nueva conversación',
              onPressed: () {
                _chatService?.resetConversation();
                setState(() {
                  _messages.clear();
                  _messages.add(_ChatMessage(
                    text: 'Conversación reiniciada. ¿En qué puedo ayudarte?',
                    isUser: false,
                  ));
                });
              },
            ),
        ],
      ),
      body: _needsApiKey ? _buildApiKeyInput() : _buildChat(),
    );
  }

  Widget _buildApiKeyInput() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.key, color: Colors.cyan, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Ingresa tu API Key de OpenAI',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Se necesita para conectar con el asistente AI.\nObtené una en platform.openai.com',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'sk-...',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: const Color(0xFF21262D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(Icons.vpn_key, color: Colors.cyan),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  if (_apiKeyController.text.trim().isNotEmpty) {
                    _initService(_apiKeyController.text);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyan,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Conectar', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        // Sugerencias (solo si no hay mensajes del usuario)
        if (_messages.where((m) => m.isUser).isEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: _chatService!.suggestedQuestions.map((q) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(q, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                    backgroundColor: const Color(0xFF21262D),
                    side: BorderSide(color: Colors.cyan.withOpacity(0.3)),
                    onPressed: () => _sendMessage(q),
                  ),
                );
              }).toList(),
            ),
          ),
        // Mensajes
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length + (_isLoading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _messages.length && _isLoading) {
                return _buildTypingIndicator();
              }
              return _buildMessageBubble(_messages[index]);
            },
          ),
        ),
        // Input
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            color: Color(0xFF161B22),
            border: Border(top: BorderSide(color: Color(0xFF30363D))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _sendMessage,
                  decoration: InputDecoration(
                    hintText: 'Pregunta sobre el audífono...',
                    hintStyle: const TextStyle(color: Colors.white30),
                    filled: true,
                    fillColor: const Color(0xFF21262D),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: Colors.cyan,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.white, size: 20),
                  onPressed: () => _sendMessage(_controller.text),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(_ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: message.isUser ? Colors.cyan.withOpacity(0.2) : const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: message.isUser ? Colors.cyan.withOpacity(0.4) : const Color(0xFF30363D),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.text,
              style: TextStyle(
                color: message.isUser ? Colors.cyan.shade100 : Colors.white.withOpacity(0.9),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (!message.isUser)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.sources.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: message.sources.map((s) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.cyan.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.cyan.withOpacity(0.2)),
                        ),
                        child: Text(s, style: const TextStyle(color: Colors.cyan, fontSize: 10)),
                      )).toList(),
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: message.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copiado'), duration: Duration(seconds: 1)),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Icon(Icons.copy, size: 14, color: Colors.white.withOpacity(0.3)),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyan)),
            SizedBox(width: 10),
            Text('Pensando...', style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;
  final List<String> sources;

  _ChatMessage({required this.text, required this.isUser, this.sources = const []});
}
