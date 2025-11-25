import 'package:e2ee_demo/services/app_service.dart';
import 'package:e2ee_demo/ui/chat_screen.dart';
import 'package:flutter/material.dart';

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
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      const query = r'''
    query GetGroupMembers($groupId: String!, $page: Int!, $limit: Int!) {
      getGroupMembers(groupId: $groupId, page: $page, limit: $limit) {
        data {
          items {
            userId
            username
            deviceIds
          }
        }
      }
    }
    ''';

      final result = await widget.services.gql.query(
        query,
        variables: {
          'page': 1.0,    // double
          'limit': 100.0, // double
        },
      );

      if (result['getUserGroups'] != null) {
        final response = result['getUserGroups'];

        if (response['success'] == true && response['data'] != null) {
          final items = response['data']['items'] as List<dynamic>?;
          setState(() {
            _groups = items?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
            _loading = false;
          });
        } else {
          throw Exception(response['error'] ?? 'Failed to load groups');
        }
      } else {
        throw Exception('Invalid response format');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
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
          return _buildGroupTile(group);
        },
      ),
    );
  }

  Widget _buildGroupTile(Map<String, dynamic> group) {
    final groupName = group['name'] ?? 'Unnamed Group';
    final groupId = group['id'];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue[700],
          child: group['avatar'] != null && group['avatar'].isNotEmpty
              ? ClipOval(
                  child: Image.network(
                    group['avatar'],
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return const Icon(Icons.group, color: Colors.white);
                    },
                  ),
                )
              : const Icon(Icons.group, color: Colors.white),
        ),
        title: Text(
          groupName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group['description'] != null && group['description'].isNotEmpty)
              Text(
                group['description'],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
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
      ),
    );
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
        throw Exception(result['createGroup']?['message'] ?? 'Failed to create group');
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
