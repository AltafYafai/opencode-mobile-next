import 'dart:async';

import 'package:flutter/foundation.dart';

import '../background/usage_widget_snapshot.dart';
import '../domain/provider_usage.dart';
import 'profiles.dart';

enum PaseoUsageStatus {
  off,
  paused,
  waiting,

  /// This phone's agent host is not running; usage is never read by starting
  /// it, so the last numbers stay (and go stale on the widget).
  hostStopped,
  checking,
  current,
  unavailable,
}

/// Reads plan usage from each opted-in Paseo server on the quota monitor's
/// cadence (5 minutes in the foreground, 15 in the background when background
/// monitoring is allowed) and feeds the Usage home-screen widget. It starts no
/// service, shows no alerts, and keeps nothing but the widget's display
/// numbers. Opt-in is per server, off by default, in
/// `oc.paseoUsage.<profileId>` so profile deletion sweeps it.
class PaseoUsageMonitor extends ChangeNotifier {
  PaseoUsageMonitor({
    required this.store,
    required this.createGateway,
    required this.isReadable,
    this.widget,
    this.phoneSupported = _never,
    this.phoneRead,
    this.autoRead = false,
    DateTime Function()? clock,
    this.foregroundInterval = const Duration(minutes: 5),
    this.backgroundInterval = const Duration(minutes: 15),
    this.timeout = const Duration(seconds: 35),
  }) : clock = clock ?? DateTime.now;

  final ProfileStore store;
  final ProviderUsageGateway Function(ServerProfile) createGateway;
  final bool Function(String) isReadable;
  final UsageWidgetSnapshot? widget;

  /// Whether this phone can host agents (built-in Linux is supported).
  final bool Function() phoneSupported;

  /// Reads usage through the phone host's session that is already open, or
  /// returns null when the host is not running. It must never start the host.
  final Future<List<ProviderUsageReading>?> Function()? phoneRead;
  static bool _never() => false;

  /// Reads every Paseo connection (and this phone's host, when it is already
  /// running) without a per-server switch. The Usage model reads every
  /// connection on its own, so a manual opt-in would contradict it. An old
  /// stored opt-in is simply no longer needed and is ignored.
  final bool autoRead;

  /// The source id of this phone's built-in agent host.
  static const phoneId = 'phone';
  final DateTime Function() clock;
  final Duration foregroundInterval, backgroundInterval, timeout;

  final _status = <String, PaseoUsageStatus>{};
  final _blocked = <String>{};
  Future<void>? _refresh;
  Timer? _timer;
  bool _foreground = true, _backgroundAllowed = false, _disposed = false;
  int _epoch = 0;

  static String key(String profileId) => 'oc.paseoUsage.$profileId';

  bool get runningAllowed => !_disposed && (_foreground || _backgroundAllowed);

  ServerProfile? _profile(String id) =>
      store.profiles.where((p) => p.id == id).firstOrNull;

  /// Saved Paseo servers, the only ones this can read.
  List<ServerProfile> get paseoProfiles => [
    for (final p in store.profiles)
      if (p.backend == ServerBackend.paseo) p,
  ];

  bool _readable(String id) {
    if (id == phoneId) {
      return !_disposed &&
          !_blocked.contains(id) &&
          phoneSupported() &&
          phoneRead != null;
    }
    final profile = _profile(id);
    return profile != null &&
        profile.backend == ServerBackend.paseo &&
        !_blocked.contains(id) &&
        isReadable(id);
  }

  /// Whether [id] is read: always when it can be ([autoRead]), else only
  /// after the old per-server opt-in.
  bool enabled(String id) =>
      _readable(id) && (autoRead || store.prefs.getBool(key(id)) == true);

  /// The old per-server opt-in is stored. Only an explicit opt-in starts the
  /// monitor's own timer at launch; automatic reading waits for the Usage
  /// model's refresh.
  bool optedIn(String id) =>
      _readable(id) && store.prefs.getBool(key(id)) == true;

  List<String> get _targets => [
    if (enabled(phoneId)) phoneId,
    for (final p in paseoProfiles)
      if (enabled(p.id)) p.id,
  ];

  /// When [id] last answered, and how many of its providers reported plan
  /// numbers then (zero: signed out, or a plan without limits).
  DateTime? lastReadAt(String id) => _readAt[id];
  int shownProviders(String id) => _shown[id] ?? 0;
  final _readAt = <String, DateTime>{};
  final _last = <String, List<ProviderUsageReading>>{};

  /// What [id] reported on its last answer (display numbers only), or null
  /// when it has not answered or is not opted in.
  List<ProviderUsageReading>? readingsFor(String id) =>
      enabled(id) ? _last[id] : null;
  final _shown = <String, int>{};

  PaseoUsageStatus statusFor(String id) {
    if (!enabled(id)) return PaseoUsageStatus.off;
    if (!runningAllowed) return PaseoUsageStatus.paused;
    return _status[id] ?? PaseoUsageStatus.waiting;
  }

  Future<bool> setEnabled(String id, bool value) async {
    final profile = _profile(id);
    if (id == phoneId) {
      if (_disposed || _blocked.contains(id) || !phoneSupported()) {
        return false;
      }
    } else if (_disposed ||
        profile == null ||
        profile.backend != ServerBackend.paseo ||
        _blocked.contains(id) ||
        !isReadable(id)) {
      return false;
    }
    try {
      if (value) {
        if (!await store.prefs.setBool(key(id), true)) return false;
      } else {
        if (!await store.prefs.remove(key(id))) return false;
        _status.remove(id);
        _readAt.remove(id);
        _shown.remove(id);
        _last.remove(id);
        await widget?.clearForProfile(id);
      }
    } catch (_) {
      return false;
    }
    if (_disposed) return true;
    notifyListeners();
    if (value) {
      _schedule();
      unawaited(refresh());
    }
    return true;
  }

  bool get _anyOptedIn =>
      [phoneId, for (final p in paseoProfiles) p.id].any(optedIn);

  void start() {
    if (_disposed || !_anyOptedIn) return;
    _schedule();
    unawaited(refresh());
  }

  void setRuntime({required bool foreground, required bool backgroundAllowed}) {
    if (_disposed) return;
    if (_foreground == foreground && _backgroundAllowed == backgroundAllowed) {
      return;
    }
    _foreground = foreground;
    _backgroundAllowed = backgroundAllowed;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    // Like start(): only an explicit opt-in keeps the monitor's own timer;
    // automatic reading waits for the Usage model's refresh.
    if (runningAllowed && _anyOptedIn) {
      _schedule();
      unawaited(refresh());
    }
    notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!runningAllowed || _targets.isEmpty) return;
    _timer = Timer(_foreground ? foregroundInterval : backgroundInterval, () {
      _timer = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    if (!runningAllowed || _targets.isEmpty) return Future.value();
    final running = _refresh;
    if (running != null) return running;
    final operation = Future<void>.microtask(() async {
      for (final id in _targets) {
        if (!runningAllowed) break;
        await _read(id);
      }
    });
    _refresh = operation;
    return operation.whenComplete(() {
      _refresh = null;
      if (!_disposed) {
        _schedule();
        notifyListeners();
      }
    });
  }

  Future<void> _read(String id) async {
    final epoch = _epoch;
    bool current() => !_disposed && epoch == _epoch && enabled(id);
    final isPhone = id == phoneId;
    final profile = isPhone ? null : _profile(id);
    if (!isPhone && profile == null) return;
    _status[id] = PaseoUsageStatus.checking;
    if (!_disposed) notifyListeners();
    ProviderUsageGateway? gateway;
    try {
      final List<ProviderUsageReading>? readings;
      if (isPhone) {
        readings = await phoneRead!().timeout(timeout);
        if (readings == null) {
          if (current()) _status[id] = PaseoUsageStatus.hostStopped;
          return;
        }
      } else {
        gateway = createGateway(profile!);
        readings = await gateway.read().timeout(timeout);
      }
      if (!current()) return;
      _status[id] = PaseoUsageStatus.current;
      _readAt[id] = clock();
      _shown[id] = readings.where((r) => r.windows.isNotEmpty).length;
      _last[id] = readings;
      try {
        await widget?.recordReadings(
          profileId: id,
          profileName: profile?.name ?? '',
          readings: readings,
          thisPhone: isPhone,
        );
      } catch (_) {}
      // Disabled or deleted while the write was in flight.
      if (!current()) await widget?.clearForProfile(id);
    } catch (_) {
      if (current()) _status[id] = PaseoUsageStatus.unavailable;
    } finally {
      try {
        await gateway?.close();
      } catch (_) {}
    }
  }

  /// Deletion started: stop reading and drop the widget's numbers.
  void removeProfile(String id, {bool retainIdentity = false}) {
    _blocked.add(id);
    _epoch++;
    _status.remove(id);
    _last.remove(id);
    final cleared = widget?.clearForProfile(id);
    if (cleared != null) unawaited(cleared.catchError((_) => false));
    if (!_disposed) notifyListeners();
  }

  /// Reopens admission after an aborted removal.
  void cancelDeletion(String id) {
    if (_disposed || !_blocked.remove(id)) return;
    if (_timer != null || _anyOptedIn) _schedule();
  }

  Future<void> drain(String id) async {
    await _refresh;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }
}
