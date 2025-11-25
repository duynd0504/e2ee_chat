import 'package:graphql_flutter/graphql_flutter.dart';

class GraphQLService {
  final GraphQLClient client;

  GraphQLService(this.client);

  /// Query helper
  Future<Map<String, dynamic>> query(
      String document, {
        Map<String, dynamic>? variables,
      }) async {
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
}