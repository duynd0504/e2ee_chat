import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

class GraphQLService {
  final GraphQLClient client;
  String? _endpointUrl;
  Map<String, String>? _defaultHeaders;

  GraphQLService(this.client) {
    _extractEndpointInfo();
  }

  void _extractEndpointInfo() {
    try {
      final link = client.link;
      if (link is HttpLink) {
        _endpointUrl = link.uri.toString();
        final headers = link.defaultHeaders;
        if (headers.isNotEmpty) {
          _defaultHeaders = <String, String>{};
          headers.forEach((key, value) {
            _defaultHeaders![key] = value.toString();
          });
        }
      } else {
        _endpointUrl = 'http://139.162.33.89:3002/graphql';
      }
    } catch (e) {
      _endpointUrl = 'http://139.162.33.89:3002/graphql';
    }
  }

  void _logCurlRequest(
    String operation,
    String document,
    Map<String, dynamic>? variables,
  ) {
    if (!kDebugMode) return;

    final url = _endpointUrl ?? 'http://139.162.33.89:3002/graphql';
    final cleanDocument = document.replaceAll(RegExp(r'\s+'), ' ').trim();

    final requestBody = {
      'query': cleanDocument,
      if (variables != null && variables.isNotEmpty) 'variables': variables,
    };

    final bodyJson = const JsonEncoder.withIndent('  ').convert(requestBody);
    final escapedBody = bodyJson.replaceAll("'", "'\\''");

    final curlHeaders = <String>[
      "-H 'Content-Type: application/json'",
    ];

    if (_defaultHeaders != null) {
      _defaultHeaders!.forEach((key, value) {
        curlHeaders.add("-H '$key: $value'");
      });
    }

    final curlCommand = "curl -X POST '$url' \\\n"
        "${curlHeaders.join(' \\\n')} \\\n"
        "-d '$escapedBody'";

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint('📤 GraphQL $operation CURL Request:');
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint(curlCommand);
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }

  /// Query helper
  Future<Map<String, dynamic>> query(
    String document, {
    Map<String, dynamic>? variables,
  }) async {
    _logCurlRequest('QUERY', document, variables);

    final options = QueryOptions(
      document: gql(document),
      variables: variables ?? {},
      fetchPolicy: FetchPolicy.networkOnly,
    );

    final result = await client.query(options);

    if (result.hasException) {
      throw Exception('GraphQL Query Error: ${result.exception}');
    }

    return result.data ?? {};
  }

  /// Mutation helper
  Future<Map<String, dynamic>> mutate(
    String document, {
    Map<String, dynamic>? variables,
  }) async {
    _logCurlRequest('MUTATION', document, variables);

    final options = MutationOptions(
      document: gql(document),
      variables: variables ?? {},
    );

    final result = await client.mutate(options);

    if (result.hasException) {
      throw Exception('GraphQL Mutation Error: ${result.exception}');
    }

    return result.data ?? {};
  }

  /// Run query and return QueryResult (allows checking hasException and data)
  Future<QueryResult> runQuery(
    String document, {
    Map<String, dynamic>? variables,
  }) async {
    _logCurlRequest('QUERY', document, variables);

    final options = QueryOptions(
      document: gql(document),
      variables: variables ?? {},
      fetchPolicy: FetchPolicy.networkOnly,
    );

    return await client.query(options);
  }
}
