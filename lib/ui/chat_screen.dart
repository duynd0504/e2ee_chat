import 'dart:async';
import 'dart:convert';
import 'package:e2ee_demo/services/app_service.dart';
import 'package:flutter/material.dart';

class ChatMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String senderDeviceId;
  final DateTime createdAt;
  final String plaintext;
  final bool fromMe;

  ChatMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderDeviceId,
    required this.createdAt,
    required this.plaintext,
    required this.fromMe,
  });
}

class ChatScreen extends StatefulWidget {
  final AppServices services;
  final String groupId;
  final String groupName;

  const ChatScreen({
    super.key,
    required this.services,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  Timer? _pollTimer;
  bool _loading = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadMessages(
      widget.groupId,
    );
    // Poll messages mỗi 3 giây
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _loadMessages(
        widget.groupId,
      );
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    const query = r'''
        query GetGroupMembers($groupId: String!, $page: Float!, $limit: Float!) {
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

    final result = await widget.services.gql.runQuery(query, variables: {
      'groupId': groupId,
      'page': 1.0,
      'limit': 100.0,
    });

    if (result.hasException) {
      debugPrint('getGroupMembers exception: ${result.exception}');
      return [];
    }
    final items =
    result.data?['getGroupMembers']?['data']?['items'] as List<dynamic>?;
    if (items == null) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _loadMessages(String groupId) async {
    if (_loading) return;
    _loading = true;

    try {
      const query = r'''
        query GetMessages($input: GetMessagesInput!) {
          getMessages(input: $input) {
            data {
              items {
                id
                content
                contentType
                ciphertextBase64
                senderId
                senderDeviceId
                groupId
                createdAt
              }
            }
            success
            error
          }
        }
        ''';

      final result = await widget.services.gql.runQuery(query, variables: {
        'input': {
          'groupId': groupId,
          'page': 1,
          'limit': 200,
        }
      });

      if (result.hasException) {
        debugPrint('getMessages exception: ${result.exception}');
      }

      final data = result.data?['getMessages'];
      if (data == null || data['success'] != true) {
        debugPrint('getMessages failed: ${data?['error']}');
        return;
      }

      final items = data['data']?['items'] as List<dynamic>? ?? [];
      final msgs = <ChatMessage>[];

      for (final m in items) {
        final groupId = m['groupId'] as String? ?? '';
        if (groupId != widget.groupId) continue;

        final contentType = m['contentType'] as String? ?? '';
        final senderId = m['senderId'] as String? ?? '';
        final senderDeviceId = m['senderDeviceId'] as String? ?? '';
        final createdAtStr = m['createdAt'] as String?;
        final createdAt = createdAtStr != null
            ? DateTime.parse(createdAtStr)
            : DateTime.now();

        String? plaintext;

        if (contentType == 'E2EE') {
          final ct = m['ciphertextBase64'] as String?;

          // ===== DEBUG LOGS =====
          debugPrint('========================================');
          debugPrint('🔍 Attempting to decrypt message');
          debugPrint('Message ID: ${m['id']}');
          debugPrint('GroupId: $groupId');
          debugPrint('SenderId: $senderId');
          debugPrint('SenderDeviceId: $senderDeviceId');
          debugPrint('My UserId: ${widget.services.myUserId}');
          debugPrint('My DeviceId: ${widget.services.myDeviceId}');
          debugPrint('Ciphertext length: ${ct?.length ?? 0}');
          debugPrint('Ciphertext (first 50 chars): ${ct?.substring(0, ct.length > 50 ? 50 : ct.length)}');
          // ===== END DEBUG LOGS =====

          if (ct != null && ct.isNotEmpty) {
            try {
              plaintext = await widget.services.signalClient.tryDecryptGroupMessage(
                groupId: groupId,
                senderId: senderId,
                senderDeviceId: senderDeviceId,
                ciphertextBase64: ct,
              );
              debugPrint('✅ Decryption SUCCESS: $plaintext');
            } catch (e, stackTrace) {
              debugPrint('❌ Decryption ERROR: $e');
              debugPrint('Stack trace: $stackTrace');
              plaintext = '[cannot decrypt: ${e.toString()}]';
            }
          }
        } else if (contentType == 'E2EE_SYSTEM') {
          // System message để setup sender keys
          final ct = m['ciphertextBase64'] as String?;
          debugPrint('🔧 Processing E2EE_SYSTEM message from $senderId ($senderDeviceId)');
          if (ct != null && ct.isNotEmpty) {
            try {
              await widget.services.signalClient.handleSystemMessage(
                fromUserId: senderId,
                fromDeviceId: senderDeviceId,
                ciphertextBase64: ct,
              );
              debugPrint('✅ System message processed successfully');
            } catch (e) {
              debugPrint('❌ System message processing error: $e');
            }
          }
          continue; // Không hiển thị system message
        } else {
          // Tin nhắn không mã hóa - bỏ qua trong demo này
          debugPrint('⚠️ Skipping non-E2EE message type: $contentType');
          continue;
        }

        plaintext ??= '[cannot decrypt]';

        msgs.add(ChatMessage(
          id: m['id'] as String,
          groupId: groupId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          createdAt: createdAt,
          plaintext: plaintext,
          fromMe: senderId == widget.services.myUserId &&
              senderDeviceId == widget.services.myDeviceId,
        ));
      }

      msgs.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(msgs);
        });

        // Auto scroll to bottom nếu đã ở gần bottom
        if (_scrollController.hasClients) {
          final maxScroll = _scrollController.position.maxScrollExtent;
          final currentScroll = _scrollController.position.pixels;
          if (maxScroll - currentScroll < 100) {
            _scrollToBottom();
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('❌ loadMessages error: $e');
      debugPrint('Stack trace: $stackTrace');
    } finally {
      _loading = false;
    }
  }

  Future<List<Map<String, dynamic>>> getMessagesForGroup(String groupId) async {
    const query = r'''
        query GetMessages($input: GetMessagesInput!) {
          getMessages(input: $input) {
            data {
              items {
                id
                content
                contentType
                ciphertextBase64
                senderId
                senderDeviceId
                groupId
                createdAt
              }
            }
            success
            error
          }
        }
        ''';

    final result = await widget.services.gql.runQuery(query, variables: {
      'input': {
        'groupId': groupId,
        'page': 1,
        'limit': 200,
      }
    });

    if (result.hasException) {
      debugPrint('getMessages exception: ${result.exception}');
      return [];
    }

    final data = result.data?['getMessages'];
    if (data == null || data['success'] != true) return [];
    final items = data['data']?['items'] as List<dynamic>?;
    if (items == null) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();

    debugPrint('📤 Sending message: $text');

    try {
      final ciphertextBytes =
      await widget.services.signalClient.encryptGroupPlaintext(
        groupId: widget.groupId,
        plaintext: text,
      );
      final ctBase64 = base64Encode(ciphertextBytes);

      debugPrint('✅ Message encrypted, length: ${ctBase64.length}');

      await widget.services.gql.sendEncryptedMessage(
        groupId: widget.groupId,
        recipientId: null,
        deviceId: widget.services.myDeviceId,
        ciphertextBase64: ctBase64,
        contentType: 'E2EE',
      );

      debugPrint('✅ Message sent successfully');
    } catch (e, stackTrace) {
      debugPrint('❌ Error sending message: $e');
      debugPrint('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.groupName),
            const Text(
              '🔒 End-to-end encrypted',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadMessages(widget.groupId),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline,
                      size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'No messages yet',
                    style:
                    TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Send a message to start',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                ],
              ),
            )
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                return _buildMessageBubble(m);
              },
            ),
          ),
          const Divider(height: 1),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final align = message.fromMe ? Alignment.centerRight : Alignment.centerLeft;
    final color = message.fromMe ? Colors.blue.shade100 : Colors.grey.shade300;

    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!message.fromMe)
              Text(
                '${message.senderId} (${message.senderDeviceId})',
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.black54,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (!message.fromMe) const SizedBox(height: 4),
            Text(
              message.plaintext,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(message.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays > 0) {
      return '${time.day}/${time.month} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      return '${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: !_sending,
              decoration: InputDecoration(
                hintText: 'Type a message...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            backgroundColor: Colors.blue,
            child: _sending
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
                : IconButton(
              icon: const Icon(Icons.send, color: Colors.white),
              onPressed: _sendMessage,
            ),
          ),
        ],
      ),
    );
  }
}