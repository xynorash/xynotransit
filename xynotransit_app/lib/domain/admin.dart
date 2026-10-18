/// What a manager types when defining the counts of a seat. [id] is null for a new one.
class MetricInput {
  const MetricInput({this.id, required this.label});
  final String? id;
  final String label;
}

/// What a manager types when defining the targets of a seat. [id] is null for a new one.
class KpiInput {
  const KpiInput({this.id, required this.text});
  final String? id;
  final String text;
}

/// Limits shared by the forms, the in-memory demo and the API.
abstract final class DefinitionRules {
  static const maxMetrics = 8;
  static const maxKpis = 20;
  static const maxMetricLabel = 60;
  static const maxKpiText = 200;
  static const maxRoleTitle = 80;
  static const maxName = 80;
}
