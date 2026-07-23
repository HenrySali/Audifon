/// @file feedback_checklist_item.dart
/// @brief Ítems del checklist de feedback del paciente sobre la
/// configuración del audífono.
///
/// Cada ítem tiene:
/// - una `key` enum estable que se serializa como string
/// - una `humanLabel` para mostrar al paciente (lenguaje cotidiano)
/// - un `technicalContext` que indica qué aspecto del DSP se está evaluando
///   (se incluye en el JSON exportado para análisis posterior).
/// - un `rating` (good / bad / noOpinion).
library;

/// Clave estable de cada ítem del checklist. La serialización JSON usa el
/// nombre de la enum para que sea legible.
enum FeedbackItemKey {
  voicesClear,
  highsNotHarsh,
  bassesGood,
  loudsSafe,
  softsAudible,
  noFeedbackPitch,
  noTunnelEffect,
  volumeAdequate,
  sceneTransitions,
  naturalSound,
}

/// Calificación del usuario para un ítem.
enum FeedbackRating {
  good,
  bad,
  noOpinion,
}

/// Un ítem del checklist con su rating actual.
class FeedbackChecklistItem {
  final FeedbackItemKey key;
  final String humanLabel;
  final String technicalContext;
  final FeedbackRating rating;

  const FeedbackChecklistItem({
    required this.key,
    required this.humanLabel,
    required this.technicalContext,
    this.rating = FeedbackRating.noOpinion,
  });

  FeedbackChecklistItem copyWith({FeedbackRating? rating}) {
    return FeedbackChecklistItem(
      key: key,
      humanLabel: humanLabel,
      technicalContext: technicalContext,
      rating: rating ?? this.rating,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key.name,
        'human_label': humanLabel,
        'technical_context': technicalContext,
        'rating': rating.name,
      };

  factory FeedbackChecklistItem.fromJson(Map<String, dynamic> j) {
    return FeedbackChecklistItem(
      key: FeedbackItemKey.values.firstWhere(
        (e) => e.name == j['key'],
        orElse: () => FeedbackItemKey.naturalSound,
      ),
      humanLabel: j['human_label'] as String? ?? '',
      technicalContext: j['technical_context'] as String? ?? '',
      rating: FeedbackRating.values.firstWhere(
        (e) => e.name == j['rating'],
        orElse: () => FeedbackRating.noOpinion,
      ),
    );
  }
}

/// Plantilla con los 10 ítems estándar (todos en `noOpinion`).
/// La UI clona esta lista y deja que el usuario cambie los `rating`.
const List<FeedbackChecklistItem> kFeedbackItemsTemplate =
    <FeedbackChecklistItem>[
  FeedbackChecklistItem(
    key: FeedbackItemKey.voicesClear,
    humanLabel: 'Las voces se entendieron claras',
    technicalContext: 'EQ bandas medias 1-3 kHz + NR',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.highsNotHarsh,
    humanLabel: 'Los agudos no me molestaron',
    technicalContext: 'EQ bandas altas 4-8 kHz + MPO',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.bassesGood,
    humanLabel: 'Los graves se sintieron bien',
    technicalContext: 'EQ bandas bajas 250-500 Hz',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.loudsSafe,
    humanLabel: 'Los sonidos fuertes no me lastimaron',
    technicalContext: 'MPO + WDRC compresión',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.softsAudible,
    humanLabel: 'Los sonidos suaves se escucharon',
    technicalContext: 'WDRC kneepoint + ganancia',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.noFeedbackPitch,
    humanLabel: 'Sin pitidos ni eco',
    technicalContext: 'AFC cancelación de feedback',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.noTunnelEffect,
    humanLabel: 'Sin sensación de túnel o lejanía',
    technicalContext: 'NR no demasiado agresivo',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.volumeAdequate,
    humanLabel: 'Volumen general adecuado',
    technicalContext: 'Volume + WDRC',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.sceneTransitions,
    humanLabel: 'Cambios entre escenas naturales',
    technicalContext: 'Smart Scene transitions',
  ),
  FeedbackChecklistItem(
    key: FeedbackItemKey.naturalSound,
    humanLabel: 'Sonido natural, no artificial',
    technicalContext: 'DSP global / artefactos',
  ),
];
