/// Thrown by every per-service API client on failure.
///
/// [statusCode] is the HTTP status when one was received, null for
/// transport errors (timeout, DNS, connection refused).
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'ApiException: $message${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}
