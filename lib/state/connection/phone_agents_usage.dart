part of '../connection.dart';

// Plan usage for the phone's agents: the Paseo helper's readings plus
// Antigravity's own CLI (#125). Split from phone_agents.dart to keep it under
// the file-size budget.

extension _PhoneAgentsUsage on _ConnectionControllerPhoneAgents {
  /// Plan usage through the built-in host session that is already open. A
  /// stopped or never-started host answers null: reading usage must not wake
  /// it (battery), so the widget keeps the last numbers instead.
  Future<List<ProviderUsageReading>?> _paReadUsage() async {
    if (_self._disposed) return null;
    var baseReadings = const <ProviderUsageReading>[];
    // An open conversation proves the helper runs, whatever the flags say.
    final open = _paSources.values.firstOrNull?.gateway;
    if (open != null && !open.isClosed) {
      try {
        baseReadings = await PaseoProviderUsageGateway.over(
          open.transport,
        ).read();
      } catch (_) {}
    } else if (_paHostRunning || _paHelperAvailable) {
      // No project's conversations are open yet (right after the app starts):
      // one short connection to the helper that is already running, closed
      // after the read. It never starts the helper.
      final host = _paHost;
      final directory = _paDesiredDirectories().firstOrNull;
      if (host != null && directory != null) {
        try {
          final gateway = await host.openGateway(directory);
          try {
            baseReadings = await PaseoProviderUsageGateway.over(
              gateway.transport,
            ).read();
          } finally {
            gateway.close();
          }
        } catch (_) {}
      }
    }

    final readings = <ProviderUsageReading>[...baseReadings];
    final antigravityRow = _paRows
        .where((r) => r.id == 'antigravity')
        .firstOrNull;
    if (!readings.any((r) => r.providerId == 'antigravity')) {
      if (antigravityRow == null ||
          antigravityRow.status != PhoneAgentStatus.signedOut) {
        final agyReadings = await _readAntigravityUsage();
        // Only what the CLI reports; nothing when it reports nothing (the
        // Usage page then says this provider reports no limits).
        if (agyReadings != null && agyReadings.isNotEmpty) {
          readings.addAll(agyReadings);
        }
      }
      if (!readings.any((r) => r.providerId == 'antigravity') &&
          antigravityRow?.status == PhoneAgentStatus.signedOut) {
        readings.add(
          ProviderUsageReading(
            providerId: 'antigravity',
            displayName: 'Antigravity',
            fetchedAt: DateTime.now().toUtc(),
            windows: const [],
            needsSignIn: true,
          ),
        );
      }
    }
    if (readings.isEmpty &&
        open == null &&
        !_paHostRunning &&
        !_paHelperAvailable) {
      return null;
    }
    return readings;
  }

  AntigravityQuotaClient get _paEnsureAntigravityClient =>
      _paAntigravityClient ??= AntigravityQuotaClient(
        runner: BuiltinLinux.supported
            ? (script, {timeout = const Duration(seconds: 35)}) async {
                final res = await BuiltinLinux().run(script, timeout: timeout);
                return (exitCode: res.exitCode, output: res.output);
              }
            : null,
      );

  Future<List<ProviderUsageReading>?> _readAntigravityUsage() async {
    final profileId = _paProfile?.id;
    try {
      return await _paEnsureAntigravityClient.fetchAllUsage(
        profileId: profileId,
      );
    } catch (_) {
      return null;
    }
  }
}
