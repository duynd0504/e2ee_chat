import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:uuid/uuid.dart';

import 'services/app_service.dart';
import 'services/graphql_service.dart';
import 'services/signal_client.dart';
import 'ui/group_list_screen.dart';
import 'services/auth_queries.dart';
const String loginEndpoint = 'http://139.162.33.89:3001/graphql';
const String graphQLEndpoint = 'http://139.162.33.89:3002/graphql';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for GraphQL cache
  await initHiveForFlutter();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E2EE Chat Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const E2EEChatRoot(),
    );
  }
}

class E2EEChatRoot extends StatefulWidget {
  const E2EEChatRoot({super.key});

  @override
  State<E2EEChatRoot> createState() => _E2EEChatRootState();
}

class _E2EEChatRootState extends State<E2EEChatRoot> {
  String? _userId;
  String? _deviceId;
  String? _authToken;
  AppServices? _services;
  bool _initializing = false;

  // Controllers để giữ giá trị
  late TextEditingController accountController;
  late TextEditingController passwordController;
  late TextEditingController deviceController;

  @override
  void initState() {
    super.initState();
    // Debug: Pre-fill with test account
    accountController = TextEditingController(text: 'rottoummutuwa-8519@yopmail.com');
    passwordController = TextEditingController(text: 'Test77@@');
    deviceController = TextEditingController(text: _deviceId ?? const Uuid().v4());
  }

  @override
  void dispose() {
    accountController.dispose();
    passwordController.dispose();
    deviceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _services == null
        ? _buildLogin()
        : GroupListScreen(services: _services!);
  }

  Widget _buildLogin() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login to E2EE Chat'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            Icon(
              Icons.lock_outline,
              size: 80,
              color: Colors.blue[700],
            ),
            const SizedBox(height: 16),
            const Text(
              'Secure Messaging',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'End-to-end encrypted with Signal Protocol',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 40),
            const Text(
              'Account (email/phone):',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: accountController,
              decoration: InputDecoration(
                hintText: 'Enter your account',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Password:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Enter your password',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.lock),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Device ID:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: deviceController,
              decoration: InputDecoration(
                hintText: 'Unique device identifier',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.devices),
              ),
            ),
            const SizedBox(height: 32),
            if (_initializing)
              const Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Initializing secure connection...'),
                  ],
                ),
              ),
            if (!_initializing)
              ElevatedButton(
                onPressed: _handleLogin,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Login and Continue',
                  style: TextStyle(fontSize: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogin() async {
    final account = accountController.text.trim();
    final password = passwordController.text.trim();
    final deviceId = deviceController.text.trim();

    if (account.isEmpty || password.isEmpty) {
      _showError('Please enter account and password');
      return;
    }

    if (deviceId.isEmpty) {
      _showError('Please enter device ID');
      return;
    }

    setState(() => _initializing = true);

    try {
      final httpLink = HttpLink(loginEndpoint);   // DÙNG PORT 3001 CHO LOGIN
      final loginClient = GraphQLClient(
        link: httpLink,
        cache: GraphQLCache(store: InMemoryStore()),
      );

      final result = await loginClient.mutate(
        MutationOptions(
          document: gql(loginMutation),
          variables: {
            'input': {
              'account': account,
              'password': password,
            }
          },
        ),
      );

      if (result.hasException) {
        throw Exception(result.exception.toString());
      }

      final data = result.data?['login'];
      if (data == null || data['data'] == null) {
        throw Exception('Login failed: ${data?['message'] ?? 'No data returned'}');
      }

      final accessToken = data['data']['accessToken'] as String;
      final userId = data['data']['user']['id'] as String;

      // 2. Tạo authenticated client
      final authedHttpLink = HttpLink(
        graphQLEndpoint,   // DÙNG PORT 3002 CHO GRAPHQL AUTHED
        defaultHeaders: {
          'Authorization': 'Bearer $accessToken',
        },
      );

      final authedClient = GraphQLClient(
        link: authedHttpLink,
        cache: GraphQLCache(store: InMemoryStore()),
      );

      final gqlService = GraphQLService(authedClient);

      // 3. Initialize Signal Protocol
      final signalClient = SignalClient(
        gql: gqlService,
        myUserId: userId,
        myDeviceId: deviceId,
      );

      await signalClient.initialize();

      // 4. Save services and navigate
      setState(() {
        _userId = userId;
        _authToken = accessToken;
        _deviceId = deviceId;
        _services = AppServices(
          gql: gqlService,
          signalClient: signalClient,
          myUserId: userId,
          myDeviceId: deviceId,
        );
      });
    } catch (e) {
      _showError('Login failed: $e');
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
      }
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}