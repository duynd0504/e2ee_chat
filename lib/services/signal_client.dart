import 'dart:convert';
import 'dart:typed_data';
import 'package:e2ee_demo/services/graphql_service.dart';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;

/// Envelope type để wrap message content
class AppMessageEnvelope {
  final String type;
  final Map<String, dynamic> body;

  AppMessageEnvelope({required this.type, required this.body});

  Map<String, dynamic> toJson() => {
    'type': type,
    'body': body,
  };

  static AppMessageEnvelope fromJson(Map<String, dynamic> json) {
    return AppMessageEnvelope(
      type: json['type'] as String,
      body: Map<String, dynamic>.from(json['body'] as Map),
    );
  }
}

class SignalClient {
  final GraphQLService gql;
  final String myUserId;
  final String myDeviceId;

  late final signal.IdentityKeyPair _identityKeyPair;
  late final int _registrationId;
  late final signal.InMemorySessionStore _sessionStore;
  late final signal.InMemoryPreKeyStore _preKeyStore;
  late final signal.InMemorySignedPreKeyStore _signedPreKeyStore;
  late final signal.InMemoryIdentityKeyStore _identityStore;
  late final signal.InMemorySenderKeyStore _senderKeyStore;

  final Map<String, signal.GroupCipher> _groupCiphers = {};
  final Map<String, signal.SessionCipher> _sessionCipherCache = {};

  // Track which groups we've sent SKDM for
  final Set<String> _distributedGroups = {};

  SignalClient({
    required this.gql,
    required this.myUserId,
    required this.myDeviceId,
  });

  Future<void> initialize() async {
    await _installLocalSignalState();

    try {
      await _registerKeysToBackend();
    } catch (e) {
      debugPrint('⚠️ Key registration skipped (mutation not found): $e');
      debugPrint('You can continue using the app, but E2EE may not work fully');
    }
  }

  Future<void> _installLocalSignalState() async {
    _identityKeyPair = signal.generateIdentityKeyPair();
    _registrationId = signal.generateRegistrationId(false);

    final preKeys = signal.generatePreKeys(0, 110);
    final signedPreKey = signal.generateSignedPreKey(_identityKeyPair, 0);

    _sessionStore = signal.InMemorySessionStore();
    _preKeyStore = signal.InMemoryPreKeyStore();
    _signedPreKeyStore = signal.InMemorySignedPreKeyStore();
    _identityStore =
        signal.InMemoryIdentityKeyStore(_identityKeyPair, _registrationId);
    _senderKeyStore = signal.InMemorySenderKeyStore();

    for (final p in preKeys) {
      await _preKeyStore.storePreKey(p.id, p);
    }
    await _signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
  }

  Future<void> _registerKeysToBackend() async {
    final signedPreKeyRecord = await _signedPreKeyStore.loadSignedPreKey(0);

    final identityKeyBytes =
    _identityKeyPair.getPublicKey().serialize().toList();
    final signedPreKeyBytes =
    signedPreKeyRecord.getKeyPair().publicKey.serialize().toList();
    final signedPreKeySigBytes = signedPreKeyRecord.signature;

    final oneTimePreKeys = <Map<String, dynamic>>[];
    for (var id = 0; id < 50; id++) {
      final preKey = await _preKeyStore.loadPreKey(id);
      oneTimePreKeys.add({
        'uid': id,
        'publicKey': base64Encode(preKey
            .getKeyPair()
            .publicKey
            .serialize()
            .toList()),
      });
    }

    const mutation = r'''
        mutation RegisterSignalKey($input: SignalKeyCreateInput!) {
          registerSignalKey(input: $input) {
            success
            data {
              id
            }
          }
        }
        ''';

    final variables = {
      'input': {
        'identityKey': base64Encode(identityKeyBytes),
        'signedPreKey': base64Encode(signedPreKeyBytes),
        'signedPreKeySig': base64Encode(signedPreKeySigBytes),
        'oneTimePreKeys': oneTimePreKeys,
        'deviceId': myDeviceId,
      }
    };
    final result = await gql.runMutation(mutation, variables: variables);
    if (result.hasException) {
      debugPrint('registerSignalKey exception: ${result.exception}');
      return;
    }
    final data = result.data?['registerSignalKey'];
    if (data == null || data['success'] != true) {
      debugPrint('registerSignalKey failed: $data');
    }
  }

  int _deviceAddressId(String deviceId) {
    final hash = deviceId.hashCode;
    return hash & 0x7fffffff;
  }

  signal.SignalProtocolAddress _addressFor(String userId, String deviceId) {
    return signal.SignalProtocolAddress(userId, _deviceAddressId(deviceId));
  }

  Future<signal.SessionCipher> _ensureSessionCipherFor(
      String remoteUserId,
      String remoteDeviceId,
      ) async {
    final key = '$remoteUserId::$remoteDeviceId';
    final existing = _sessionCipherCache[key];
    if (existing != null) return existing;

    const query = r'''
    query GetSignalKey($input: SignalKeyGetInput!) {
      getSignalKey(input: $input) {
        success
        data {
          items {
            id
            identityKey
            signedPreKey
            signedPreKeySig
            oneTimePreKeys {
              uid
              publicKey
            }
            deviceId
          }
        }
      }
    }
    ''';

    final result = await gql.query(query, variables: {
      'input': {
        'userId': remoteUserId,
        'deviceId': remoteDeviceId,
        'page': 1,
        'limit': 1,
      }
    });

    final wrapper = result['getSignalKey'];
    if (wrapper == null || wrapper['success'] != true) {
      throw Exception('No SignalKey for $remoteUserId/$remoteDeviceId');
    }

    final items = wrapper['data']?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) {
      throw Exception('No SignalKey items found');
    }

    final signalKey = Map<String, dynamic>.from(items.first as Map);
    final oneTimeList = signalKey['oneTimePreKeys'] as List<dynamic>?;
    if (oneTimeList == null || oneTimeList.isEmpty) {
      throw Exception('Remote user has no one‑time prekeys');
    }

    final firstPreKey = Map<String, dynamic>.from(oneTimeList.first as Map);
    final preKeyId = firstPreKey['uid'] as int;
    final preKeyPublicBytes = base64Decode(firstPreKey['publicKey'] as String);

    final signedPreKeyBytes = base64Decode(signalKey['signedPreKey'] as String);
    final signedPreKeySigBytes =
    base64Decode(signalKey['signedPreKeySig'] as String);

    final identityKeyBytes = base64Decode(signalKey['identityKey'] as String);

    final remoteIdentityKey = signal.IdentityKey(
        signal.DjbECPublicKey(Uint8List.fromList(identityKeyBytes)));
    final remoteSignedPreKey = signal.DjbECPublicKey(signedPreKeyBytes);
    final remotePreKey = signal.DjbECPublicKey(preKeyPublicBytes);

    final remoteRegId = 1;

    final preKeyBundle = signal.PreKeyBundle(
      remoteRegId,
      _deviceAddressId(remoteDeviceId),
      preKeyId,
      remotePreKey,
      0,
      remoteSignedPreKey,
      signedPreKeySigBytes,
      remoteIdentityKey,
    );

    final remoteAddress = _addressFor(remoteUserId, remoteDeviceId);

    final builder = signal.SessionBuilder(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      remoteAddress,
    );

    await builder.processPreKeyBundle(preKeyBundle);

    final cipher = signal.SessionCipher(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      remoteAddress,
    );

    _sessionCipherCache[key] = cipher;
    return cipher;
  }

  Future<String> encryptToDevice({
    required String remoteUserId,
    required String remoteDeviceId,
    required AppMessageEnvelope envelope,
  }) async {
    final cipher = await _ensureSessionCipherFor(remoteUserId, remoteDeviceId);
    final plaintext =
    Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson())));
    final ciphertext = await cipher.encrypt(plaintext);
    final serialized = ciphertext.serialize();
    return base64Encode(serialized);
  }

  Future<AppMessageEnvelope> decryptFromDevice({
    required String remoteUserId,
    required String remoteDeviceId,
    required String ciphertextBase64,
  }) async {
    final remoteAddress = _addressFor(remoteUserId, remoteDeviceId);
    final cipher = signal.SessionCipher(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      remoteAddress,
    );

    final bytes = Uint8List.fromList(base64Decode(ciphertextBase64));
    final message = signal.PreKeySignalMessage(bytes);

    late Uint8List plaintext;
    await cipher.decryptWithCallback(message, (Uint8List value) {
      plaintext = value;
    });

    final jsonMap = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    return AppMessageEnvelope.fromJson(jsonMap);
  }

  signal.SenderKeyName _groupSenderKeyNameFor(
      String groupId,
      String senderUserId,
      String senderDeviceId,
      ) {
    final addr = _addressFor(senderUserId, senderDeviceId);
    return signal.SenderKeyName(groupId, addr);
  }

  Future<signal.GroupCipher> _ensureGroupCipherForSender(
      String groupId,
      String senderUserId,
      String senderDeviceId,
      ) async {
    final key = '$groupId::$senderUserId::$senderDeviceId';
    final existing = _groupCiphers[key];
    if (existing != null) return existing;

    final senderKeyName =
    _groupSenderKeyNameFor(groupId, senderUserId, senderDeviceId);
    final cipher = signal.GroupCipher(_senderKeyStore, senderKeyName);
    _groupCiphers[key] = cipher;
    return cipher;
  }

  /// FIXED: Distribute sender key CHỈ MỘT LẦN cho mỗi group
  Future<void> _distributeSenderKeyOnce(String groupId) async {
    // Nếu đã distribute rồi thì skip
    if (_distributedGroups.contains(groupId)) {
      debugPrint('✅ Sender key already distributed for group $groupId');
      return;
    }

    debugPrint('🔧 Distributing sender key for group $groupId...');

    final senderKeyName = _groupSenderKeyNameFor(groupId, myUserId, myDeviceId);
    final builder = signal.GroupSessionBuilder(_senderKeyStore);
    final distribution = await builder.create(senderKeyName);
    final distributionBytes = distribution.serialize();

    // Lấy danh sách members
    final members = await getGroupMembers(groupId);

    // Gửi SKDM cho tất cả devices của members khác
    for (final m in members) {
      final userId = m['userId'] as String;
      if (userId == myUserId) continue; // Skip chính mình

      final deviceIds = (m['deviceIds'] as List<dynamic>? ?? []).cast<String>().toList();

      for (final devId in deviceIds) {
        try {
          final envelope = AppMessageEnvelope(
            type: 'skdm',
            body: {
              'groupId': groupId,
              'senderUserId': myUserId,
              'senderDeviceId': myDeviceId,
              'distributionMessageBase64': base64Encode(distributionBytes),
            },
          );

          final ct = await encryptToDevice(
            remoteUserId: userId,
            remoteDeviceId: devId,
            envelope: envelope,
          );

          await gql.sendEncryptedMessage(
            groupId: null,
            recipientId: userId,
            deviceId: myDeviceId,
            ciphertextBase64: ct,
            contentType: 'E2EE_SYSTEM',
          );

          debugPrint('✅ Sent SKDM to $userId ($devId)');
        } catch (e) {
          debugPrint('❌ Failed to send SKDM to $userId ($devId): $e');
        }
      }
    }

    // Đánh dấu đã distribute
    _distributedGroups.add(groupId);
    debugPrint('✅ Sender key distribution completed for group $groupId');
  }

  Future<Uint8List> encryptGroupPlaintext({
    required String groupId,
    required String plaintext,
  }) async {
    // BƯỚC 1: Distribute sender key nếu chưa
    await _distributeSenderKeyOnce(groupId);

    // BƯỚC 2: Encrypt message với group cipher
    final cipher = await _ensureGroupCipherForSender(groupId, myUserId, myDeviceId);
    final ciphertext = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));

    debugPrint('✅ Group message encrypted, length: ${ciphertext.length}');
    return ciphertext;
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

    final result = await gql.runQuery(query, variables: {
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

  Future<String?> tryDecryptGroupMessage({
    required String groupId,
    required String senderId,
    required String senderDeviceId,
    required String ciphertextBase64,
  }) async {
    try {
      debugPrint('🔍 Attempting to decrypt group message from $senderId ($senderDeviceId)');

      final cipher = await _ensureGroupCipherForSender(groupId, senderId, senderDeviceId);
      final ciphertextBytes = Uint8List.fromList(base64Decode(ciphertextBase64));
      final plaintextBytes = await cipher.decrypt(ciphertextBytes);
      final plaintext = utf8.decode(plaintextBytes);

      debugPrint('✅ Group message decrypted successfully: $plaintext');
      return plaintext;
    } catch (e, stackTrace) {
      debugPrint('❌ Group decrypt failed: $e');
      debugPrint('Stack trace: $stackTrace');
      return null;
    }
  }

  Future<void> handleSystemMessage({
    required String fromUserId,
    required String fromDeviceId,
    required String ciphertextBase64,
  }) async {
    try {
      debugPrint('🔧 Processing system message from $fromUserId ($fromDeviceId)');

      final envelope = await decryptFromDevice(
        remoteUserId: fromUserId,
        remoteDeviceId: fromDeviceId,
        ciphertextBase64: ciphertextBase64,
      );

      if (envelope.type == 'skdm') {
        final groupId = envelope.body['groupId'] as String;
        final senderUserId = envelope.body['senderUserId'] as String;
        final senderDeviceId = envelope.body['senderDeviceId'] as String;
        final distributionBase64 = envelope.body['distributionMessageBase64'] as String;
        final distributionBytes = base64Decode(distributionBase64);

        final senderKeyName = _groupSenderKeyNameFor(groupId, senderUserId, senderDeviceId);
        final wrapper = signal.SenderKeyDistributionMessageWrapper.fromSerialized(distributionBytes);
        final builder = signal.GroupSessionBuilder(_senderKeyStore);
        await builder.process(senderKeyName, wrapper);

        debugPrint('✅ SKDM processed: group=$groupId, sender=$senderUserId ($senderDeviceId)');
      }
    } catch (e, stackTrace) {
      debugPrint('❌ handleSystemMessage failed: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Reset sender key distribution state (useful for testing)
  void resetDistributionState() {
    _distributedGroups.clear();
    debugPrint('🔄 Sender key distribution state reset');
  }
}