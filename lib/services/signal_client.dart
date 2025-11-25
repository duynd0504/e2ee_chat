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

  SignalClient({
    required this.gql,
    required this.myUserId,
    required this.myDeviceId,
  });

  Future<void> initialize() async {
    await _installLocalSignalState();

    // TEMPORARY: Comment out key registration until we find the correct mutation
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
    // Lấy signed prekey đầu tiên
    final signedPreKeyRecord = await _signedPreKeyStore.loadSignedPreKey(0);

    // Serialize các key thành bytes
    final identityKeyBytes =
        _identityKeyPair.getPublicKey().serialize().toList();
    final signedPreKeyBytes =
        signedPreKeyRecord.getKeyPair().publicKey.serialize().toList();
    final signedPreKeySigBytes = signedPreKeyRecord.signature;

    // Tạo danh sách one-time prekeys đúng schema
    final oneTimePreKeys = <Map<String, dynamic>>[];
    for (var id = 0; id < 50; id++) {
      final preKey = await _preKeyStore.loadPreKey(id);
      oneTimePreKeys.add({
        'uid': id, // bắt buộc phải là 'id'
        'publicKey': base64Encode(preKey
            .getKeyPair()
            .publicKey
            .serialize()
            .toList()), // bắt buộc phải là 'publicKey'
      });
    }

    // Mutation GraphQL
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

    // Gửi mutation đến backend
    await gql.mutate(
      mutation,
      variables: {
        'input': {
          'identityKey': base64Encode(identityKeyBytes),
          'signedPreKey': base64Encode(signedPreKeyBytes),
          'signedPreKeySig': base64Encode(signedPreKeySigBytes),
          'oneTimePreKeys': oneTimePreKeys,
          'deviceId': myDeviceId,
        }
      },
    );
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

    ///
    ///đoạn này đang bị map sai cần chờ be
    ///
    final preKeyPublicBytes = base64Decode('1');

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

  // Future<Uint8List> encryptGroupPlaintext({
  //   required String groupId,
  //   required String plaintext,
  // }) async {
  //   final senderKeyName = _groupSenderKeyNameFor(groupId, myUserId, myDeviceId);
  //   final builder = signal.GroupSessionBuilder(_senderKeyStore);
  //   final distribution = await builder.create(senderKeyName);
  //   final distributionBytes = distribution.serialize();

  //   // Gửi SKDM cho tất cả members khác
  //   const query = r'''
  //   query GetGroupMembers($groupId: String!, $page: Float!, $limit: Float!) {
  //     getGroupMembers(groupId: $groupId, page: $page, limit: $limit) {
  //       data {
  //         items {
  //           userId
  //           username
  //           deviceIds
  //         }
  //       }
  //     }
  //   }
  //   ''';

  //   final result = await gql.query(query, variables: {
  //     'groupId': groupId,
  //     'page': 1.0,
  //     'limit': 100.0,
  //   });

  //   final members = result['getGroupMembers']?['data']?['items'] as List<dynamic>? ?? [];

  //   for (final m in members) {
  //     final userId = m['userId'] as String;
  //     if (userId == myUserId) continue;

  //     final deviceIds = (m['deviceIds'] as List<dynamic>? ?? []).cast<String>().toList();
  //     for (final devId in deviceIds) {
  //       final envelope = AppMessageEnvelope(
  //         type: 'skdm',
  //         body: {
  //           'groupId': groupId,
  //           'senderUserId': myUserId,
  //           'senderDeviceId': myDeviceId,
  //           'distributionMessageBase64': base64Encode(distributionBytes),
  //         },
  //       );

  //       final ct = await encryptToDevice(
  //         remoteUserId: userId,
  //         remoteDeviceId: devId,
  //         envelope: envelope,
  //       );

  //       await gql.sendEncryptedMessage(
  //         groupId: null,
  //         recipientId: userId,
  //         deviceId: myDeviceId,
  //         ciphertextBase64: ct,
  //         contentType: 'E2EE_SYSTEM',
  //       );
  //     }
  //   }

  //   // Encrypt group message
  //   final cipher = await _ensureGroupCipherForSender(groupId, myUserId, myDeviceId);
  //   final ciphertext = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
  //   return ciphertext;
  // }

  Future<Uint8List> encryptGroupPlaintext({
    required String groupId,
    required String plaintext,
  }) async {
    final senderKeyName = _groupSenderKeyNameFor(groupId, myUserId, myDeviceId);
    final builder = signal.GroupSessionBuilder(_senderKeyStore);
    final distribution =
        await builder.create(senderKeyName); // new sender key if needed
    final distributionBytes = distribution.serialize();

    // For every other device in the group we send an SKDM system message.
    final members = await getGroupMembers(groupId);
    for (final m in members) {
      final userId = m['userId'] as String;
      if (userId == myUserId) continue;
      final deviceIds =
          (m['deviceIds'] as List<dynamic>? ?? []).cast<String>().toList();
      for (final devId in deviceIds) {
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
      }
    }

    // Now encrypt actual group plaintext
    final cipher =
        await _ensureGroupCipherForSender(groupId, myUserId, myDeviceId);
    final ciphertext =
        await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
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
      final cipher =
          await _ensureGroupCipherForSender(groupId, senderId, senderDeviceId);
      final ciphertextBytes =
          Uint8List.fromList(base64Decode(ciphertextBase64));
      final plaintextBytes = await cipher.decrypt(ciphertextBytes);
      return utf8.decode(plaintextBytes);
    } catch (e) {
      debugPrint('Group decrypt failed: $e');
      return null;
    }
  }

  Future<void> handleSystemMessage({
    required String fromUserId,
    required String fromDeviceId,
    required String ciphertextBase64,
  }) async {
    try {
      final envelope = await decryptFromDevice(
        remoteUserId: fromUserId,
        remoteDeviceId: fromDeviceId,
        ciphertextBase64: ciphertextBase64,
      );

      if (envelope.type == 'skdm') {
        final groupId = envelope.body['groupId'] as String;
        final senderUserId = envelope.body['senderUserId'] as String;
        final senderDeviceId = envelope.body['senderDeviceId'] as String;
        final distributionBase64 =
            envelope.body['distributionMessageBase64'] as String;
        final distributionBytes = base64Decode(distributionBase64);

        final senderKeyName =
            _groupSenderKeyNameFor(groupId, senderUserId, senderDeviceId);
        final wrapper =
            signal.SenderKeyDistributionMessageWrapper.fromSerialized(
                distributionBytes);
        final builder = signal.GroupSessionBuilder(_senderKeyStore);
        await builder.process(senderKeyName, wrapper);
      }
    } catch (e) {
      debugPrint('handleSystemMessage failed: $e');
    }
  }
}
