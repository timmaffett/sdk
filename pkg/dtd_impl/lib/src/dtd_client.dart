// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:dart_service_protocol_shared/dart_service_protocol_shared.dart';
import 'package:dtd/dtd.dart' show CoreDtdServiceConstants, DtdParameters;
import 'package:sse/server/sse_handler.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:dtd/dtd.dart' show RpcErrorCodes, RegisteredServicesResponse;

import 'constants.dart';
import 'dart_tooling_daemon.dart';

/// Represents a client that is connected to a DTD service.
///
/// [DTDClient] is used only by the server to handle the remote DTD client and
/// by the client itself/on the client side.
class DTDClient extends Client {
  final StreamChannel<String> connection;
  late json_rpc.Peer _clientPeer;
  final DartToolingDaemon dtd;
  late final Future<void> _done;

  Future<void> get done => _done;

  DTDClient.fromWebSocket(
    DartToolingDaemon dtd,
    WebSocketChannel ws,
  ) : this._(
          dtd,
          ws.cast<String>(),
        );

  DTDClient.fromSSEConnection(
    DartToolingDaemon dtd,
    SseConnection sse,
  ) : this._(
          dtd,
          sse,
        );

  DTDClient._(
    this.dtd,
    this.connection,
  ) {
    _clientPeer = json_rpc.Peer(
      connection,
      strictProtocolChecks: false,
    );
    _registerJsonRpcMethods();
    _done = listen();
  }

  @override
  Future<void> close() => _clientPeer.close();

  @override
  Future<dynamic> sendRequest({
    required String method,
    dynamic parameters,
  }) async {
    if (_clientPeer.isClosed) {
      return;
    }

    return await _clientPeer.sendRequest(method, parameters.value);
  }

  @override
  void streamNotify(String stream, Object data) {
    _clientPeer.sendNotification(
      CoreDtdServiceConstants.streamNotify,
      data,
    );
  }

  /// Start receiving JSON RPC requests from the client.
  ///
  /// Returned future completes when the peer is closed.
  Future<void> listen() => _clientPeer.listen().then(
        (_) => dtd.streamManager.onClientDisconnect(this),
      );

  /// The set of RPC methods registered by DTD itself.
  ///
  /// This will be a combination of first party DTD methods and methods
  /// registered by internal services.
  final _dtdRpcMethods = <String>{};

  /// Registers handlers for the Dart Tooling Daemon JSON RPC method endpoints.
  void _registerJsonRpcMethods() {
    _registerDtdMethod(CoreDtdServiceConstants.streamListen, _streamListen);
    _registerDtdMethod(CoreDtdServiceConstants.streamCancel, _streamCancel);
    _registerDtdMethod(CoreDtdServiceConstants.postEvent, _postEvent);
    _registerDtdMethod(
      CoreDtdServiceConstants.registerService,
      _registerService,
    );
    _registerDtdMethod(
      CoreDtdServiceConstants.getRegisteredServices,
      _getRegisteredServices,
    );

    // Handle service extension invocations.
    _clientPeer.registerFallback(_fallback);
  }

  /// jrpc endpoint for listening to a stream.
  ///
  /// Parameters:
  /// 'streamId': the stream to be cancelled.
  Future<Map<String, Object?>> _streamListen(
    json_rpc.Parameters parameters,
  ) async {
    final streamId = parameters[DtdParameters.streamId].asString;
    try {
      await dtd.streamManager.streamListen(
        this,
        streamId,
      );
    } on StreamAlreadyListeningException catch (_) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kStreamAlreadySubscribed,
        data: {
          'details': "The stream '$streamId' is already subscribed",
        },
      );
    }

    // If the remote client was subscribing to the services stream, send all
    // of the existing streams.
    if (streamId == CoreDtdServiceConstants.servicesStreamId) {
      for (final client in dtd.clientManager.clients) {
        for (final service in client.services.values) {
          for (final method in service.methods.values) {
            _streamNotifyHelper(
              CoreDtdServiceConstants.servicesStreamId,
              CoreDtdServiceConstants.serviceRegisteredKind,
              _buildServiceRegisteredData(
                service: service.name,
                method: method.name,
                capabilities: method.capabilities,
              ),
            );
          }
        }
      }

      for (final method in _dtdRpcMethods) {
        // If the DTD service method has the form 'service.method', split up the
        // two values. Otherwise, leave the service null and use the entire name
        // as the method.
        String? serviceName;
        String methodName;
        final parts = method.split('.');
        if (parts.length == 2) {
          serviceName = parts[0];
        }
        methodName = parts.last;

        _streamNotifyHelper(
          CoreDtdServiceConstants.servicesStreamId,
          CoreDtdServiceConstants.serviceRegisteredKind,
          _buildServiceRegisteredData(
            service: serviceName,
            method: methodName,
          ),
        );
      }
    }

    return RPCResponses.success;
  }

  /// A helper to emit an event ([eventKind] to [stream]).
  void _streamNotifyHelper(
    String stream,
    String eventKind,
    Map<String, Object?>? eventData,
  ) {
    streamNotify(stream, {
      DtdParameters.streamId: stream,
      DtdParameters.eventKind: eventKind,
      DtdParameters.eventData: eventData,
      DtdParameters.timestamp: DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// jrpc endpoint for stopping listening to a stream.
  ///
  /// Parameters:
  /// 'streamId': the stream that the client would like to stop listening to.
  Future<Map<String, Object?>> _streamCancel(
    json_rpc.Parameters parameters,
  ) async {
    final streamId = parameters[DtdParameters.streamId].asString;

    if (!dtd.streamManager.isSubscribed(this, streamId)) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kStreamNotSubscribed,
        data: {
          'details': "Client is not listening to '$streamId'",
        },
      );
    }
    await dtd.streamManager.streamCancel(this, streamId);
    return RPCResponses.success;
  }

  /// jrpc endpoint for posting an event to a stream.
  ///
  /// Parameters:
  /// 'eventKind': the kind of event being sent.
  /// 'eventData': the data being sent over the stream.
  /// 'streamId: the stream that is being posted to.
  Future<Map<String, Object?>> _postEvent(
    json_rpc.Parameters parameters,
  ) async {
    final eventKind = parameters[DtdParameters.eventKind].asString;
    final eventData =
        parameters[DtdParameters.eventData].asMap.cast<String, Object?>();
    final stream = parameters[DtdParameters.streamId].asString;
    dtd.streamManager.postEventHelper(stream, eventKind, eventData);
    return RPCResponses.success;
  }

  bool _isValidServiceName(String serviceName) {
    return !serviceName.contains('.');
  }

  /// jrpc endpoint for registering a service to the tooling daemon.
  ///
  /// Parameters:
  /// 'service': the name of the service that is being registered to.
  /// 'method': the name of the method that is being registered on the service.
  Map<String, Object?> _registerService(json_rpc.Parameters parameters) {
    final serviceName = parameters[DtdParameters.service].asString;
    final methodName = parameters[DtdParameters.method].asString;
    final capabilities = parameters[DtdParameters.capabilities].exists
        ? parameters[DtdParameters.capabilities].asMap.cast<String, Object?>()
        : null;

    if (!_isValidServiceName(serviceName)) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kServiceNameInvalid,
        data: {
          'details': "'$serviceName' is not a valid service name. "
              "Services may not include dots in their names.",
        },
      );
    }

    if (dtd.internalServices.containsKey(serviceName)) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kServiceAlreadyRegistered,
        data: {
          'details':
              "Service '$serviceName' is already registered as a DTD internal service.",
        },
      );
    }

    final existingServiceOwnerClient =
        dtd.clientManager.findClientThatOwnsService(serviceName);
    if (existingServiceOwnerClient != null &&
        existingServiceOwnerClient != this) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kServiceAlreadyRegistered,
        data: {
          'details':
              "Service '$serviceName' is already registered by another client. "
                  "Only 1 client at a time may register methods to a service.",
        },
      );
    }

    if (services[serviceName]?.methods.containsKey(methodName) ?? false) {
      throw RpcErrorCodes.buildRpcException(
        RpcErrorCodes.kServiceMethodAlreadyRegistered,
        data: {
          'details':
              "$methodName has already been registered for the $serviceName service by this client.",
        },
      );
    }

    final methodInfo = ClientServiceMethodInfo(methodName, capabilities);
    services
        .putIfAbsent(serviceName, () => ClientServiceInfo(serviceName))
        .methods[methodName] = methodInfo;

    // Send an event to inform other clients that this service method is
    // available.
    dtd.streamManager.postEventHelper(
      CoreDtdServiceConstants.servicesStreamId,
      CoreDtdServiceConstants.serviceRegisteredKind,
      _buildServiceRegisteredData(
        service: serviceName,
        method: methodName,
        capabilities: capabilities,
      ),
    );
    return RPCResponses.success;
  }

  /// Returns a structured response with all the currently registered services
  /// available on this DTD instance.
  Map<String, Object?> _getRegisteredServices() {
    final clientServices =
        dtd.clientManager.clients.map((client) => client.services);
    final combinedClientServices = {
      // This will not create collisions because [_registerService] ensures
      // the uniqueness of service methods across clients.
      for (final servicesForClient in clientServices) ...servicesForClient,
    };
    return RegisteredServicesResponse(
      dtdServices: _dtdRpcMethods.toList(),
      clientServices: combinedClientServices.values.toList(),
    ).toJson();
  }

  /// Cleans up when this client is disconnecting, before it is removed from the
  /// client manager.
  void onClientDisconnect() {
    for (final service in services.values) {
      for (final method in service.methods.values) {
        // Notify other clients about this service going away.
        dtd.streamManager.postEventHelper(
          CoreDtdServiceConstants.servicesStreamId,
          CoreDtdServiceConstants.serviceUnregisteredKind,
          _buildServiceUnregisteredData(service.name, method.name),
        );
      }
    }
  }

  /// Builds a structured object describing a service method that is being
  /// registered on DTD.
  ///
  /// [service] may be null if this service method is a first party service
  /// method registered by DTD or by an internal service.
  Map<String, Object?> _buildServiceRegisteredData({
    required String? service,
    required String method,
    Map<String, Object?>? capabilities,
  }) {
    return {
      if (service != null) DtdParameters.service: service,
      DtdParameters.method: method,
      if (capabilities != null) DtdParameters.capabilities: capabilities,
    };
  }

  Map<String, Object?> _buildServiceUnregisteredData(
    String service,
    String method,
  ) {
    return {
      DtdParameters.service: service,
      DtdParameters.method: method,
    };
  }

  /// jrpc fallback handler.
  ///
  /// Handles all service method calls that will be forwarded to the respective
  /// client which registered that service method.
  Future<Object?> _fallback(json_rpc.Parameters parameters) async {
    // Lookup the client associated with the service extension's namespace.
    // If the client exists and that client has registered the specified
    // method, forward the request to that client.
    final combinedName = parameters.method;
    final dotIndex = combinedName.indexOf('.');
    if (dotIndex == -1) {
      // All service methods must have a dot in the name.
      throw json_rpc.RpcException(
        RpcErrorCodes.kMethodNotFound,
        'Unknown service method: $combinedName',
      );
    }

    final serviceName = combinedName.substring(0, dotIndex);
    final methodName = combinedName.substring(dotIndex + 1);

    final client = dtd.clientManager.findClientThatHandlesServiceMethod(
      serviceName,
      methodName,
    );
    if (client == null) {
      throw json_rpc.RpcException(
        RpcErrorCodes.kMethodNotFound,
        'Unknown service method: $combinedName',
      );
    }

    return await client.sendRequest(
      method: combinedName,
      parameters: parameters,
    );
  }

  /// Registers a service method to the Dart Tooling Daemon using the name
  /// "[service].[method]".
  ///
  /// This method is a helper for registering service methods that are available
  /// when the Dart Tooling Daemon is initialized. To trigger a service method
  /// registered with this helper see the
  /// [dtd_protocol.md#servicemethod](https://github.com/dart-lang/sdk/blob/main/pkg/dtd_impl/dtd_protocol.md#servicemethod)
  /// documentation.
  ///
  /// When a client of the Dart Tooling Daemon calls [service].[method], then
  /// [callback] will be run with the parameters of that call.
  void registerServiceMethod(
    String service,
    String method,
    void Function(json_rpc.Parameters parameters) callback,
  ) {
    final combinedName = '$service.$method';
    _registerDtdMethod(combinedName, callback);
  }

  /// A helper method for registering a service method on DTD and adding the
  /// service method to the [_dtdRpcMethods] set.
  void _registerDtdMethod(String method, Function callback) {
    _dtdRpcMethods.add(method);
    _clientPeer.registerMethod(method, callback);
  }
}
