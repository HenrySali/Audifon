// Feature: in-app-diagnostic-analyzer
// Module: presentation/screens/diagnostic_analyzer_screen
//
// Technician variant of the AnalyzerScreen entry. Hosts the shared
// AnalyzerScreen widget without any Service_Code_Gate (the technician is
// already authenticated by the app login).
//
// Spec: .kiro/specs/in-app-diagnostic-analyzer/ - Task 10.3 - Req. 18.

import 'package:flutter/material.dart';

import '../../core/analyzer/ui/analyzer_screen.dart';

class DiagnosticAnalyzerScreen extends StatelessWidget {
  const DiagnosticAnalyzerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // The technician variant always opens with the file-picker entry —
    // no gate, no pre-loaded paths.
    return const AnalyzerScreen();
  }
}
