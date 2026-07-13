/// Generador de reporte unificado de diagnóstico.
///
/// Interpreta los resultados numéricos de los 13 tests y genera
/// [DiagnosticFinding]s con lenguaje de usuario + detalle técnico.

import '../models/diagnostic_report.dart';
import '../models/diag_test_id.dart';
import '../models/test_result.dart';

class DiagnosticReportGenerator {
  DiagnosticReportGenerator._();

  /// Genera el reporte a partir de los resultados de todos los tests.
  static DiagnosticReport generate({
    required Map<String, TestResult> results,
    required List<String> wavFiles,
  }) {
    final findings = <DiagnosticFinding>[];
    final testData = <String, Map<String, dynamic>>{};

    for (final id in DiagTestId.all) {
      final r = results[id];
      if (r == null || r.status != TestStatus.completed) continue;
      testData[id] = r.data;
    }

    // ─── Analizar cada subsistema ──────────────────────────────────────────
    _analyzeSmartScene(testData, findings);
    _analyzeDspRecording(testData, findings);
    _analyzeEnhancement(testData, findings);
    _analyzeLatency(testData, findings);
    _analyzeDnn(testData, findings);
    _analyzeWdrc(testData, findings);
    _analyzeMpo(testData, findings);
    _analyzeProtection(testData, findings);
    _analyzeRouting(testData, findings);
    _analyzeHealth(testData, findings);

    // Si no hay findings, agregar uno positivo genérico
    if (findings.isEmpty) {
      findings.add(const DiagnosticFinding(
        title: 'Sistema OK',
        userMessage: 'Todos los módulos funcionan correctamente',
        technicalDetail: 'Todos los tests completados sin anomalías',
        severity: FindingSeverity.ok,
      ));
    }

    // Determinar estado global
    final hasCritical =
        findings.any((f) => f.severity == FindingSeverity.critical);
    final hasWarning =
        findings.any((f) => f.severity == FindingSeverity.warning);
    final overallStatus =
        hasCritical ? 'issues' : (hasWarning ? 'warnings' : 'ok');

    return DiagnosticReport(
      timestamp: DateTime.now(),
      findings: findings,
      testResults: testData,
      wavFiles: wavFiles,
      overallStatus: overallStatus,
    );
  }

  // ─── Análisis por subsistema ────────────────────────────────────────────

  static void _analyzeSmartScene(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.smartScene];
    if (d == null) return;
    if (d['available'] == false) {
      findings.add(const DiagnosticFinding(
        title: 'Clasificador inactivo',
        userMessage: 'El clasificador de ambiente no está activo',
        technicalDetail: 'SmartScene: available=false, motor no responde',
        severity: FindingSeverity.warning,
        recommendation: 'Verificar que el motor de audio esté iniciado',
      ));
      return;
    }

    // Mapear clase numérica a nombre legible.
    const classNames = [
      'Indeterminado', 'Silencio', 'Voz', 'Voz+Ruido leve',
      'Voz+Ruido medio', 'Ruido grave', 'Ruido agudo', 'Música',
    ];
    final classIdx = d['claseDominante'] as int? ?? 0;
    final className = (classIdx >= 0 && classIdx < classNames.length)
        ? classNames[classIdx]
        : 'clase $classIdx';

    findings.add(DiagnosticFinding(
      title: 'Clasificador activo',
      userMessage:
          'El clasificador de ambiente funciona (${d['muestras']} muestras) '
          '— ambiente detectado: $className',
      technicalDetail:
          'SmartScene OK: input=${d['inputDbSpl (min/avg/max)']}, '
          'SNR=${d['snrDb (min/avg/max)']}, clase=$classIdx ($className)',
      severity: FindingSeverity.ok,
    ));
  }

  static void _analyzeDspRecording(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.dspRecording];
    if (d == null) return;
    if (d['completada'] == true) {
      findings.add(DiagnosticFinding(
        title: 'Grabación DSP',
        userMessage:
            'Grabación de diagnóstico completada (${d['duración']})',
        technicalDetail: 'WAV dual-channel: ${d['archivo']}',
        severity: FindingSeverity.ok,
      ));
    } else if (d['canRecord'] == false) {
      findings.add(const DiagnosticFinding(
        title: 'Sin grabación DSP',
        userMessage: 'No se pudo grabar — motor de audio inactivo',
        technicalDetail: 'DspRecording: motor no activo o error I/O',
        severity: FindingSeverity.info,
      ));
    }
  }

  static void _analyzeEnhancement(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.enhancement];
    if (d == null || d['available'] == false) return;

    final mode = d['modoDominante'] as String? ?? 'Desconocido';
    final stable = d['estable'] == true;
    final dnnPct = d['dnnActivo%'] as String? ?? '0%';
    final mvdrPct = d['mvdrActivo%'] as String? ?? '0%';

    // El "modo" se refiere al subsistema de beamforming (MVDR), NO al pipeline
    // completo. La DNN corre independiente del beamformer.
    // IEC 60118-2: el AGC puede tener múltiples etapas independientes.
    String userMsg;
    if (mode == 'Bypass' && dnnPct != '0%') {
      userMsg = 'Reducción de ruido por IA activa ($dnnPct), '
          'beamformer desactivado';
    } else if (mode == 'MVDR Beamformer') {
      userMsg = 'Beamformer MVDR activo ($mvdrPct) + DNN ($dnnPct)';
    } else {
      userMsg = 'Motor de realce en modo $mode (DNN $dnnPct)';
    }

    if (!stable) {
      userMsg += ' — cambios de modo detectados';
    }

    findings.add(DiagnosticFinding(
      title: 'Motor de realce',
      userMessage: userMsg,
      technicalDetail:
          'Enhancement: beamformerMode=$mode, stable=$stable, DNN=$dnnPct, '
          'MVDR=$mvdrPct',
      severity: stable ? FindingSeverity.ok : FindingSeverity.warning,
      recommendation:
          stable ? null : 'El beamformer cambia de modo frecuentemente — '
              'verificar condiciones de audio',
    ));
  }

  static void _analyzeLatency(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.latency];
    if (d == null || d['available'] == false) return;

    final dspStr = d['dspProcessing (min/avg/max)'] as String? ?? '';
    final underruns = d['underrunsNuevos'] as int? ?? 0;

    // Extraer avg del DSP processing
    double dspAvg = 0;
    final parts = dspStr.split('/');
    if (parts.length >= 2) {
      dspAvg = double.tryParse(parts[1].trim().replaceAll(' ms', '')) ?? 0;
    }

    if (dspAvg > 10) {
      findings.add(DiagnosticFinding(
        title: 'Latencia alta',
        userMessage:
            'La latencia del procesamiento es alta (${dspAvg.toStringAsFixed(1)} ms)',
        technicalDetail: 'DSP processing avg=${dspAvg.toStringAsFixed(2)} ms, '
            'underruns nuevos=$underruns',
        severity:
            dspAvg > 20 ? FindingSeverity.critical : FindingSeverity.warning,
        recommendation: 'Reducir carga DSP o aumentar buffer size',
      ));
    } else {
      findings.add(DiagnosticFinding(
        title: 'Latencia normal',
        userMessage: 'El procesamiento de audio es rápido '
            '(${dspAvg.toStringAsFixed(1)} ms)',
        technicalDetail: 'DSP=$dspStr, underruns=$underruns',
        severity: FindingSeverity.ok,
      ));
    }

    if (underruns > 0) {
      findings.add(DiagnosticFinding(
        title: 'Underruns detectados',
        userMessage:
            'Se detectaron $underruns cortes de audio durante el test',
        technicalDetail: 'callbackUnderruns delta=$underruns en 5s',
        severity:
            underruns > 5 ? FindingSeverity.critical : FindingSeverity.warning,
        recommendation: 'Cerrar apps en segundo plano o aumentar buffer',
      ));
    }
  }

  static void _analyzeDnn(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.dnnDenoiser];
    if (d == null || d['available'] == false) return;

    final activePct = d['activo%'] as String? ?? '0%';
    final stable = d['estable'] == true;

    findings.add(DiagnosticFinding(
      title: 'DNN Denoiser',
      userMessage: 'Reducción de ruido por IA activa $activePct del tiempo',
      technicalDetail:
          'DNN: activo=$activePct, inferencia=${d['inferencia (min/avg/max)']}, '
          'estable=$stable',
      severity: FindingSeverity.ok,
    ));
  }

  static void _analyzeWdrc(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.wdrc];
    if (d == null || d['available'] == false) return;

    final dist = d['distribuciónRegiones'] as String? ?? '';
    final changes = d['cambiosDeRegión'] as int? ?? 0;

    findings.add(DiagnosticFinding(
      title: 'Compresión (WDRC)',
      userMessage: 'Control de volumen automático funcionando ($dist)',
      technicalDetail:
          'WDRC: regiones=$dist, cambios=$changes, '
          'gain=${d['gainFactor (min/avg/max)']}',
      severity: FindingSeverity.ok,
    ));
  }

  static void _analyzeMpo(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.mpoLimiter];
    if (d == null || d['available'] == false) return;

    final limitingStr = d['limitando%'] as String? ?? '0%';
    final limitingPct =
        double.tryParse(limitingStr.replaceAll('%', '')) ?? 0;
    final clips = d['clipsAcumulados'] as int? ?? 0;
    final sustained = d['sostenido%'] as String? ?? '0%';
    final peakStr = d['peakMáximo'] as String? ?? '0';
    // ignore: unused_local_variable
    final peak = double.tryParse(peakStr) ?? 0;

    // Lógica inteligente basada en Giannoulis/Massberg/Reiss (2012):
    // El limitador basado en envolvente reporta activación incluso cuando
    // el hard-clamp no actúa (ganancia reducida previene el clip).
    // Diferenciar: "protegiendo exitosamente" vs "saturado con distorsión".

    if (clips > 0) {
      // CASO CRÍTICO: hay clipping real → distorsión audible.
      findings.add(DiagnosticFinding(
        title: 'MPO saturado — distorsión',
        userMessage:
            'El protector de volumen se satura ($clips clips detectados) '
            '— hay distorsión audible',
        technicalDetail:
            'MPO: limiting=$limitingStr, sustained=$sustained, clips=$clips, '
            'peak=$peakStr — hard-clamp activo',
        severity: FindingSeverity.critical,
        recommendation: 'Reducir ganancias del EQ en 5 dB o bajar volumen',
      ));
    } else if (limitingPct > 30) {
      // Sin clips pero el limitador trabaja mucho → protección activa.
      // IEC 60118-0: el SSPL debe mantenerse sin exceder LDL del usuario.
      // Si no hay clips, el limitador está cumpliendo su función.
      findings.add(DiagnosticFinding(
        title: 'Limitador MPO muy activo',
        userMessage:
            'El protector de volumen está trabajando $limitingStr del tiempo '
            '(sin distorsión, protegiendo correctamente)',
        technicalDetail:
            'MPO: limiting=$limitingStr, sustained=$sustained, clips=0, '
            'peak=$peakStr — envolvente activa, hard-clamp inactivo',
        severity: FindingSeverity.warning,
        recommendation:
            'Considerar reducir ganancias en 3 dB para dar más headroom',
      ));
    } else if (limitingPct > 10) {
      findings.add(DiagnosticFinding(
        title: 'MPO activo parcialmente',
        userMessage:
            'El protector de volumen se activa ocasionalmente ($limitingStr)',
        technicalDetail:
            'MPO: limiting=$limitingStr, sustained=$sustained, clips=$clips',
        severity: FindingSeverity.info,
      ));
    } else {
      findings.add(DiagnosticFinding(
        title: 'MPO normal',
        userMessage: 'Protección de volumen máximo OK (activo $limitingStr)',
        technicalDetail: 'MPO: limiting=$limitingStr, clips=$clips',
        severity: FindingSeverity.ok,
      ));
    }
  }

  static void _analyzeProtection(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.protection];
    if (d == null || d['available'] == false) return;

    final stable = d['clasificadorEstable'] == true;
    final env = d['ambienteDominante'] as String? ?? 'desconocido';

    if (!stable) {
      findings.add(DiagnosticFinding(
        title: 'Clasificador inestable',
        userMessage:
            'El detector de ambiente cambia mucho — puede causar '
            'cambios bruscos de volumen',
        technicalDetail:
            'Protection: env=$env, changes=${d['cambiosDeAmbiente']}, '
            'eqMax=${d['eqMaxGain']}',
        severity: FindingSeverity.warning,
        recommendation: 'El ambiente puede ser mixto; considerar perfil fijo',
      ));
    }
  }

  static void _analyzeRouting(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.routing];
    if (d == null || d['available'] == false) return;

    final api = d['outputApi'] as String? ?? 'Desconocido';
    final perf = d['outputPerformance'] as String? ?? 'None';

    if (api != 'AAudio') {
      findings.add(DiagnosticFinding(
        title: 'API de audio subóptima',
        userMessage: 'El dispositivo usa $api en vez de AAudio (más lento)',
        technicalDetail:
            'Routing: outputApi=$api, perf=$perf, '
            'SR=${d['sampleRate']}, burst=${d['outputBurst']}',
        severity: FindingSeverity.info,
      ));
    }
    if (perf != 'LowLatency') {
      findings.add(DiagnosticFinding(
        title: 'Modo no-baja-latencia',
        userMessage: 'El audio no está en modo baja latencia ($perf)',
        technicalDetail: 'outputPerformanceMode=$perf',
        severity: FindingSeverity.info,
        recommendation: 'Verificar configuración de Oboe performance mode',
      ));
    }
  }

  static void _analyzeHealth(
    Map<String, Map<String, dynamic>> data,
    List<DiagnosticFinding> findings,
  ) {
    final d = data[DiagTestId.health];
    if (d == null || d['available'] == false) return;

    final growing = d['creciendoActivamente'] == true;
    final healthyPct = d['timestampsHealthy%'] as String? ?? '100%';
    final newUnderruns = d['underrunsNuevos'] as int? ?? 0;

    if (growing) {
      findings.add(DiagnosticFinding(
        title: 'Sistema bajo estrés',
        userMessage:
            'El sistema está perdiendo paquetes de audio activamente '
            '($newUnderruns nuevos en 5s)',
        technicalDetail:
            'Health: underruns growing=$growing, new=$newUnderruns, '
            'healthy=$healthyPct',
        severity: FindingSeverity.critical,
        recommendation:
            'Cerrar aplicaciones pesadas y reiniciar el audio',
      ));
    } else {
      findings.add(DiagnosticFinding(
        title: 'Salud del sistema',
        userMessage: 'Sistema estable (timestamps sanos $healthyPct)',
        technicalDetail:
            'Health: growing=false, underruns=$newUnderruns, '
            'healthy=$healthyPct',
        severity: FindingSeverity.ok,
      ));
    }
  }
}
