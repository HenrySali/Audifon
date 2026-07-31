/// Estado de ejecución de un test individual.
enum TestStatus { idle, running, completed, error }

/// Resultado de un test individual de diagnóstico.
class TestResult {
  final String testName;
  final TestStatus status;
  final Map<String, dynamic> data;
  final DateTime? completedAt;
  final String? errorMessage;

  TestResult({
    required this.testName,
    this.status = TestStatus.idle,
    this.data = const {},
    this.completedAt,
    this.errorMessage,
  });

  TestResult copyWith({
    TestStatus? status,
    Map<String, dynamic>? data,
    DateTime? completedAt,
    String? errorMessage,
  }) {
    return TestResult(
      testName: testName,
      status: status ?? this.status,
      data: data ?? this.data,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
