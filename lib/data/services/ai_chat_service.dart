import 'dart:convert';
import 'package:http/http.dart' as http;

/// Servicio de chat AI para el audífono digital.
/// Se conecta a OpenAI GPT-4o-mini con contexto del sistema de audífono.
class AiChatService {
  static const String _baseUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';

  final String apiKey;
  final List<Map<String, String>> _history = [];

  AiChatService({required this.apiKey});

  static const String _systemPrompt = '''
Eres un asistente técnico experto en audífonos digitales del proyecto PSK Hearing Aid.
Tu rol es ayudar a audiólogos y usuarios con:
- Configuración del audífono (EQ, WDRC, MPO, NR)
- Prescripción de ganancia (NAL-NL2, DSL v5.0)
- Interpretación de audiogramas
- Diagnóstico de problemas del dispositivo
- Explicación de parámetros DSP

Responde en español, de forma clara y profesional.
Para preguntas clínicas, aclara que no reemplazas el criterio profesional.
Sé conciso pero preciso.
''';

  /// Envía un mensaje y obtiene respuesta del AI
  Future<String> sendMessage(String message) async {
    _history.add({'role': 'user', 'content': message});

    // Limitar historial a últimos 10 mensajes
    if (_history.length > 20) {
      _history.removeRange(0, _history.length - 20);
    }

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {'role': 'system', 'content': _systemPrompt},
            ..._history,
          ],
          'temperature': 0.3,
          'max_tokens': 1000,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices'][0]['message']['content'] as String;
        _history.add({'role': 'assistant', 'content': reply});
        return reply;
      } else {
        final error = jsonDecode(response.body);
        return 'Error: ${error['error']?['message'] ?? 'Error desconocido (${response.statusCode})'}';
      }
    } catch (e) {
      return 'Error de conexión: $e';
    }
  }

  /// Resetea el historial de conversación
  void resetConversation() {
    _history.clear();
  }

  /// Preguntas sugeridas
  List<String> get suggestedQuestions => [
        '¿Qué es el WDRC y cómo funciona?',
        '¿Cómo configuro el EQ para pérdida en altas?',
        '¿Qué significa el MPO de 110 dB SPL?',
        '¿Cuál es la diferencia entre NAL-NL2 y DSL v5?',
        '¿Por qué el audífono hace feedback?',
        '¿Cómo interpreto el índice de degradación?',
      ];
}
