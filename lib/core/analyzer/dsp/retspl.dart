// Feature: in-app-diagnostic-analyzer
// Module: dsp/retspl
//
// ISO 389-7 free-field RETSPL lookup at the 12 audiometric frequencies.
// The table is the canonical source for converting between dB SPL and
// dB HL inside the analyzer (Req. 13.3).

import '../constants.dart';

class Retspl {
  /// Returns the free-field RETSPL offset (dB) at the audiometric
  /// frequency `freqHz`. Throws `ArgumentError` for unknown frequencies
  /// — the analyzer never queries off-grid frequencies.
  static double offsetDb(int freqHz) {
    final v = kRetsplDb[freqHz];
    if (v == null) {
      throw ArgumentError(
        'No RETSPL value defined for $freqHz Hz (allowed: '
        '${kRetsplDb.keys.toList()})',
      );
    }
    return v;
  }
}
