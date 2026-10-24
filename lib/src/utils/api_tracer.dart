// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
class ApiTracer {
  static const String _tag = '[Frappe API]';

  /// Field names whose values are credentials and must never reach a log:
  /// passwords, OTPs, access/refresh tokens, API keys, API and client
  /// secrets, PKCE verifiers and OAuth authorization codes. Matched
  /// case-insensitively against each key of a Map body or query, at any
  /// depth. Short generic names (`pwd`, `sid`, `key`, `code`) match only as
  /// the whole key, so `monkey` or `item_code` are still printed.
  static final RegExp _sensitiveKey = RegExp(
    r'password|passwd|secret|token|otp|code_verifier|authorization|api[_-]?key'
    r'|^pwd$|^sid$|^key$|^code$',
    caseSensitive: false,
  );

  static const String _redacted = 'REDACTED';

  /// One `key=value` pair of a form-urlencoded string or URL query. The key
  /// must start the string or follow `&` / `?` and hold no whitespace, so
  /// prose such as a server traceback (`token = get_token()`) is not taken
  /// for a form body.
  static final RegExp _formPair = RegExp(r'(^|[&?])([^=&?\s]+)=([^&]*)');

  /// How many string layers (JSON in a string, an encoded form value) are
  /// unwrapped before a string is printed as it is.
  static const int _maxStringDepth = 8;

  /// Returns [value] with the value of every credential-named key replaced
  /// by `REDACTED`, so a debug trace of a login or refresh call does not
  /// print the password, OTP or token it carries. A String (a whole body, or
  /// a value inside a Map or List) is redacted too when it holds JSON or a
  /// form-urlencoded body, and stays a String.
  @visibleForTesting
  static dynamic redact(dynamic value) => _redact(value, 0);

  static dynamic _redact(dynamic value, int depth) {
    if (value is Map) {
      return value.map(
        (k, v) => MapEntry(
          k,
          _sensitiveKey.hasMatch(k.toString()) ? _redacted : _redact(v, depth),
        ),
      );
    }
    if (value is List) return value.map((e) => _redact(e, depth)).toList();
    if (value is String) return _redactString(value, depth);
    return value;
  }

  /// [s] with credential values replaced, or [s] itself when nothing in it
  /// needed redacting. JSON (`{...}` / `[...]`) is decoded and redacted like
  /// a Map; otherwise every `key=value` pair with a credential-named key has
  /// its value replaced. Never throws: on any failure [s] is returned as it
  /// is, which is what the tracer printed before strings were redacted.
  static String _redactString(String s, int depth) {
    if (depth >= _maxStringDepth) return s;
    try {
      final t = s.trimLeft();
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          final decoded = jsonDecode(s);
          final encoded = jsonEncode(_redact(decoded, depth + 1));
          // Keep the original text (and its formatting) when nothing changed.
          return encoded == jsonEncode(decoded) ? s : encoded;
        } on FormatException {
          // Not JSON after all: try it as a form body below.
        }
      }
      if (!s.contains('=')) return s;
      return s.replaceAllMapped(_formPair, (m) {
        final lead = m[1]!;
        final rawKey = m[2]!;
        final key = _decodeComponent(rawKey) ?? rawKey;
        if (_sensitiveKey.hasMatch(key)) return '$lead$rawKey=$_redacted';
        // A non-secret value may itself carry JSON or a URL with secrets.
        final value = _decodeComponent(m[3]!);
        if (value == null) return m[0]!;
        final inner = _redactString(value, depth + 1);
        return inner == value
            ? m[0]!
            : '$lead$rawKey=${Uri.encodeQueryComponent(inner)}';
      });
    } catch (_) {
      return s;
    }
  }

  /// [component] percent-decoded, or null when its escapes are malformed.
  static String? _decodeComponent(String component) {
    try {
      return Uri.decodeQueryComponent(component);
    } catch (_) {
      return null;
    }
  }

  /// [url] with the value of every credential-named query parameter
  /// replaced, for the same reason as [redact]. A non-secret parameter whose
  /// value holds JSON with a credential in it is redacted as well.
  @visibleForTesting
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    try {
      var changed = false;
      final params = uri.queryParametersAll.map((k, v) {
        if (_sensitiveKey.hasMatch(k)) {
          changed = true;
          return MapEntry<String, Object>(k, _redacted);
        }
        final values = [for (final s in v) _redactString(s, 0)];
        if (!listEquals(values, v)) changed = true;
        return MapEntry<String, Object>(k, values);
      });
      if (!changed) return url;
      return uri.replace(queryParameters: params).toString();
    } catch (_) {
      // A query Uri cannot decode (a broken percent escape): redact the raw
      // text instead of printing it as it is.
      return _redactString(url, 0);
    }
  }

  /// Caps a body / Map / List string at 500 chars for log readability.
  /// Non-collection bodies pass through as `toString()`. Shared by
  /// [traceRequest] and [traceResponse] so a threshold change applies to
  /// both at once. Credential-named keys are redacted first, in String
  /// bodies (JSON or form-urlencoded) as well.
  static String _preview(dynamic body) {
    if (body is Map || body is List) {
      final s = redact(body).toString();
      return s.length > 500 ? '${s.substring(0, 500)}...' : s;
    }
    return redact(body).toString();
  }

  /// Log request (method, url, body). No-op in release.
  static void traceRequest({
    required String method,
    required String url,
    Map<String, dynamic>? queryParams,
    dynamic body,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer();
    buffer.writeln('$_tag REQUEST $method ${redactUrl(url)}');
    if (queryParams != null && queryParams.isNotEmpty) {
      buffer.writeln('  query: ${redact(queryParams)}');
    }
    if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }

  /// Log response (status, body or error). No-op in release.
  static void traceResponse({
    required int statusCode,
    required String url,
    dynamic body,
    Object? error,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer();
    buffer.writeln('$_tag RESPONSE $statusCode ${redactUrl(url)}');
    if (error != null) {
      buffer.writeln('  error: $error');
    } else if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }
}
