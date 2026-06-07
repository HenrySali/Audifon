import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/services/remote_config_service.dart';
import '../screens/blocked_screen.dart';
import 'update_available_dialog.dart';

/// Envoltorio que dispara el `fetch()` del backend remoto Oír Pro al
/// montarse y reacciona al resultado mostrando `BlockedScreen` o el
/// diálogo de actualización.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 5b / R6.2 a R6.5.
///
/// Estructura típica:
///
/// ```dart
/// runApp(
///   BiometricGate(
///     child: RemoteConfigGate(
///       child: HearingAidApp(...),
///     ),
///   ),
/// );
/// ```
///
/// Reglas de UX:
///
/// 1. **No bloquea la UI** mientras se hace el check (R6.5). El `child`
///    se monta inmediatamente y arranca el flujo del audífono. El fetch
///    corre en background con timeout 3 s.
/// 2. Cuando llega la respuesta:
///    - `blocked == true` → el gate cambia su build a una pantalla
///      `BlockedScreen` con su propio `MaterialApp`, reemplazando
///      visualmente todo el stack del child. No destructivo: la
///      `BlockedScreen` no toca datos del paciente.
///    - `isVersionNewer(latestVersion, currentVersion)` →
///      `showUpdateDialog` sobre el Navigator del child. Si además
///      `isVersionNewer(minVersion, currentVersion)`, el diálogo es
///      modal y bloqueante (`WillPopScope.false`).
///    - Caso normal → no hace nada, la app sigue.
/// 3. Si el config viene del cache (`isFromCache`), NO se muestra el
///    diálogo de update — los datos podrían ser viejos y queremos evitar
///    que un usuario sin internet vea notificaciones espurias. El
///    bloqueo SÍ se respeta desde cache, porque el kill switch tiene
///    que sobrevivir cortes de internet (R6.4).
///
/// **Nota técnica**: como el gate sits arriba del `MaterialApp` del
/// child, no puede usar `Navigator.of(context)` (que busca ancestros).
/// Para mostrar el diálogo recorremos los descendientes del element
/// tree buscando el `NavigatorState` del child. Es la técnica que usa
/// algún código del propio framework (por ejemplo, ciertos overlays).
class RemoteConfigGate extends StatefulWidget {
  /// La app real que se renderiza inmediatamente, sin esperar al fetch.
  final Widget child;

  /// Versión actual de la app instalada. Se manda al backend en el body
  /// del POST y se compara contra `latestVersion` / `minVersion` para
  /// decidir si mostrar el diálogo de update.
  final String currentVersion;

  /// `appId` que se manda al backend. La APK del técnico usa
  /// `oirpro-tech` (default). El spec separado `oir-pro-patient-mode`
  /// usará `oirpro-patient`.
  final String appId;

  /// Inyectable para tests: reemplaza el singleton del servicio. En
  /// producción se deja en null.
  final RemoteConfigService? service;

  const RemoteConfigGate({
    super.key,
    required this.child,
    this.currentVersion = '1.0.0',
    this.appId = 'oirpro-tech',
    this.service,
  });

  @override
  State<RemoteConfigGate> createState() => _RemoteConfigGateState();
}

class _RemoteConfigGateState extends State<RemoteConfigGate> {
  bool _blocked = false;
  String? _blockedReason;
  bool _checkStarted = false;

  @override
  void initState() {
    super.initState();
    // Disparar el fetch después del primer frame, así el `child` ya
    // pinta su UI antes de que arranque el POST. R6.5.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_checkStarted) {
        _checkStarted = true;
        unawaited(_runCheck());
      }
    });
  }

  Future<void> _runCheck() async {
    final svc = widget.service ?? RemoteConfigService.instance;
    final cfg = await svc.fetch(
      currentVersion: widget.currentVersion,
      appId: widget.appId,
    );
    if (!mounted) return;
    _handleResult(cfg);
  }

  void _handleResult(RemoteConfig cfg) {
    if (cfg.blocked) {
      // Cambiamos la build del gate a una pantalla bloqueada con su
      // propio MaterialApp. El `child` (HearingAidApp) se desmonta
      // limpiamente — no destruimos datos del paciente porque la
      // persistencia vive en Hive, no en el árbol de widgets.
      if (!mounted) return;
      setState(() {
        _blocked = true;
        _blockedReason = cfg.blockedReason;
      });
      return;
    }

    // Si el config viene del cache, no mostramos diálogo de update —
    // podría estar desactualizado y arruinar la UX offline (R6.4).
    if (cfg.isFromCache) return;

    if (isVersionNewer(cfg.latestVersion, widget.currentVersion)) {
      // El diálogo se muestra sobre el Navigator del child. Lo
      // posponemos un frame para asegurar que el árbol esté armado.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showUpdateDialogOnChild(cfg);
      });
    }
  }

  /// Busca el `NavigatorState` del `MaterialApp` hijo recorriendo los
  /// elementos descendientes y dispara el diálogo de update sobre él.
  /// Si no encuentra un Navigator (caso raro: el child todavía no se
  /// montó), descarta el intento. El diálogo no es crítico — se
  /// volverá a evaluar en el próximo arranque de la app.
  void _showUpdateDialogOnChild(RemoteConfig cfg) {
    final navigator = _findDescendantNavigator();
    if (navigator == null) {
      debugPrint(
        '[RemoteConfigGate] no encontré Navigator para el diálogo de update',
      );
      return;
    }
    final navContext = navigator.context;
    showUpdateDialog(navContext, cfg, widget.currentVersion);
  }

  NavigatorState? _findDescendantNavigator() {
    NavigatorState? found;
    void visitor(Element element) {
      if (found != null) return;
      if (element.widget is Navigator) {
        if (element is StatefulElement) {
          final state = element.state;
          if (state is NavigatorState) {
            found = state;
            return;
          }
        }
      }
      element.visitChildren(visitor);
    }

    final ctx = context;
    if (ctx is Element) {
      ctx.visitChildren(visitor);
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    if (_blocked) {
      // MaterialApp propio para tener Navigator + Directionality cuando
      // mostramos la BlockedScreen. Mismo patrón que `BiometricGate`
      // durante el splash.
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0F1B2D),
        ),
        home: BlockedScreen(blockedReason: _blockedReason),
      );
    }
    // Pasthrough: el child se monta inmediatamente y maneja toda la UI
    // mientras corre el fetch en background.
    return widget.child;
  }
}
