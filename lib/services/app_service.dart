
import 'graphql_service.dart';
import 'signal_client.dart';

class AppServices {
  final GraphQLService gql;
  final SignalClient signalClient;
  final String myUserId;
  final String myDeviceId;

  AppServices({
    required this.gql,
    required this.signalClient,
    required this.myUserId,
    required this.myDeviceId,
  });
}