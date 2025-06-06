// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:devtools_shared/devtools_extensions_io.dart';
import 'package:devtools_shared/devtools_shared.dart' show DtdInfo;
import 'package:dtd/dtd.dart' hide RpcErrorCodes;
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_proxy/shelf_proxy.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sse/server/sse_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../dds.dart';
import 'binary_compatible_peer.dart';
import 'client.dart';
import 'client_manager.dart';
import 'constants.dart';
import 'dap_handler.dart';
import 'devtools/dtd.dart';
import 'devtools/handler.dart';
import 'expression_evaluator.dart';
import 'isolate_manager.dart';
import 'package_uri_converter.dart';
import 'rpc_error_codes.dart';
import 'stream_manager.dart';

@visibleForTesting
typedef PeerBuilder = Future<json_rpc.Peer> Function(WebSocketChannel, dynamic);

@visibleForTesting
typedef WebSocketBuilder = WebSocketChannel Function(Uri);

@visibleForTesting
PeerBuilder peerBuilder = _defaultPeerBuilder;

@visibleForTesting
WebSocketBuilder webSocketBuilder = _defaultWebSocketBuilder;

Future<json_rpc.Peer> _defaultPeerBuilder(
    WebSocketChannel ws, dynamic streamManager) async {
  return BinaryCompatiblePeer(ws, streamManager);
}

WebSocketChannel _defaultWebSocketBuilder(Uri uri) {
  return WebSocketChannel.connect(uri.replace(scheme: 'ws'));
}

class DartDevelopmentServiceImpl implements DartDevelopmentService {
  DartDevelopmentServiceImpl(
    this._remoteVmServiceUri,
    this._uri,
    this._authCodesEnabled,
    this._cachedUserTags,
    this._ipv6,
    this._devToolsConfiguration,
    this.shouldLogRequests,
    this._enableServicePortFallback,
    this.uriConverter,
  ) {
    _clientManager = ClientManager(this);
    _expressionEvaluator = ExpressionEvaluator(this);
    _isolateManager = IsolateManager(this);
    _streamManager = StreamManager(this);
    _packageUriConverter = PackageUriConverter(this);
    _dapHandler = DapHandler(this);
    _authCode = _authCodesEnabled ? _makeAuthToken() : '';
  }

  Future<void> startService() async {
    DartDevelopmentServiceException? error;
    // TODO(bkonyi): throw if we've already shutdown.
    // Establish the connection to the VM service.
    _vmServiceSocket = webSocketBuilder(remoteVmServiceWsUri);
    try {
      await _vmServiceSocket.ready;
    } on WebSocketChannelException catch (e) {
      throw DartDevelopmentServiceException.connectionIssue(e.toString());
    }

    vmServiceClient = await peerBuilder(_vmServiceSocket, _streamManager);
    // Setup the JSON RPC client with the VM service.
    unawaited(
      vmServiceClient.listen().then(
        (_) {
          if (_initializationComplete) {
            shutdown();
          } else {
            // If we fail to connect to the service or the connection is
            // terminated while we're starting up, we'll need to cleanup later
            // once DDS has finished initializing to make sure all ports are
            // closed before throwing the exception.
            error = DartDevelopmentServiceException.failedToStart();
          }
        },
        onError: (e, st) {
          if (_initializationComplete) {
            shutdown();
          } else {
            // If we encounter an error while we're starting up, we'll need to
            // cleanup later once DDS has finished initializing to make sure
            // all ports are closed before throwing the exception.
            error = DartDevelopmentServiceException.connectionIssue(
              e.toString(),
            );
          }
        },
      ),
    );
    // Run in an error Zone to ensure that asynchronous exceptions encountered
    // during request handling are handled, as exceptions thrown during request
    // handling shouldn't take down the entire service.
    await runZonedGuarded(
      () async {
        try {
          // Setup stream event handling.
          await streamManager.listen();

          // Populate initial isolate state.
          await _isolateManager.initialize();

          // Once we have a connection to the VM service, we're ready to spawn
          // the intermediary.
          await _startDDSServer();
          _initializationComplete = true;
        } on StateError {
          // Handle json-rpc state errors.
          //
          // It's possible that ordering of events on the event queue can
          // result in the cleanup code above being called after this function
          // has returned,
          // resulting in an invalid DDS instance being released into the wild.
          //
          // If initialization hasn't completed and the error hasn't already
          // been set, set it now.
          error ??= DartDevelopmentServiceException.failedToStart();
        } on DartDevelopmentServiceException catch (e) {
          // Forward any DartDevelopmentServiceExceptions thrown when starting
          // the server.
          error = e;
        }
      },
      (error, stack) {
        if (shouldLogRequests) {
          print('Asynchronous error: $error\n$stack');
        }
      },
    );

    // Check if we encountered any errors during startup, cleanup, and throw.
    if (error != null) {
      await shutdown();
      throw error!;
    }
  }

  Future<void> _startDDSServer() async {
    // The host on which the user requested DDS to be started, or [null] if the
    // user did not specify a host. We replace 'localhost' with either
    // [InternetAddress.loopbackIPv4] or [InternetAddress.loopbackIPv6]
    // depending on the value of [_ipv6].
    final hostArg = uri?.host == 'localhost'
        ? (_ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4)
            .host
        : uri?.host;
    // The host on which DDS will be started.
    final host = hostArg ??
        (_ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4)
            .host;
    var port = uri?.port ?? 0;
    var pipeline = const Pipeline();
    if (shouldLogRequests) {
      pipeline = pipeline.addMiddleware(
        logRequests(
          logger: (String message, bool isError) {
            print('Log: $message');
          },
        ),
      );
    }
    pipeline = pipeline.addMiddleware(_authCodeMiddleware);
    pipeline = pipeline.addMiddleware(
        createMiddleware(errorHandler: (Object error, StackTrace st) {
      return Response.internalServerError(body: error.toString());
    }));

    if (_devToolsConfiguration?.enable ?? false) {
      // If we are enabling DevTools in DDS, then we also need to start the Dart
      // tooling daemon, since this is usually the responsibility of the
      // DevTools server when a DTD uri is not already passed to the DevTools
      // server on start.
      _hostedDartToolingDaemon = await startDtd(
        machineMode: false,
        printDtdUri: false,
      );
    }

    final handler = pipeline.addHandler(_handlers().handler);
    // Start the DDS server.
    late String errorMessage;
    Future<HttpServer?> startServer() async {
      try {
        return await io.serve(handler, host, port);
      } on SocketException catch (e) {
        if (_enableServicePortFallback && port != 0) {
          // Try again, this time with a random port.
          port = 0;
          return await startServer();
        }
        errorMessage = e.message;
        if (e.osError != null) {
          errorMessage += ' (${e.osError!.message})';
        }
        errorMessage += ': ${e.address?.host}:${e.port}';
        return null;
      }
    }

    final tmpServer = await startServer();

    if (tmpServer == null) {
      throw DartDevelopmentServiceException.connectionIssue(errorMessage);
    }
    _server = tmpServer;

    final tmpUri = Uri(
      scheme: 'http',
      host: _server.address.host,
      port: _server.port,
      path: '$authCode/',
    );

    // Notify the VM service that this client is DDS and that it should close
    // and refuse connections from other clients. DDS is now acting in place of
    // the VM service.
    try {
      await vmServiceClient.sendRequest('_yieldControlToDDS', {
        'uri': tmpUri.toString(),
      });
    } on json_rpc.RpcException catch (e) {
      await _server.close(force: true);
      String message = e.toString();
      Object? data = e.data;
      Uri? ddsUri;
      if (data != null) {
        message += ' data: $data';

        // Read the existing URI (if provided) so clients can connect to it
        // directly.
        if (data is Map<String, Object?>) {
          final uri = data['ddsUri'];
          if (uri is String) {
            ddsUri = Uri.tryParse(uri);
          }
        }
      }
      // _yieldControlToDDS fails if DDS is not the only VM service client.
      throw DartDevelopmentServiceException.existingDdsInstance(
        message,
        ddsUri: ddsUri,
      );
    }

    _uri = tmpUri;

    // If DDS is hosting the Dart Tooling Daemon, it needs to register the VM
    // Service URI on DTD.
    final hostedDtd = _hostedDartToolingDaemon;
    if (hostedDtd != null && wsUri != null) {
      final dtdClient = await DartToolingDaemon.connect(hostedDtd.localUri);
      await dtdClient.registerVmService(
        uri: wsUri!.toString(),
        secret: hostedDtd.secret!,
      );
      // Immediately close this client after registering the VM service. The
      // VM service will be automatically unregistered from DTD when the VM
      // service shuts down. For this case, DTD will also be shut down as part
      // of shutting down DDS & the VM Service so we do not need to worry about
      // unregistering the VM service manually.
      await dtdClient.close();
    }
  }

  /// Stop accepting requests after gracefully handling existing requests.
  @override
  Future<void> shutdown() async {
    if (_done.isCompleted || _shuttingDown || !_initializationComplete) {
      // Already shutdown or we were interrupted during initialization.
      return;
    }
    _shuttingDown = true;
    // Don't accept any more HTTP requests.
    await _server.close();

    // Close connections to clients.
    await clientManager.shutdown();

    // Close connection to VM service.
    await _vmServiceSocket.sink.close();

    _done.complete();
  }

  /// Generates a base64 authentication code that must be passed as the first
  /// part of the request path. Used to prevent random connections from clients
  /// watching the common service ports.
  static String _makeAuthToken() {
    final kTokenByteSize = 8;
    final bytes = Uint8List(kTokenByteSize);
    final random = Random.secure();
    for (int i = 0; i < kTokenByteSize; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes);
  }

  /// Shelf middleware to verify authentication tokens before processing a
  /// request.
  ///
  /// If authentication codes are enabled, a 403 response is returned if the
  /// authentication code is not the first element of the request's path.
  /// Otherwise, the request is forwarded to the first handler.
  Handler _authCodeMiddleware(Handler innerHandler) => (Request request) {
        if (_authCodesEnabled) {
          final forbidden =
              Response.forbidden('missing or invalid authentication code');
          final pathSegments = request.url.pathSegments;
          if (pathSegments.isEmpty) {
            return forbidden;
          }
          final authToken = pathSegments[0];
          if (authToken != authCode) {
            return forbidden;
          }
          // Creates a new request with the authentication code stripped from
          // the request URI. This method doesn't behave as you might expect.
          // Calling request.change(path: authToken) has the effect of changing
          // the request's handler path from '/' to '/$authToken/' while also
          // changing the request's url from '$authToken/restofpath/' to
          // 'restofpath/'. The handler path is only used by shelf, so this
          // operation has the effect of stripping the authentication code from
          // the request.
          request = request.change(path: authToken);
        }
        return innerHandler(request);
      };

  // Attempt to upgrade HTTP requests to a websocket before processing them as
  // standard HTTP requests. The websocket handler will fail quickly if the
  // request doesn't appear to be a websocket upgrade request.
  Cascade _handlers() {
    return Cascade()
        .add(_webSocketHandler())
        .add(_sseHandler())
        .add(_httpHandler());
  }

  // Note: the WebSocketChannel type below is needed for compatibility with
  // package:shelf_web_socket v2.
  Handler _webSocketHandler() => webSocketHandler((WebSocketChannel ws, _) {
        final client = DartDevelopmentServiceClient.fromWebSocket(
          this,
          ws,
          vmServiceClient,
        );
        clientManager.addClient(client);
      });

  Handler _sseHandler() {
    final handler = SseHandler(
      authCodesEnabled
          ? Uri.parse('/$authCode/$kSseHandlerPath')
          : Uri.parse('/$kSseHandlerPath'),
      keepAlive: sseKeepAlive,
    );

    handler.connections.rest.listen((sseConnection) {
      final client = DartDevelopmentServiceClient.fromSSEConnection(
        this,
        sseConnection,
        vmServiceClient,
      );
      clientManager.addClient(client);
    });

    return handler.handler;
  }

  Handler _httpHandler() {
    final notFoundHandler = proxyHandler(remoteVmServiceUri);

    if (_devToolsConfiguration?.enable ?? false) {
      final existingDevToolsAddress =
          _devToolsConfiguration!.devToolsServerAddress;
      if (existingDevToolsAddress == null) {
        // If DDS is serving DevTools, install the DevTools handlers and
        // forward any unhandled HTTP requests to the VM service.
        final String buildDir =
            _devToolsConfiguration.customBuildDirectoryPath.toFilePath();
        return defaultHandler(
          dds: this,
          buildDir: buildDir,
          notFoundHandler: notFoundHandler,
          dtd: _hostedDartToolingDaemon,
          devtoolsExtensionsManager: ExtensionsManager(),
        ) as FutureOr<Response> Function(Request);
      }
      // Otherwise, set the DevTools URI to point to the externally hosted
      // DevTools instance.
      _devToolsUri = existingDevToolsAddress;
    }

    // Otherwise, DevTools may be served externally, or not at all.
    return (Request request) {
      final pathSegments = request.url.pathSegments;
      if (pathSegments.isEmpty || pathSegments.first != 'devtools') {
        // Not a DevTools request, forward to the VM service.
        return notFoundHandler(request);
      } else {
        if (_devToolsUri == null) {
          // DevTools is not being served externally.
          return Response.notFound(
            'No DevTools instance is registered with the Dart Development Service (DDS).',
          );
        }
        // Redirect to the external DevTools server.
        return Response.seeOther(
          _devToolsUri!.replace(
            queryParameters: request.requestedUri.queryParameters,
          ),
        );
      }
    };
  }

  List<String> _cleanupPathSegments(Uri uri) {
    final pathSegments = <String>[];
    if (uri.pathSegments.isNotEmpty) {
      pathSegments.addAll(uri.pathSegments.where(
        // Strip out the empty string that appears at the end of path segments.
        // Empty string elements will result in an extra '/' being added to the
        // URI.
        (s) => s.isNotEmpty,
      ));
    }
    return pathSegments;
  }

  Uri? _toWebSocket(Uri? uri) {
    if (uri == null) {
      return null;
    }
    final pathSegments = _cleanupPathSegments(uri);
    pathSegments.add('ws');
    return uri.replace(scheme: 'ws', pathSegments: pathSegments);
  }

  Uri? _toSse(Uri? uri) {
    if (uri == null) {
      return null;
    }
    final pathSegments = _cleanupPathSegments(uri);
    pathSegments.add(kSseHandlerPath);
    return uri.replace(scheme: 'sse', pathSegments: pathSegments);
  }

  @visibleForTesting
  Uri? toDevTools(Uri? uri) {
    return Uri(
      scheme: 'http',
      host: uri!.host,
      port: uri.port,
      pathSegments: [
        ...uri.pathSegments.where(
          (e) => e.isNotEmpty,
        ),
        'devtools',
        // Includes a trailing slash by adding an empty string to the end of the
        // path segments list.
        '',
      ],
      query: 'uri=$wsUri',
    );
  }

  String? getNamespace(DartDevelopmentServiceClient client) =>
      clientManager.clients.keyOf(client);

  @override
  bool get authCodesEnabled => _authCodesEnabled;
  final bool _authCodesEnabled;
  String? get authCode => _authCode;
  String? _authCode;

  final bool _enableServicePortFallback;
  final bool shouldLogRequests;

  @override
  Uri get remoteVmServiceUri => _remoteVmServiceUri;

  @override
  Uri get remoteVmServiceWsUri => _toWebSocket(_remoteVmServiceUri)!;
  final Uri _remoteVmServiceUri;

  @override
  Uri? get uri => _uri;
  Uri? _uri;

  @override
  Uri? get sseUri => _toSse(_uri);

  @override
  Uri? get wsUri => _toWebSocket(_uri);

  @override
  Uri? get devToolsUri {
    _devToolsUri ??=
        _devToolsConfiguration?.enable ?? false ? toDevTools(_uri) : null;
    return _devToolsUri;
  }

  Uri? _devToolsUri;

  @override
  void setExternalDevToolsUri(Uri uri) {
    if ((_devToolsConfiguration?.enable ?? false) &&
        _devToolsConfiguration?.devToolsServerAddress != null) {
      throw StateError('A hosted DevTools instance is already being served.');
    }
    _devToolsUri = uri;
  }

  @override
  DtdInfo? get hostedDartToolingDaemon => _hostedDartToolingDaemon;

  DtdInfo? _hostedDartToolingDaemon;

  final bool _ipv6;

  @override
  bool get isRunning => _uri != null;

  final DevToolsConfiguration? _devToolsConfiguration;

  @override
  List<String> get cachedUserTags => UnmodifiableListView(_cachedUserTags);
  final List<String> _cachedUserTags;

  @override
  Future<void> get done => _done.future;
  final Completer _done = Completer<void>();
  bool _initializationComplete = false;
  bool _shuttingDown = false;

  UriConverter? uriConverter;
  PackageUriConverter get packageUriConverter => _packageUriConverter;
  late PackageUriConverter _packageUriConverter;

  DapHandler get dapHandler => _dapHandler;
  late DapHandler _dapHandler;

  ClientManager get clientManager => _clientManager;
  late ClientManager _clientManager;

  ExpressionEvaluator get expressionEvaluator => _expressionEvaluator;
  late ExpressionEvaluator _expressionEvaluator;

  IsolateManager get isolateManager => _isolateManager;
  late IsolateManager _isolateManager;

  StreamManager get streamManager => _streamManager;
  late StreamManager _streamManager;

  static const kSseHandlerPath = '\$debugHandler';

  late json_rpc.Peer vmServiceClient;
  late WebSocketChannel _vmServiceSocket;
  late HttpServer _server;
}

extension PeerExtension on json_rpc.Peer {
  Future<dynamic> sendRequestAndIgnoreMethodNotFound(
    String method, [
    dynamic parameters,
  ]) async {
    try {
      await sendRequest(method, parameters);
    } on json_rpc.RpcException catch (e) {
      if (e.code != RpcErrorCodes.kMethodNotFound) {
        rethrow;
      }
    }
  }
}
