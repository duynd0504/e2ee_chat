import 'package:e2ee_demo/models/group_summary_model.dart';
import 'package:e2ee_demo/services/app_service.dart';
import 'package:e2ee_demo/ui/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GroupListScreen extends StatefulWidget {
  final AppServices services;

  const GroupListScreen({super.key, required this.services});

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> {
  List<Map<String, dynamic>> _groups = [];

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    getUserGroups().then((groups) {
      setState(() {
        _groups = groups.map((g) => {'id': g.id, 'name': g.name}).toList();
        _loading = false;
      });
    }).catchError((e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    });
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final groups = await getUserGroups();
      setState(() {
        _groups = groups.map((g) => {'id': g.id, 'name': g.name}).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<List<GroupSummary>> getUserGroups() async {
    const query = r'''
    query GetUserGroups($page: Int!, $limit: Int!) {
      getUserGroups(input: { page: $page, limit: $limit }) {
        data {
          items {
            id
            name
          }
        }
      }
    }
  ''';

    final result = await widget.services.gql.runQuery(
      query,
      variables: {'page': 1, 'limit': 50},
    );

    if (result.hasException) {
      debugPrint('getUserGroups exception: ${result.exception}');
      return [];
    }
    final data = result.data?['getUserGroups']?['data']?['items'] as List?;
    if (data == null) return [];

    return data
        .map((e) => GroupSummary.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Groups'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showCreateGroupDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadGroups,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadGroups,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.group_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No groups yet',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a group to start chatting',
              style: TextStyle(color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _showCreateGroupDialog,
              icon: const Icon(Icons.add),
              label: const Text('Create Group'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadGroups,
      child: ListView.builder(
        itemCount: _groups.length,
        itemBuilder: (context, index) {
          final group = _groups[index];
          return _buildGroupTile(group, index);
        },
      ),
    );
  }

  Widget _buildGroupTile(Map<String, dynamic> group, int index) {
    final groupName = group['name'] ?? 'Unnamed Group';
    final groupId = group['id'] as String;

    // Tạo màu khác nhau cho mỗi group
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
    ];
    final color = colors[index % colors.length];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color[700],
          child: Text(
            groupName.isNotEmpty ? groupName[0].toUpperCase() : 'G',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
        ),
        title: Text(
          groupName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            // Hiển thị 8 ký tự đầu của Group ID
            Text(
              'ID: ${groupId.substring(0, 8)}...',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Nút copy Group ID
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy Group ID',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: groupId));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied: $groupId'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
            // Nút rename
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Rename Group',
              onPressed: () => _showRenameGroupDialog(groupId, groupName),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                services: widget.services,
                groupId: groupId,
                groupName: groupName,
              ),
            ),
          );
        },
        onLongPress: () {
          // Long press để show full info
          _showGroupInfoDialog(groupId, groupName);
        },
      ),
    );
  }

  void _showGroupInfoDialog(String groupId, String groupName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Group Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name: $groupName', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Group ID:', style: TextStyle(fontWeight: FontWeight.bold)),
            SelectableText(
              groupId,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: groupId));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Group ID copied!')),
              );
            },
            child: const Text('Copy ID'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showRenameGroupDialog(String groupId, String currentName) {
    final nameController = TextEditingController(text: currentName);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Group'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'New Name',
            hintText: 'Enter new group name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              if (newName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a name')),
                );
                return;
              }
              if (newName == currentName) {
                Navigator.pop(context);
                return;
              }

              Navigator.pop(context);
              await _renameGroup(groupId, newName);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _renameGroup(String groupId, String newName) async {
    try {
      const mutation = '''
        mutation UpdateGroup(\$groupId: String!, \$name: String!) {
          updateGroup(groupId: \$groupId, input: { name: \$name }) {
            success
            message
          }
        }
      ''';

      final result = await widget.services.gql.mutate(
        mutation,
        variables: {
          'groupId': groupId,
          'name': newName,
        },
      );

      if (result['updateGroup']?['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Group renamed successfully')),
          );
        }
        await _loadGroups();
      } else {
        throw Exception(
            result['updateGroup']?['message'] ?? 'Failed to rename group');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _showCreateGroupDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Group Name',
                hintText: 'Enter group name',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Enter description',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter group name')),
                );
                return;
              }

              Navigator.pop(context);
              await _createGroup(name, descController.text.trim());
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _createGroup(String name, String description) async {
    try {
      const mutation = '''
        mutation CreateGroup(\$name: String!, \$description: String) {
          createGroup(name: \$name, description: \$description) {
            success
            message
            data {
              id
              name
              description
            }
          }
        }
      ''';

      final result = await widget.services.gql.mutate(
        mutation,
        variables: {
          'name': name,
          'description': description.isEmpty ? null : description,
        },
      );

      if (result['createGroup']?['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Group created successfully')),
          );
        }
        await _loadGroups();
      } else {
        throw Exception(
            result['createGroup']?['message'] ?? 'Failed to create group');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}