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
  final Set<String> _distributedGroups = {};

  SignalClient({
    required this.gql,
    required this.myUserId,
    required this.myDeviceId,
  });

  /// Khởi tạo local Signal state và đăng ký keys
  Future<void> initialize() async {
    await _installLocalSignalState();
    try {
      await _registerKeysToBackend();
    } catch (e) {
      debugPrint('⚠️ Key registration skipped: $e');
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
        'publicKey': base64Encode(preKey.getKeyPair().publicKey.serialize().toList()),
      });
    }

    const mutation = r'''
      mutation RegisterSignalKey($input: SignalKeyCreateInput!) {
        registerSignalKey(input: $input) {
          success
          data { id }
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

  int _deviceAddressId(String deviceId) => deviceId.hashCode & 0x7fffffff;
  signal.SignalProtocolAddress _addressFor(String userId, String deviceId) =>
      signal.SignalProtocolAddress(userId, _deviceAddressId(deviceId));

  /// Đảm bảo có session cipher cho 1:1
  Future<signal.SessionCipher> _ensureSessionCipherFor(
      String remoteUserId, String remoteDeviceId) async {
    final key = '$remoteUserId::$remoteDeviceId';
    if (_sessionCipherCache.containsKey(key)) return _sessionCipherCache[key]!;

    const query = r'''
      query GetSignalKey($input: SignalKeyGetInput!) {
        getSignalKey(input: $input) {
          success
          data { items {
            id identityKey signedPreKey signedPreKeySig
            oneTimePreKeys { uid publicKey }
            deviceId
          } }
        }
      }
    ''';

    final result = await gql.query(query, variables: {
      'input': {'userId': remoteUserId, 'deviceId': remoteDeviceId, 'page': 1, 'limit': 1}
    });

    final wrapper = result['getSignalKey'];
    if (wrapper == null || wrapper['success'] != true)
      throw Exception('No SignalKey for $remoteUserId/$remoteDeviceId');

    final items = wrapper['data']?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty)
      throw Exception('No SignalKey items found');

    final signalKey = Map<String, dynamic>.from(items.first as Map);
    final oneTimeList = signalKey['oneTimePreKeys'] as List<dynamic>?;
    if (oneTimeList == null || oneTimeList.isEmpty)
      throw Exception('Remote user has no one-time prekeys');

    final firstPreKey = Map<String, dynamic>.from(oneTimeList.first as Map);
    final preKeyId = firstPreKey['uid'] as int;
    final preKeyPublicBytes = base64Decode(firstPreKey['publicKey'] as String);
    final signedPreKeyBytes = base64Decode(signalKey['signedPreKey'] as String);
    final signedPreKeySigBytes = base64Decode(signalKey['signedPreKeySig'] as String);
    final identityKeyBytes = base64Decode(signalKey['identityKey'] as String);

    final remoteIdentityKey =
    signal.IdentityKey(signal.DjbECPublicKey(Uint8List.fromList(identityKeyBytes)));
    final remoteSignedPreKey = signal.DjbECPublicKey(signedPreKeyBytes);
    final remotePreKey = signal.DjbECPublicKey(preKeyPublicBytes);

    final preKeyBundle = signal.PreKeyBundle(
      1,
      _deviceAddressId(remoteDeviceId),
      preKeyId,
      remotePreKey,
      0,
      remoteSignedPreKey,
      signedPreKeySigBytes,
      remoteIdentityKey,
    );

    final builder = signal.SessionBuilder(
        _sessionStore, _preKeyStore, _signedPreKeyStore, _identityStore, _addressFor(remoteUserId, remoteDeviceId));
    await builder.processPreKeyBundle(preKeyBundle);

    final cipher = signal.SessionCipher(
        _sessionStore, _preKeyStore, _signedPreKeyStore, _identityStore, _addressFor(remoteUserId, remoteDeviceId));
    _sessionCipherCache[key] = cipher;
    return cipher;
  }

  /// Encrypt 1:1
  Future<String> encryptToDevice({
    required String remoteUserId,
    required String remoteDeviceId,
    required AppMessageEnvelope envelope,
  }) async {
    final cipher = await _ensureSessionCipherFor(remoteUserId, remoteDeviceId);
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson())));
    final ciphertext = await cipher.encrypt(plaintext);
    return base64Encode(ciphertext.serialize());
  }

  /// Decrypt 1:1
  Future<AppMessageEnvelope?> decryptFromDevice({
    required String remoteUserId,
    required String remoteDeviceId,
    required String ciphertextBase64,
  }) async {
    try {
      final cipher = signal.SessionCipher(
        _sessionStore,
        _preKeyStore,
        _signedPreKeyStore,
        _identityStore,
        _addressFor(remoteUserId, remoteDeviceId),
      );

      final bytes = Uint8List.fromList(base64Decode(ciphertextBase64));
      final message = signal.PreKeySignalMessage(bytes);
      late Uint8List plaintext;

      await cipher.decryptWithCallback(message, (v) => plaintext = v);
      return AppMessageEnvelope.fromJson(jsonDecode(utf8.decode(plaintext)));
    } catch (e, stackTrace) {
      debugPrint('❌ decryptFromDevice failed: $e\n$stackTrace');
      return null;
    }
  }

  signal.SenderKeyName _groupSenderKeyNameFor(String groupId, String senderUserId, String senderDeviceId) {
    return signal.SenderKeyName(groupId, _addressFor(senderUserId, senderDeviceId));
  }

  Future<signal.GroupCipher> _ensureGroupCipherForSender(String groupId, String senderUserId, String senderDeviceId) async {
    final key = '$groupId::$senderUserId::$senderDeviceId';
    if (_groupCiphers.containsKey(key)) return _groupCiphers[key]!;

    final cipher = signal.GroupCipher(_senderKeyStore, _groupSenderKeyNameFor(groupId, senderUserId, senderDeviceId));
    _groupCiphers[key] = cipher;
    return cipher;
  }

  /// Distribute sender key một lần cho group
  Future<void> _distributeSenderKeyOnce(String groupId) async {
    if (_distributedGroups.contains(groupId)) return;

    final senderKeyName = _groupSenderKeyNameFor(groupId, myUserId, myDeviceId);
    final builder = signal.GroupSessionBuilder(_senderKeyStore);
    final distributionBytes = (await builder.create(senderKeyName)).serialize();

    final members = await getGroupMembers(groupId);
    for (final m in members) {
      final userId = m['userId'] as String;
      if (userId == myUserId) continue;
      final deviceIds = (m['deviceIds'] as List<dynamic>? ?? []).cast<String>();
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

          final ct = await encryptToDevice(remoteUserId: userId, remoteDeviceId: devId, envelope: envelope);
          await gql.sendEncryptedMessage(groupId: null, recipientId: userId, deviceId: myDeviceId, ciphertextBase64: ct, contentType: 'E2EE_SYSTEM');
        } catch (e) {
          debugPrint('❌ Failed to send SKDM to $userId ($devId): $e');
        }
      }
    }

    _distributedGroups.add(groupId);
  }

  Future<Uint8List> encryptGroupPlaintext({required String groupId, required String plaintext}) async {
    await _distributeSenderKeyOnce(groupId);
    final cipher = await _ensureGroupCipherForSender(groupId, myUserId, myDeviceId);
    return await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
  }

  /// Decrypt group message
  Future<String?> tryDecryptGroupMessage({
    required String groupId,
    required String senderId,
    required String senderDeviceId,
    required String ciphertextBase64,
  }) async {
    try {
      final cipher = await _ensureGroupCipherForSender(groupId, senderId, senderDeviceId);
      final plaintext = await cipher.decrypt(Uint8List.fromList(base64Decode(ciphertextBase64)));
      return utf8.decode(plaintext);
    } catch (e, stackTrace) {
      debugPrint('❌ Group decrypt failed: $e\n$stackTrace');
      return null;
    }
  }

  Future<void> handleSystemMessage({required String fromUserId, required String fromDeviceId, required String ciphertextBase64}) async {
    try {
      final envelope = await decryptFromDevice(remoteUserId: fromUserId, remoteDeviceId: fromDeviceId, ciphertextBase64: ciphertextBase64);
      if (envelope?.type == 'skdm') {
        final groupId = envelope!.body['groupId'] as String;
        final senderUserId = envelope.body['senderUserId'] as String;
        final senderDeviceId = envelope.body['senderDeviceId'] as String;
        final distributionBytes = base64Decode(envelope.body['distributionMessageBase64'] as String);

        final builder = signal.GroupSessionBuilder(_senderKeyStore);
        await builder.process(_groupSenderKeyNameFor(groupId, senderUserId, senderDeviceId),
            signal.SenderKeyDistributionMessageWrapper.fromSerialized(distributionBytes));
      }
    } catch (e, stackTrace) {
      debugPrint('❌ handleSystemMessage failed: $e\n$stackTrace');
    }
  }

  Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    const query = r'''
      query GetGroupMembers($groupId: String!, $page: Float!, $limit: Float!) {
        getGroupMembers(groupId: $groupId, page: $page, limit: $limit) {
          data { items { userId username deviceIds } }
        }
      }
    ''';

    final result = await gql.runQuery(query, variables: {'groupId': groupId, 'page': 1.0, 'limit': 100.0});
    if (result.hasException) {
      debugPrint('getGroupMembers exception: ${result.exception}');
      return [];
    }

    final items = result.data?['getGroupMembers']?['data']?['items'] as List<dynamic>?;
    if (items == null) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  void resetDistributionState() {
    _distributedGroups.clear();
  }
}
