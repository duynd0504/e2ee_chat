class GroupSummary {
  final String id;
  final String name;

  GroupSummary({required this.id, required this.name});

  factory GroupSummary.fromJson(Map<String, dynamic> json) {
    return GroupSummary(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled group',
    );
  }
}
