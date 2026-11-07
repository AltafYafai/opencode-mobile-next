import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/quota/antigravity_quota_client.dart';

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.handler);

  final FutureOr<({int statusCode, String body})> Function(Uri uri) handler;
  final uris = <Uri>[];
  final headers = <String, Map<String, String>>{};

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  bool autoUncompress = true;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    uris.add(url);
    final req = _FakeHttpClientRequest(url, handler);
    return req;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.uri, this.handler);

  final Uri uri;
  final FutureOr<({int statusCode, String body})> Function(Uri uri) handler;
  final _headers = _FakeHttpHeaders();
  final _body = <int>[];

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) {
    _body.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    final res = await handler(uri);
    return _FakeHttpClientResponse(res.statusCode, res.body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> values = {};

  @override
  void set(String name, Object value) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.body);

  @override
  final int statusCode;
  final String body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.value(utf8.encode(body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final testNow = DateTime.utc(2026, 11, 7, 20, 0, 0);

  group('AntigravityQuotaClient', () {
    test('missing token returns needsSignIn: true', () async {
      final client = AntigravityQuotaClient(
        tokenReader: ({profileId, supportDir}) async => null,
        clock: () => testNow,
      );

      final reading = await client.fetchUsage();
      expect(reading.providerId, 'antigravity');
      expect(reading.displayName, 'Antigravity');
      expect(reading.needsSignIn, isTrue);
      expect(reading.windows, isEmpty);
    });

    test('401 response returns needsSignIn: true', () async {
      final fakeHttp = _FakeHttpClient((uri) => (statusCode: 401, body: '{}'));
      final client = AntigravityQuotaClient(
        clientFactory: () => fakeHttp,
        tokenReader: ({profileId, supportDir}) async => 'test-token',
        clock: () => testNow,
      );

      final reading = await client.fetchUsage();
      expect(reading.needsSignIn, isTrue);
      expect(reading.windows, isEmpty);
    });

    test('parses actual weekly, 5h, and Gemini quotas with plan label', () async {
      const summaryJson = '''
      {
        "groups": [
          {
            "displayName": "Claude and GPT models",
            "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
            "buckets": [
              {
                "bucketId": "3p-weekly",
                "displayName": "Weekly Limit Remaining",
                "window": "weekly",
                "resetTime": "2026-11-11T10:05:57Z",
                "remainingFraction": 0
              },
              {
                "bucketId": "3p-5h",
                "displayName": "Five Hour Limit Remaining",
                "window": "5h",
                "resetTime": "2026-11-08T01:16:25Z",
                "remainingFraction": 0.85
              }
            ]
          }
        ]
      }
      ''';

      const quotaJson = '''
      {
        "buckets": [
          {
            "modelId": "gemini-3.8-flash-tiered",
            "remainingFraction": 1.0,
            "resetTime": "2026-11-08T01:16:30Z"
          },
          {
            "modelId": "claude-sonnet-4-6",
            "remainingFraction": 0,
            "resetTime": "2026-11-11T10:05:57Z"
          }
        ]
      }
      ''';

      const tierJson = '''
      {
        "currentTier": {
          "id": "free-tier",
          "name": "Google AI Pro"
        }
      }
      ''';

      final fakeHttp = _FakeHttpClient((uri) {
        if (uri.path.contains('retrieveUserQuotaSummary')) {
          return (statusCode: 200, body: summaryJson);
        }
        if (uri.path.contains('retrieveUserQuota')) {
          return (statusCode: 200, body: quotaJson);
        }
        if (uri.path.contains('loadCodeAssist')) {
          return (statusCode: 200, body: tierJson);
        }
        return (statusCode: 404, body: '{}');
      });

      final client = AntigravityQuotaClient(
        clientFactory: () => fakeHttp,
        tokenReader: ({profileId, supportDir}) async => 'valid-bearer-token',
        clock: () => testNow,
      );

      final reading = await client.fetchUsage();
      expect(reading.providerId, 'antigravity');
      expect(reading.displayName, 'Antigravity');
      expect(reading.needsSignIn, isFalse);
      expect(reading.planLabel, 'Google AI Pro');
      expect(reading.windows.length, 3);

      // Windows sorted: 5h first, weekly second, other third
      final fiveHour = reading.windows[0];
      expect(fiveHour.windowId, '5h');
      expect(fiveHour.durationSeconds, 18000);
      expect(fiveHour.remainingPercent, 85);
      expect(fiveHour.resetsAt, DateTime.utc(2026, 11, 8, 1, 16, 25));

      final weekly = reading.windows[1];
      expect(weekly.windowId, 'weekly');
      expect(weekly.durationSeconds, 604800);
      expect(weekly.remainingPercent, 0);
      expect(weekly.resetsAt, DateTime.utc(2026, 11, 11, 10, 5, 57));

      final gemini = reading.windows[2];
      expect(gemini.windowId, 'gemini');
      expect(gemini.durationSeconds, isNull);
      expect(gemini.remainingPercent, 100);
      expect(gemini.label, 'Gemini (Flash)');
      expect(gemini.resetsAt, DateTime.utc(2026, 11, 8, 1, 16, 30));
    });

    test('network failure returns cached reading when available', () async {
      int calls = 0;
      final fakeHttp = _FakeHttpClient((uri) {
        calls++;
        if (calls <= 3) {
          if (uri.path.contains('retrieveUserQuotaSummary')) {
            return (
              statusCode: 200,
              body: '{"groups":[{"buckets":[{"window":"weekly","remainingFraction":0.4}]}]}'
            );
          }
          return (statusCode: 200, body: '{}');
        }
        throw const SocketException('No route to host');
      });

      final client = AntigravityQuotaClient(
        clientFactory: () => fakeHttp,
        tokenReader: ({profileId, supportDir}) async => 'token',
        clock: () => testNow,
      );

      final first = await client.fetchUsage();
      expect(first.windows.length, 1);
      expect(first.windows.first.remainingPercent, 40);

      // Second fetch encounters network error and returns cached
      final second = await client.fetchUsage();
      expect(second.windows.first.remainingPercent, 40);
    });
  });
}
