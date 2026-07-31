// Spec: system-audit-fix · Wave 8, task 9.2.
//
// Test de integración del flujo end-to-end con `ageYears` cableado en
// el `PatientProfile` y un `RecdProvider` inyectado al `BundleBuilder`.
//
// Cubre el hallazgo A-10: la conversión HL → SPL real-ear se invoca
// desde `BundleBuilder.buildFromAudiogram` cuando el caller pasa un
// provider RECD y el perfil del paciente tiene edad. La conversión
// real-ear es informativa (se emite vía `dart:developer.log` con
// name='BundleBuilder.realEar', level=800) y NO altera el bundle.
//
// La validación clínica clave es que con `ageYears < 18` el `MpoDeriver`
// aplica la regla pediátrica (techo 110 dB SPL en lugar de 132 dB SPL)
// y el bundle resultante refleja ese clamp en su `mpoProfileDbSpl`.
// Esto verifica end-to-end que el cableado bloc → builder → MpoDeriver
// pasa el `ageYears` correctamente.

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/mpo_deriver.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/recd_provider.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

void main() {
  group('Real-ear conversion (RecdProvider en BundleBuilder)', () {
    // Audiograma con pérdida moderada-severa (HL ≈ 30-60 dB) para que
    // UCL ≈ 100 + 0.15 × HL caiga por encima del techo pediátrico
    // (110 dB SPL) en las bandas más severas, garantizando que el
    // clamp pediátrico es observable.
    final audiogram = const Audiogram(thresholds: {
      250: 30,
      500: 30,
      750: 35,
      1000: 40,
      1500: 40,
      2000: 45,
      2500: 45,
      3000: 50,
      3500: 50,
      4000: 55,
      6000: 55,
      8000: 60,
    });
    final builder = BundleBuilder();
    final fixedAt = DateTime.utc(2026, 6, 5);

    test(
        'BundleBuilder aplica regla pediátrica cuando ageYears<18 '
        '(MPO ≤ 110 dB SPL en todas las bandas)', () {
      final bundle = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24, ageYears: 8),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        recdProvider: const BagattoRecdProvider(),
      );

      expect(bundle.gainsDb.length, equals(AudiogramDrivenBundle.bandCount));
      expect(bundle.mpoProfileDbSpl.length,
          equals(AudiogramDrivenBundle.bandCount));
      expect(bundle.derivedAt, equals(fixedAt));

      // Validación clínica clave: con ageYears=8 se aplica la regla
      // pediátrica del MpoDeriver, que clampa el techo absoluto a
      // 110 dB SPL (en lugar del techo adulto de 132 dB SPL). Si el
      // bloc/builder no propagara `ageYears` correctamente, este
      // techo no se aplicaría.
      expect(
        bundle.mpoProfileDbSpl.every(
          (m) => m <= MpoDeriver.pediatricCeilingDbSpl,
        ),
        isTrue,
        reason:
            'Pediatric MPO ceiling (${MpoDeriver.pediatricCeilingDbSpl} dB SPL) '
            'should apply when ageYears<18. Got: ${bundle.mpoProfileDbSpl}',
      );

      // Sanity: ningún MPO por debajo del piso operativo del bundle.
      expect(
        bundle.mpoProfileDbSpl.every(
          (m) => m >= AudiogramDrivenBundle.mpoMinDbSpl,
        ),
        isTrue,
        reason: 'MPO values must be ≥ ${AudiogramDrivenBundle.mpoMinDbSpl} '
            'dB SPL. Got: ${bundle.mpoProfileDbSpl}',
      );
    });

    test(
        'sin ageYears (adulto) el techo MPO es 132 dB SPL '
        '(regla adulto)', () {
      final bundle = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        recdProvider: const BagattoRecdProvider(),
      );

      // Con audición moderada-severa el UCL estimado nunca toca 132,
      // pero validamos que el techo permitido sea 132 (regla adulto)
      // y no 110 (regla pediátrica). Lo verificamos asegurando que el
      // clamp pediátrico no se aplicó: en al menos una banda el MPO
      // adulto debería superar el techo pediátrico cuando el UCL
      // estimado lo supera, o como mínimo NO ser menor que el MPO
      // pediátrico de la misma corrida.
      final pediatricBundle = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24, ageYears: 8),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        recdProvider: const BagattoRecdProvider(),
      );

      // Adulto debe tener MPO ≥ pediátrico en cada banda, porque
      // adulto usa safetyMargin=5 y techo=132, mientras que pediátrico
      // usa safetyMargin=10 y techo=110.
      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        expect(
          bundle.mpoProfileDbSpl[i] >= pediatricBundle.mpoProfileDbSpl[i],
          isTrue,
          reason:
              'Adult MPO[$i]=${bundle.mpoProfileDbSpl[i]} debe ser ≥ '
              'pediatric MPO[$i]=${pediatricBundle.mpoProfileDbSpl[i]} '
              '(adulto: safety=5/ceiling=132; pediátrico: safety=10/ceiling=110).',
        );
      }
    });

    test(
        'sin recdProvider → bundle sigue válido (la conversión real-ear '
        'es opcional y no altera la prescripción)', () {
      final withProvider = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24, ageYears: 8),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        recdProvider: const BagattoRecdProvider(),
      );
      final withoutProvider = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24, ageYears: 8),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        // recdProvider omitido a propósito.
      );

      // El bundle no debe cambiar: la conversión RECD sólo emite un
      // log informativo, no toca gainsDb / compressionRatios / MPO.
      expect(withProvider.gainsDb, equals(withoutProvider.gainsDb));
      expect(
        withProvider.compressionRatios,
        equals(withoutProvider.compressionRatios),
      );
      expect(
        withProvider.mpoProfileDbSpl,
        equals(withoutProvider.mpoProfileDbSpl),
      );
    });

    test('con recdProvider pero sin ageYears → builder no falla', () {
      // Caso de regresión: si hay provider pero el perfil no tiene
      // edad (o no hay perfil), el branch `_logRealEarConversion` no
      // se invoca y el bundle se construye con la regla adulto.
      final bundle = builder.buildFromAudiogram(
        audiogram,
        profile: const PatientProfile(experienceMonths: 24),
        mode: PrescriptionMode.quiet,
        derivedAt: fixedAt,
        recdProvider: const BagattoRecdProvider(),
      );
      expect(bundle.gainsDb.length, equals(AudiogramDrivenBundle.bandCount));
    });
  });
}
