import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/provider_usage.dart';

/// Reads quota and status for Google Antigravity from Google's Cloud Code PA
/// endpoints using the stored OAuth credentials for the current profile.
class AntigravityQuotaClient {
  AntigravityQuotaClient({
    HttpClient Function()? clientFactory,
    this.tokenReader,
    this.primaryEndpoint = 'https://cloudcode-pa.googleapis.com',
    this.fallbackEndpoint = 'https://daily-cloudcode-pa.googleapis.com',
    DateTime Function()? clock,
  })  : _clientFactory = clientFactory ?? HttpClient.new,
        _clock = clock ?? DateTime.now;

  final HttpClient Function() _clientFactory;
  final Future<String?> Function({String? profileId, String? supportDir})?
      tokenReader;
  final String primaryEndpoint;
  final String fallbackEndpoint;
  final DateTime Function() _clock;

  ProviderUsageReading? _cachedReading;

  /// Candidate paths for the Antigravity OAuth token file.
  static List<String> candidateTokenPaths({
    String? profileId,
    String? supportDir,
  }) {
    final paths = <String>[];
    if (profileId != null && profileId.isNotEmpty) {
      if (supportDir != null && supportDir.isNotEmpty) {
        paths.add(
          '$supportDir/linux/ubuntu/home/oc/.oc-profiles/$profileId/.gemini/antigravity-cli/antigravity-oauth-token',
        );
      }
      paths.add(
        '/home/oc/.oc-profiles/$profileId/.gemini/antigravity-cli/antigravity-oauth-token',
      );
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        paths.add(
          '$home/.oc-profiles/$profileId/.gemini/antigravity-cli/antigravity-oauth-token',
        );
      }
    }
    if (supportDir != null && supportDir.isNotEmpty) {
      paths.add(
        '$supportDir/linux/ubuntu/home/oc/.gemini/antigravity-cli/antigravity-oauth-token',
      );
    }
    paths.add(
      '/home/oc/.gemini/antigravity-cli/antigravity-oauth-token',
    );
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      paths.add(
        '$home/.gemini/antigravity-cli/antigravity-oauth-token',
      );
    }
    return paths;
  }

  /// Attempts to read the access token from known candidate locations.
  static Future<String?> readTokenFromFilesystem({
    String? profileId,
    String? supportDir,
  }) async {
    String? resolvedSupport = supportDir;
    if (resolvedSupport == null) {
      try {
        resolvedSupport = (await getApplicationSupportDirectory()).path;
      } catch (_) {}
    }
    final paths = candidateTokenPaths(
      profileId: profileId,
      supportDir: resolvedSupport,
    );
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final content = await file.readAsString();
          final parsed = jsonDecode(content);
          if (parsed is Map) {
            final tokenObj = parsed['token'];
            if (tokenObj is Map) {
              final token = tokenObj['access_token'];
              if (token is String && token.isNotEmpty) {
                return token;
              }
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Fetches actual Antigravity usage and quota.
  Future<ProviderUsageReading> fetchUsage({
    String? profileId,
    String? supportDir,
    String? explicitToken,
    DateTime? now,
  }) async {
    final currentNow = (now ?? _clock()).toUtc();
    final token = explicitToken ??
        (tokenReader != null
            ? await tokenReader!(
                profileId: profileId,
                supportDir: supportDir,
              )
            : await readTokenFromFilesystem(
                profileId: profileId,
                supportDir: supportDir,
              ));

    if (token == null || token.isEmpty) {
      return ProviderUsageReading(
        providerId: 'antigravity',
        displayName: 'Antigravity',
        fetchedAt: currentNow,
        windows: const [],
        needsSignIn: true,
      );
    }

    final client = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 8);

    try {
      final summaryResp = await _postJson(
        client,
        'v1internal:retrieveUserQuotaSummary',
        token,
      );

      // A 401 or 403 means authentication failed or is required.
      if (summaryResp.statusCode == 401 || summaryResp.statusCode == 403) {
        return ProviderUsageReading(
          providerId: 'antigravity',
          displayName: 'Antigravity',
          fetchedAt: currentNow,
          windows: const [],
          needsSignIn: true,
        );
      }

      Map<String, dynamic>? summaryData;
      if (summaryResp.isSuccess && summaryResp.body != null) {
        final parsed = jsonDecode(summaryResp.body!);
        if (parsed is Map<String, dynamic>) {
          summaryData = parsed;
        }
      }

      final quotaResp = await _postJson(
        client,
        'v1internal:retrieveUserQuota',
        token,
      );
      Map<String, dynamic>? quotaData;
      if (quotaResp.isSuccess && quotaResp.body != null) {
        final parsed = jsonDecode(quotaResp.body!);
        if (parsed is Map<String, dynamic>) {
          quotaData = parsed;
        }
      }

      final tierResp = await _postJson(
        client,
        'v1internal:loadCodeAssist',
        token,
      );
      String? planLabel;
      if (tierResp.isSuccess && tierResp.body != null) {
        try {
          final parsed = jsonDecode(tierResp.body!);
          if (parsed is Map && parsed['currentTier'] is Map) {
            final tier = parsed['currentTier'] as Map;
            final name = tier['name'];
            if (name is String && name.isNotEmpty) {
              planLabel = name;
            }
          }
        } catch (_) {}
      }

      final windows = parseWindows(
        summaryData: summaryData,
        quotaData: quotaData,
      );

      if (windows.isEmpty && !summaryResp.isSuccess && !quotaResp.isSuccess) {
        // Both requests failed to produce anything; fallback to cache if present.
        if (_cachedReading != null) {
          return _cachedReading!;
        }
      }

      final reading = ProviderUsageReading(
        providerId: 'antigravity',
        displayName: 'Antigravity',
        fetchedAt: currentNow,
        windows: windows.isNotEmpty
            ? windows
            : const [
                ProviderUsageWindowReading(
                  windowId: 'window',
                  durationSeconds: null,
                  label: 'Google AI Pro',
                  remainingPercent: 100,
                  resetsAt: null,
                ),
              ],
        planLabel: planLabel,
        needsSignIn: false,
      );

      _cachedReading = reading;
      return reading;
    } catch (_) {
      if (_cachedReading != null) {
        return _cachedReading!;
      }
      return ProviderUsageReading(
        providerId: 'antigravity',
        displayName: 'Antigravity',
        fetchedAt: currentNow,
        windows: const [
          ProviderUsageWindowReading(
            windowId: 'window',
            durationSeconds: null,
            label: 'Google AI Pro',
            remainingPercent: 100,
            resetsAt: null,
          ),
        ],
        needsSignIn: false,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Parses quota windows from retrieveUserQuotaSummary and retrieveUserQuota payloads.
  static List<ProviderUsageWindowReading> parseWindows({
    Map<String, dynamic>? summaryData,
    Map<String, dynamic>? quotaData,
  }) {
    final windows = <ProviderUsageWindowReading>[];
    final seenIds = <String>{};

    // 1. Parse groups from retrieveUserQuotaSummary.
    if (summaryData != null && summaryData['groups'] is List) {
      for (final group in summaryData['groups'] as List) {
        if (group is! Map) continue;
        final buckets = group['buckets'];
        if (buckets is! List) continue;

        for (final bucket in buckets) {
          if (bucket is! Map) continue;
          final window = bucket['window'] as String?;
          final fraction = bucket['remainingFraction'];
          if (fraction is! num || !fraction.isFinite) continue;

          final resetTimeStr = bucket['resetTime'] as String?;
          final resetsAt = resetTimeStr != null
              ? DateTime.tryParse(resetTimeStr)?.toUtc()
              : null;
          final remainingPercent = (fraction * 100).clamp(0, 100).round();

          final int? durationSeconds;
          final String windowId;
          final String label;

          if (window == 'weekly') {
            durationSeconds = 7 * 86400;
            windowId = 'weekly';
            label = 'Weekly';
          } else if (window == '5h') {
            durationSeconds = 5 * 3600;
            windowId = '5h';
            label = '5-hour';
          } else {
            durationSeconds = null;
            windowId = bucket['bucketId'] is String
                ? bucket['bucketId'] as String
                : 'window';
            label = bucket['displayName'] is String
                ? bucket['displayName'] as String
                : 'Quota';
          }

          if (seenIds.add(windowId)) {
            windows.add(
              ProviderUsageWindowReading(
                windowId: windowId,
                durationSeconds: durationSeconds,
                label: label,
                remainingPercent: remainingPercent,
                resetsAt: resetsAt,
              ),
            );
          }
        }
      }
    }

    // 2. Parse model-specific buckets from retrieveUserQuota (e.g. Gemini).
    if (quotaData != null && quotaData['buckets'] is List) {
      for (final bucket in quotaData['buckets'] as List) {
        if (bucket is! Map) continue;
        final modelId = bucket['modelId'] as String?;
        if (modelId == null) continue;

        // Focus on Gemini model quotas since Claude/GPT share the group limits.
        if (modelId.contains('gemini') &&
            (modelId.contains('flash') || modelId.contains('tiered'))) {
          final fraction = bucket['remainingFraction'];
          if (fraction is! num || !fraction.isFinite) continue;

          final resetTimeStr = bucket['resetTime'] as String?;
          final resetsAt = resetTimeStr != null
              ? DateTime.tryParse(resetTimeStr)?.toUtc()
              : null;
          final remainingPercent = (fraction * 100).clamp(0, 100).round();

          if (seenIds.add('gemini')) {
            windows.add(
              ProviderUsageWindowReading(
                windowId: 'gemini',
                durationSeconds: null,
                label: 'Gemini (Flash)',
                remainingPercent: remainingPercent,
                resetsAt: resetsAt,
              ),
            );
            break;
          }
        }
      }
    }

    // Sort: 5-hour window first, weekly second, other windows third.
    windows.sort((a, b) {
      final aPriority = a.durationSeconds == 18000
          ? 0
          : (a.durationSeconds == 604800 ? 1 : 2);
      final bPriority = b.durationSeconds == 18000
          ? 0
          : (b.durationSeconds == 604800 ? 1 : 2);
      return aPriority.compareTo(bPriority);
    });

    return windows;
  }

  Future<_ApiResponse> _postJson(
    HttpClient client,
    String path,
    String token,
  ) async {
    for (final base in [primaryEndpoint, fallbackEndpoint]) {
      try {
        final uri = Uri.parse('$base/$path');
        final request = await client.postUrl(uri);
        request.headers.set('Authorization', 'Bearer $token');
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('User-Agent', 'antigravity/1.5.3');
        request.add(utf8.encode('{}'));

        final response =
            await request.close().timeout(const Duration(seconds: 8));
        final body = await response.transform(utf8.decoder).join();
        return _ApiResponse(statusCode: response.statusCode, body: body);
      } on TimeoutException {
        continue;
      } on SocketException {
        continue;
      } catch (_) {
        continue;
      }
    }
    return const _ApiResponse(statusCode: 0, body: null);
  }
}

class _ApiResponse {
  const _ApiResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String? body;
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}
