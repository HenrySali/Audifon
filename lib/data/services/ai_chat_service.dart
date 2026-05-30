import 'dart:convert';
import 'package:http/http.dart' as http;

/// Servicio de chat AI para el audífono digital.
/// Se conecta al servidor RAG local (web-simulator) que busca en la
/// documentación del proyecto antes de responder.
class AiChatService {
  /// URL del servidor (web-simulator corriendo en localhost:8080)
  final String serverUrl;
  final String apiKey;

  AiChatService({
    required this.apiKey,
    this.serverUrl = 'http://10.0.2.2:8080', // Android emulator → localhost
  });

  /// Envía un mensaje al servidor RAG y obtiene respuesta con contexto
  Future<AiChatResponse> sendMessage(String message) async {
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': message,
          'apiKey': apiKey,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return AiChatResponse(
          answer: data['answer'] ?? 'Sin respuesta',
          sources: (data['sources'] as List?)
                  ?.map((s) => s['title']?.toString() ?? s['path']?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList() ??
              [],
          tokensUsed: data['tokensUsed'] ?? 0,
        );
      } else {
        final error = jsonDecode(response.body);
        return AiChatResponse(
          answer: 'Error: ${error['error'] ?? 'Error ${response.statusCode}'}',
          sources: [],
          tokensUsed: 0,
        );
      }
    } catch (e) {
      return AiChatResponse(
        answer: 'Error de conexión con el servidor AI.\n\n'
            'Asegurate de que el servidor esté corriendo:\n'
            'cd web-simulator && node src/server.js\n\n'
            'Error: $e',
        sources: [],
        tokensUsed: 0,
      );
    }
  }

  /// Verifica si el servidor está disponible
  Future<bool> checkServer() async {
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/status'),
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Resetea la conversación actual.
  /// El servidor RAG es stateless (no mantiene historial entre mensajes),
  /// así que esto simplemente es un placeholder para limpieza local.
  void resetConversation() {
    // No hay estado de conversación que resetear en el servicio actual.
    // El historial de mensajes se mantiene en el widget que llama.
  }

  /// Preguntas sugeridas
  List<String> get suggestedQuestions => [
        '¿Qué es el WDRC y cómo funciona?',
        '¿Cómo configuro el EQ para pérdida en altas?',
        '¿Qué significa el MPO de 110 dB SPL?',
        '¿Cuál es la diferencia entre NAL-NL2 y DSL v5?',
        '¿Por qué el audífono hace feedback?',
        '¿Cómo interpreto el índice de degradación?',
        '¿Qué parámetros WDRC usar para pérdida moderada?',
        '¿Cómo funciona la calibración ANSI S3.22?',
      ];
}

/// Respuesta del chat AI con fuentes
class AiChatResponse {
  final String answer;
  final List<String> sources;
  final int tokensUsed;

  AiChatResponse({
    required this.answer,
    required this.sources,
    required this.tokensUsed,
  });
}
