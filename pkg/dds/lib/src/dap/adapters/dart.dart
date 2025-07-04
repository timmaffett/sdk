// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dap/dap.dart';
import 'package:dds_service_extensions/dds_service_extensions.dart';
import 'package:json_rpc_2/error_code.dart' as json_rpc_errors;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart' as vm;

import '../../../dds.dart';
import '../base_debug_adapter.dart';
import '../isolate_manager.dart';
import '../logging.dart';
import '../progress_reporter.dart';
import '../protocol_converter.dart';
import '../protocol_stream.dart';
import '../utils.dart';
import '../variables.dart';
import 'mixins.dart';

/// The mime type to send with source responses to the client.
///
/// This is used so if the source name does not end with ".dart" the client can
/// still tell which language to use (for syntax highlighting, etc.).
///
/// https://github.com/microsoft/vscode/issues/8182#issuecomment-231151640
const dartMimeType = 'text/x-dart';

/// Maximum number of toString()s to be called when responding to variables
/// requests from the client.
///
/// Setting this too high can have a performance impact, for example if the
/// client requests 500 items in a variablesRequest for a list.
const maxToStringsPerEvaluation = 100;

/// An expression that evaluates to the exception for the current thread.
///
/// In order to support some functionality like "Copy Value" in VS Code's
/// Scopes/Variables window, each variable must have a valid "evaluateName" (an
/// expression that evaluates to it). Since we show exceptions in there we use
/// this magic value as an expression that maps to it.
///
/// This is not intended to be used by the user directly, although if they
/// evaluate it as an expression and the current thread has an exception, it
/// will work.
const threadExceptionExpression = r'$_threadException';

/// Typedef for handlers of VM Service stream events.
typedef _StreamEventHandler<T> = FutureOr<void> Function(T data);

/// A null result passed to `sendResponse` functions when there is no result.
///
/// Because the signature of `sendResponse` is generic, an argument must be
/// provided even when the generic type is `void`. This value is used to make
/// it clearer in calling code that the result is unused.
const _noResult = null;

/// Pattern for extracting useful error messages from an evaluation exception.
final _evalErrorMessagePattern = RegExp('Error: (.*)');

/// Pattern for extracting useful error messages from an unhandled exception.
final _exceptionMessagePattern = RegExp('Unhandled exception:\n(.*)');

/// Pattern for a trailing semicolon.
final _trailingSemicolonPattern = RegExp(r';$');

/// An implementation of [AttachRequestArguments] that includes all fields used
/// by the Dart CLI and test debug adapters.
///
/// This class represents the data passed from the client editor to the debug
/// adapter in attachRequest, which is a request to start debugging an
/// application.
///
/// Specialized adapters (such as Flutter) have their own versions of this
/// class.
class DartAttachRequestArguments extends DartCommonLaunchAttachRequestArguments
    implements AttachRequestArguments {
  /// The VM Service URI to attach to.
  ///
  /// Either this or [vmServiceInfoFile] must be supplied.
  final String? vmServiceUri;

  /// The VM Service info file to extract the VM Service URI from to attach to.
  ///
  /// Either this or [vmServiceUri] must be supplied.
  final String? vmServiceInfoFile;

  /// A reader for protocol arguments that throws detailed exceptions if
  /// arguments aren't of the correct type.
  static final arg = DebugAdapterArgumentReader('attach');

  DartAttachRequestArguments({
    this.vmServiceUri,
    this.vmServiceInfoFile,
    super.restart,
    super.name,
    super.cwd,
    super.additionalProjectPaths,
    super.debugSdkLibraries,
    super.debugExternalPackageLibraries,
    super.showGettersInDebugViews,
    super.evaluateGettersInDebugViews,
    super.evaluateToStringInDebugViews,
    super.sendLogsToClient,
    super.sendCustomProgressEvents = null,
    super.allowAnsiColorOutput,
  }) : super(
          // env is not supported for Dart attach because we don't spawn a process.
          env: null,
        );

  DartAttachRequestArguments.fromMap(super.obj)
      : vmServiceUri = arg.read<String?>(obj, 'vmServiceUri'),
        vmServiceInfoFile = arg.read<String?>(obj, 'vmServiceInfoFile'),
        super.fromMap();

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        if (vmServiceUri != null) 'vmServiceUri': vmServiceUri,
        if (vmServiceInfoFile != null) 'vmServiceInfoFile': vmServiceInfoFile,
      };

  static DartAttachRequestArguments fromJson(Map<String, Object?> obj) =>
      DartAttachRequestArguments.fromMap(obj);
}

/// A common base for [DartLaunchRequestArguments] and
/// [DartAttachRequestArguments] for fields that are common to both.
class DartCommonLaunchAttachRequestArguments extends RequestArguments {
  /// A reader for protocol arguments that throws detailed exceptions if
  /// arguments aren't of the correct type.
  static final arg = DebugAdapterArgumentReader('launch/attach');

  /// Optional data from the previous, restarted session.
  /// The data is sent as the 'restart' attribute of the 'terminated' event.
  /// The client should leave the data intact.
  final Object? restart;

  final String? name;
  final String? cwd;

  /// Environment variables to pass to the launched process.
  final Map<String, String>? env;

  /// Paths that should be considered the users local code.
  ///
  /// These paths will generally be all of the open folders in the users editor
  /// and are used to determine whether a library is "external" or not to
  /// support debugging "just my code" where SDK/Pub package code will be marked
  /// as not-debuggable.
  final List<String>? additionalProjectPaths;

  /// Whether SDK libraries should be marked as debuggable.
  ///
  /// Treated as `true` if null. If `false`, "step in" will not step into SDK
  /// libraries.
  final bool? debugSdkLibraries;

  /// Whether to send custom progress events for long-running operations.
  ///
  /// If `false` or `null`, will send standard DAP progress notifications.
  final bool? sendCustomProgressEvents;

  /// Whether external package libraries should be marked as debuggable.
  ///
  /// Treated as `true` if null. If `false`, "step in" will not step into
  /// libraries in packages that are not either the local package or a path
  /// dependency. This allows users to debug "just their code" and treat Pub
  /// packages as block boxes.
  final bool? debugExternalPackageLibraries;

  /// Whether to show getters in debug views like hovers and the variables
  /// list.
  final bool? showGettersInDebugViews;

  /// Whether to eagerly evaluate getters in debug views like hovers and the
  /// variables list.
  ///
  /// If `true`, getters will be invoked automatically and included inline with
  /// other  fields (implies [showGettersInDebugViews]).
  ///
  /// If `false`, getters will not be included unless [showGettersInDebugViews]
  /// is `true`, in which case they will be wrapped and only evaluated when the
  /// user expands them.
  final bool? evaluateGettersInDebugViews;

  /// Whether to call toString() on objects in debug views like hovers and the
  /// variables list.
  ///
  /// Invoking toString() has a performance cost and may introduce side-effects,
  /// although users may expected this functionality. null is treated like false
  /// although clients may have their own defaults (for example Dart-Code sends
  /// true by default at the time of writing).
  final bool? evaluateToStringInDebugViews;

  /// Whether to send debug logging to clients in a custom `dart.log` event. This
  /// is used both by the out-of-process tests to ensure the logs contain enough
  /// information to track down issues, but also by Dart-Code to capture VM
  /// service traffic in a unified log file.
  final bool? sendLogsToClient;

  /// Whether to allow ansi color codes in OutputEvents. These may be used to
  /// highlight user code in stack traces.
  ///
  /// Generally, we should only output codes that work equally with both dark
  /// and light themes because we don't know what the clients colour scheme
  /// looks like.
  final bool? allowAnsiColorOutput;

  DartCommonLaunchAttachRequestArguments({
    required this.restart,
    required this.name,
    required this.cwd,
    required this.env,
    required this.additionalProjectPaths,
    required this.debugSdkLibraries,
    required this.debugExternalPackageLibraries,
    // TODO(dantup): Make this 'required' after Flutter subclasses have been
    //  updated.
    this.showGettersInDebugViews,
    // TODO(dantup): Make this 'required' after Flutter subclasses have been
    //  updated.
    this.allowAnsiColorOutput,
    required this.evaluateGettersInDebugViews,
    required this.evaluateToStringInDebugViews,
    required this.sendLogsToClient,
    this.sendCustomProgressEvents = false,
  });

  DartCommonLaunchAttachRequestArguments.fromMap(Map<String, Object?> obj)
      : restart = arg.read<Object?>(obj, 'restart'),
        name = arg.read<String?>(obj, 'name'),
        cwd = arg.read<String?>(obj, 'cwd'),
        env = arg.readOptionalMap<String, String>(obj, 'env'),
        additionalProjectPaths =
            arg.readOptionalList<String>(obj, 'additionalProjectPaths'),
        debugSdkLibraries = arg.read<bool?>(obj, 'debugSdkLibraries'),
        debugExternalPackageLibraries =
            arg.read<bool?>(obj, 'debugExternalPackageLibraries'),
        showGettersInDebugViews =
            arg.read<bool?>(obj, 'showGettersInDebugViews'),
        evaluateGettersInDebugViews =
            arg.read<bool?>(obj, 'evaluateGettersInDebugViews'),
        evaluateToStringInDebugViews =
            arg.read<bool?>(obj, 'evaluateToStringInDebugViews'),
        sendLogsToClient = arg.read<bool?>(obj, 'sendLogsToClient'),
        sendCustomProgressEvents =
            arg.read<bool?>(obj, 'sendCustomProgressEvents'),
        allowAnsiColorOutput = arg.read<bool?>(obj, 'allowAnsiColorOutput');

  Map<String, Object?> toJson() => {
        if (restart != null) 'restart': restart,
        if (name != null) 'name': name,
        if (cwd != null) 'cwd': cwd,
        if (env != null) 'env': env,
        if (additionalProjectPaths != null)
          'additionalProjectPaths': additionalProjectPaths,
        if (debugSdkLibraries != null) 'debugSdkLibraries': debugSdkLibraries,
        if (debugExternalPackageLibraries != null)
          'debugExternalPackageLibraries': debugExternalPackageLibraries,
        if (showGettersInDebugViews != null)
          'showGettersInDebugViews': showGettersInDebugViews,
        if (evaluateGettersInDebugViews != null)
          'evaluateGettersInDebugViews': evaluateGettersInDebugViews,
        if (evaluateToStringInDebugViews != null)
          'evaluateToStringInDebugViews': evaluateToStringInDebugViews,
        if (sendLogsToClient != null) 'sendLogsToClient': sendLogsToClient,
        if (sendCustomProgressEvents != null)
          'sendCustomProgressEvents': sendCustomProgressEvents,
        if (allowAnsiColorOutput != null)
          'allowAnsiColorOutput': allowAnsiColorOutput,
      };
}

/// A base DAP Debug Adapter implementation for running and debugging Dart-based
/// applications (including Flutter and Tests).
///
/// This class implements all functionality common to Dart, Flutter and Test
/// debug sessions, including things like breakpoints and expression eval.
///
/// Sub-classes should handle the launching/attaching of apps and any custom
/// behaviour (such as Flutter's Hot Reload). This is generally done by overriding
/// `fooImpl` methods that are called during the handling of a `fooRequest` from
/// the client.
///
/// A DebugAdapter instance will be created per application being debugged (in
/// multi-session mode, one DebugAdapter corresponds to one incoming TCP
/// connection, though a client may make multiple of these connections if it
/// wants to debug multiple scripts concurrently, such as with a compound launch
/// configuration in VS Code).
///
/// The lifecycle is described in the DAP spec here:
/// https://microsoft.github.io/debug-adapter-protocol/overview#initialization
///
/// In summary:
///
/// The client will create a connection to the server (which will create an
///   instance of the debug adapter) and send an `initializeRequest` message,
///   wait for the server to return a response and then an initializedEvent
/// The client will then send breakpoints and exception config
///   (`setBreakpointsRequest`, `setExceptionBreakpoints`) and then a
///   `configurationDoneRequest`.
/// Finally, the client will send a `launchRequest` or `attachRequest` to start
///   running/attaching to the script.
///
/// The client will continue to send requests during the debug session that may
/// be in response to user actions (for example changing breakpoints or typing
/// an expression into an evaluation console) or to events sent by the server
/// (for example when the server sends a `StoppedEvent` it may cause the client
/// to then send a `stackTraceRequest` or `scopesRequest` to get variables).
abstract class DartDebugAdapter<TL extends LaunchRequestArguments,
        TA extends AttachRequestArguments> extends BaseDebugAdapter<TL, TA>
    with FileUtils {
  late final DartCommonLaunchAttachRequestArguments args;
  final _debuggerInitializedCompleter = Completer<void>();
  final _configurationDoneCompleter = Completer<void>();

  /// Manages VM Isolates and their events, including fanning out any requests
  /// to set breakpoints etc. from the client to all Isolates.
  late final IsolateManager isolateManager;

  /// A helper that handlers converting to/from DAP and VM Service types.
  late ProtocolConverter _converter;

  /// All active VM Service subscriptions.
  ///
  /// TODO(dantup): This may be changed to use StreamManager as part of using
  /// DDS in this process.
  final _subscriptions = <StreamSubscription<vm.Event>>[];

  /// The VM service of the app being debugged.
  ///
  /// `null` if the session is running in noDebug mode of the connection has not
  /// yet been made.
  vm.VmService? vmService;

  /// The root of the Dart SDK containing the VM running the debug adapter.
  late final String dartSdkRoot;

  /// Mappings of file paths to 'org-dartlang-sdk:///' URIs used for translating
  /// URIs/paths between the DAP client and the VM.
  ///
  /// Keys are the base file paths and the values are the base URIs. Neither
  /// value should contain trailing slashes.
  final orgDartlangSdkMappings = <String, Uri>{};

  /// The [DartInitializeRequestArguments] provided by the client in the
  /// `initialize` request.
  ///
  /// `null` if the `initialize` request has not yet been made.
  DartInitializeRequestArguments? _initializeArgs;

  /// Whether to use IPv6 for DAP/Debugger services.
  final bool ipv6;

  /// A logger for printing diagnostic information.
  final Logger? logger;

  /// Whether the current debug session is an attach request (as opposed to a
  /// launch request). Only set during [attachRequest] so will always be `false`
  /// prior to that.
  bool isAttach = false;

  /// A list of evaluateNames for InstanceRef IDs.
  ///
  /// When providing variables for fields/getters or items in maps/arrays, we
  /// need to provide an expression to the client that evaluates to that
  /// variable so that functionality like "Add to Watch" or "Copy Value" can
  /// work. For example, if a user expands a list named `myList` then the 1st
  /// [Variable] returned should have an evaluateName of `myList[0]`. The `foo`
  /// getter of that object would then have an evaluateName of `myList[0].foo`.
  ///
  /// Since those expressions aren't round-tripped as child variables are
  /// requested we build them up as we send variables out, so we can append to
  /// them when returning elements/map entries/fields/getters.
  final _evaluateNamesForInstanceRefIds = <String, String>{};

  /// A list of all possible project paths that should be considered the users
  /// own code.
  ///
  /// This is made up of the folder containing the 'program' being executed, the
  /// 'cwd' and any 'additionalProjectPaths' from the launch arguments.
  late final List<String> projectPaths = [
    args.cwd,
    if (args is DartLaunchRequestArguments)
      path.dirname((args as DartLaunchRequestArguments).program),
    ...?args.additionalProjectPaths,
  ].nonNulls.map(normalizePath).toList();

  /// Whether we have already sent the [TerminatedEvent] to the client.
  ///
  /// This is tracked so that we don't send multiple if there are multiple
  /// events that suggest the session ended (such as a process exiting and the
  /// VM Service closing).
  bool _hasSentTerminatedEvent = false;

  /// Whether verbose internal logs (such as VM Service traffic) should be sent
  /// to the client in `dart.log` events.
  bool get sendLogsToClient => _sendLogsToClient;
  var _sendLogsToClient = false;

  /// Whether or not the DAP is terminating.
  ///
  /// When set to `true`, some requests that return "Service Disappeared" errors
  /// will be caught and dropped as these are expected if the process is
  /// terminating.
  ///
  /// This flag may be set by incoming requests from the client
  /// (terminateRequest/disconnectRequest) or when a process terminates, or the
  /// VM Service disconnects.
  bool isTerminating = false;

  /// Whether or not the current termination is happening because the user
  /// chose to detach from an attached process.
  ///
  /// This affects the message a user sees when the adapter shuts down ('exited'
  /// vs 'detached').
  bool isDetaching = false;

  /// Whether this adapter set the --pause-isolates-on-start flag, specifying
  /// that isolates should pause on starting.
  ///
  /// Normally this will be true, but it may be set to false if the user
  /// also manually passed the --pause-isolates-on-start flag.
  bool pauseIsolatesOnStartSetByDap = true;

  /// Whether this adapter set the --pause-isolates-on-exit flag, specifying
  /// that isolates should pause on exiting.
  ///
  /// Normally this will be true, but it may be set to false if the user
  /// also manually passed the --pause-isolates-on-exit flag.
  bool pauseIsolatesOnExitSetByDap = true;

  /// A [Future] that completes when the last queued OutputEvent has been sent.
  ///
  /// Calls to [SendOutput] will reserve their place in this queue and
  /// subsequent calls will chain their own sends onto this (and replace it) to
  /// preserve order.
  Future? _lastOutputEvent;

  /// Capabilities of the DDS instance available in the connected VM Service.
  ///
  /// If the VM Service is not yet connected, does not have a DDS instance, or
  /// the version has not been fetched, all capabilities will be false.
  _DdsCapabilities _ddsCapabilities = _DdsCapabilities.empty;

  /// The ID of the custom VM Service stream that emits events intended for
  /// tools/IDEs.
  static final toolEventStreamId = 'ToolEvent';

  /// Removes any breakpoints or pause behaviour and resumes any paused
  /// isolates.
  ///
  /// This is useful when detaching from a process that was attached to, where
  /// the user would not expect the script to continue to pause on breakpoints
  /// the had set while attached.
  Future<void> preventBreakingAndResume() async {
    await _withErrorHandling(() async {
      // Remove anything that may cause us to pause again.
      await Future.wait([
        isolateManager.clearAllBreakpoints(),
        isolateManager.setExceptionPauseMode('None'),
      ]);
      // Once those have completed, it's safe to resume anything paused.
      await isolateManager.resumeAll();
    });
  }

  DartDebugAdapter(
    ByteStreamServerChannel channel, {
    this.ipv6 = false,
    @Deprecated('DAP never spawns DDS now, this `enableDds` does nothing')
    bool enableDds = true,
    @Deprecated('DAP never spawns DDS now, this `enableAuthCodes` does nothing')
    bool enableAuthCodes = true,
    this.logger,
    Function? onError,
  }) : super(channel, onError: onError) {
    channel.closed.then((_) => shutdown());

    final vmPath = Platform.resolvedExecutable;
    dartSdkRoot = path.dirname(path.dirname(vmPath));
    orgDartlangSdkMappings[dartSdkRoot] = Uri.parse('org-dartlang-sdk:///sdk');

    isolateManager = IsolateManager(this);
    _converter = ProtocolConverter(this);
  }

  /// Completes when the debugger initialization has completed. Used to delay
  /// processing isolate events while initialization is still running to avoid
  /// race conditions (for example if an isolate unpauses before we have
  /// processed its initial paused state).
  Future<void> get debuggerInitialized => _debuggerInitializedCompleter.future;

  bool get evaluateToStringInDebugViews =>
      args.evaluateToStringInDebugViews ?? false;

  /// The [InitializeRequestArguments] provided by the client in the
  /// `initialize` request.
  ///
  /// `null` if the `initialize` request has not yet been made.
  DartInitializeRequestArguments? get initializeArgs => _initializeArgs;

  /// Whether or not this adapter can handle the restartRequest.
  ///
  /// If false, the editor will just terminate the debug session and start a new
  /// one when the user asks to restart. If true, the adapter must implement
  /// the [restartRequest] method and handle its own restart (for example the
  /// Flutter adapter will perform a Hot Restart).
  bool get supportsRestartRequest => false;

  /// Whether the VM Service closing should be used as a signal to terminate the
  /// debug session.
  ///
  /// It is generally better to handle termination when the debuggee terminates
  /// instead, since this ensures the stdout/stderr streams have been drained.
  /// However, that's not possible in some cases (for example 'runInTerminal'
  /// or attaching), so this is the only signal we have.
  ///
  /// It is up to the subclass DA to provide this value correctly based on
  /// whether it will call [handleSessionTerminate] itself upon process
  /// termination.
  bool get terminateOnVmServiceClose;

  /// Whether to subscribe to stdout/stderr through the VM Service.
  ///
  /// This is set by [attachRequest] so that any output will still be captured and
  /// sent to the client without needing to access the process.
  ///
  /// [launchRequest] reads the stdout/stderr streams directly and does not need
  /// to have them sent via the VM Service.
  var _subscribeToOutputStreams = false;

  /// Overridden by sub-classes to handle when the client sends an
  /// `attachRequest` (a request to attach to a running app).
  ///
  /// Sub-classes can use the [args] field to access the arguments provided
  /// to this request.
  Future<void> attachImpl();

  /// [attachRequest] is called by the client when it wants us to attach to
  /// an existing app. This will only be called once (and only one of this or
  /// launchRequest will be called).
  @override
  Future<void> attachRequest(
    Request request,
    TA args,
    void Function() sendResponse,
  ) async {
    try {
      this.args = args as DartCommonLaunchAttachRequestArguments;
      isAttach = true;
      _subscribeToOutputStreams = true;

      // Common setup.
      await _prepareForLaunchOrAttach(null);

      // Delegate to the sub-class to attach to the process.
      await attachImpl();

      sendResponse();
    } on DebugAdapterException catch (e) {
      // Any errors that are thrown as part of an AttachRequest should be shown
      // to the user.
      throw DebugAdapterException(e.message, showToUser: true);
    }
  }

  /// Builds an evaluateName given a parent VM InstanceRef ID and a suffix.
  ///
  /// If [parentInstanceRefId] is `null`, or we have no evaluateName for it,
  /// will return null.
  String? buildEvaluateName(
    String suffix, {
    required String? parentInstanceRefId,
  }) {
    final parentEvaluateName =
        _evaluateNamesForInstanceRefIds[parentInstanceRefId];
    return combineEvaluateName(parentEvaluateName, suffix);
  }

  /// Builds an evaluateName given a prefix and a suffix.
  ///
  /// If [prefix] is null, will return be null.
  String? combineEvaluateName(String? prefix, String suffix) {
    return prefix != null ? '$prefix$suffix' : null;
  }

  /// configurationDone is called by the client when it has finished sending
  /// any initial configuration (such as breakpoints and exception pause
  /// settings).
  ///
  /// We delay processing `launchRequest`/`attachRequest` until this request has
  /// been sent to ensure we're not still getting breakpoints (which are sent
  /// per-file) while we're launching and initializing over the VM Service.
  @override
  Future<void> configurationDoneRequest(
    Request request,
    ConfigurationDoneArguments? args,
    void Function() sendResponse,
  ) async {
    _configurationDoneCompleter.complete();
    sendResponse();
  }

  /// Connects to the VM Service at [uri] and initializes debugging.
  ///
  /// This method will be called by sub-classes when they are ready to start
  /// a debug session and may provide a URI given by the user (in the case
  /// of attach) or from something like a vm-service-info file or Flutter
  /// app.debugPort message.
  ///
  /// The URI protocol will be changed to ws/wss but otherwise not normalized.
  /// The caller should handle any other normalisation (such as adding /ws to
  /// the end if required).
  ///
  /// The implementation for this method is run in try/catch and any
  /// exceptions during initialization will result in the debug adapter
  /// reporting an error to the user and shutting down.
  Future<void> connectDebugger(Uri uri) async {
    try {
      await _connectDebuggerImpl(uri);
    } catch (error, stack) {
      final message = 'Failed to connect/initialize debugger for $uri:\n'
          '$error\n$stack';
      logger?.call(message);
      sendConsoleOutput(message);
      shutdown();
    }
  }

  /// Connects to the VM Service at [uri] and initializes debugging.
  ///
  /// This is the implementation for [connectDebugger] which is executed in a
  /// try/catch.
  Future<void> _connectDebuggerImpl(Uri uri) async {
    uri = vmServiceUriToWebSocket(uri);

    logger?.call('Connecting to debugger at $uri');
    sendConsoleOutput('Connecting to VM Service at $uri');
    final vmService = await _vmServiceConnectUri(uri.toString());
    logger?.call('Connected to debugger at $uri!');
    sendConsoleOutput('Connected to the VM Service.');

    // Fetch DDS capabilities.
    final supportedProtocols = await vmService.getSupportedProtocols();
    final ddsProtocol = supportedProtocols.protocols
        ?.firstWhereOrNull((protocol) => protocol.protocolName == 'DDS');
    if (ddsProtocol != null) {
      _ddsCapabilities = _DdsCapabilities(
        major: ddsProtocol.major ?? 0,
        minor: ddsProtocol.minor ?? 0,
      );
    }
    final supportsCustomStreams = _ddsCapabilities.supportsCustomStreams;

    // Send debugger URI to the client.
    sendDebuggerUris(uri);

    this.vmService = vmService;

    unawaited(vmService.onDone.then((_) => _handleVmServiceClosed()));

    // Handlers must be wrapped to handle Service Disappeared errors if async
    // code tries to call the VM Service after termination begins.
    final wrap = _wrapHandlerWithErrorHandling;
    _subscriptions.addAll([
      vmService.onIsolateEvent.listen(wrap(handleIsolateEvent)),
      vmService.onDebugEvent.listen(wrap(handleDebugEvent)),
      vmService.onLoggingEvent.listen(wrap(handleLoggingEvent)),
      vmService.onExtensionEvent.listen(wrap(handleExtensionEvent)),
      vmService.onServiceEvent.listen(wrap(handleServiceEvent)),
      if (supportsCustomStreams)
        vmService.onEvent(toolEventStreamId).listen(wrap(handleToolEvent)),
      if (_subscribeToOutputStreams) ...[
        vmService.onStdoutEvent.listen(wrap(_handleStdoutEvent)),
        vmService.onStderrEvent.listen(wrap(_handleStderrEvent)),
      ],
    ]);
    await Future.wait([
      vmService.streamListen(vm.EventStreams.kIsolate),
      vmService.streamListen(vm.EventStreams.kDebug),
      vmService.streamListen(vm.EventStreams.kLogging),
      vmService.streamListen(vm.EventStreams.kExtension),
      vmService.streamListen(vm.EventStreams.kService),
      if (supportsCustomStreams) vmService.streamListen(toolEventStreamId),
      if (_subscribeToOutputStreams) ...[
        vmService.streamListen(vm.EventStreams.kStdout),
        vmService.streamListen(vm.EventStreams.kStderr),
      ],
    ]);

    final vmInfo = await vmService.getVM();
    logger?.call('Connected to ${vmInfo.name} on ${vmInfo.operatingSystem}');

    // Let the subclass do any existing setup once we have a connection.
    await debuggerConnected(vmInfo);

    await _configureIsolateSettings(vmService);
    await _withErrorHandling(
      () => _configureExistingIsolates(vmService, vmInfo),
    );

    _debuggerInitializedCompleter.complete();
  }

  // This is intended for subclasses to override to provide a URI converter to
  // resolve package URIs to local paths.
  UriConverter? uriConverter() {
    return null;
  }

  void sendDebuggerUris(Uri uri) {
    // Send a custom event with the VM Service URI as the editor might want to
    // know about this (for example so it can connect an embedded DevTools to
    // this app).
    sendEvent(
      RawEventBody({
        'vmServiceUri': uri.toString(),
      }),
      eventType: 'dart.debuggerUris',
    );
  }

  /// Starts reporting progress to the client for a single operation.
  ///
  /// The returned [DapProgressReporter] can be used to send updated messages
  /// and to complete progress (hiding the progress notification).
  ///
  /// Clients will use [title] as a prefix for all updates, appending [message]
  /// in the form:
  ///
  /// title: message
  ///
  /// When `update` is called, the new message will replace the previous
  /// message but the title prefix will remain.
  DapProgressReporter startProgressNotification(
    String id,
    String title, {
    String? message,
  }) {
    return DapProgressReporter.start(this, id, title, message: message);
  }

  Future<void> _configureIsolateSettings(
    vm.VmService vmService,
  ) async {
    // If this is an attach workflow, check whether pause_isolates_on_start or
    // pause_isolates_on_exit were already set, and if not set them (note: this
    // is already done as part of the launch workflow):
    if (isAttach) {
      const pauseIsolatesOnStart = 'pause_isolates_on_start';
      const pauseIsolatesOnExit = 'pause_isolates_on_exit';
      final flags = (await vmService.getFlagList()).flags ?? <vm.Flag>[];
      for (final flag in flags) {
        final flagName = flag.name;
        final isPauseIsolatesFlag =
            flagName == pauseIsolatesOnStart || flagName == pauseIsolatesOnExit;
        if (flagName == null || !isPauseIsolatesFlag) continue;

        if (flag.valueAsString == 'true') {
          if (flagName == pauseIsolatesOnStart) {
            pauseIsolatesOnStartSetByDap = false;
          }
          if (flagName == pauseIsolatesOnExit) {
            pauseIsolatesOnExitSetByDap = false;
          }
        } else {
          _setVmFlagTo(vmService, flagName: flagName, valueAsString: 'true');
        }
      }
    }

    try {
      // Make sure DDS waits for DAP to be ready to resume before forwarding
      // resume requests to the VM Service:
      await vmService.requirePermissionToResume(
        onPauseStart: true,
        onPauseExit: true,
      );

      // Specify whether DDS should wait for a user-initiated resume as well as a
      // DAP-initiated resume:
      await vmService.requireUserPermissionToResume(
        onPauseStart: !pauseIsolatesOnStartSetByDap,
        onPauseExit: !pauseIsolatesOnExitSetByDap,
      );
    } catch (e) {
      // If DDS is not enabled, calling these DDS service extensions will fail.
      // Therefore catch and log any errors.
      logger?.call('Failure configuring isolate settings: $e');
    }
  }

  Future<void> _setVmFlagTo(
    vm.VmService vmService, {
    required String flagName,
    required String valueAsString,
  }) async {
    try {
      await vmService.setFlag(flagName, valueAsString);
    } catch (e) {
      logger?.call('Failed to to set VM flag $flagName to $valueAsString: $e');
    }
  }

  /// Process any existing isolates that may have been created before the
  /// streams above were set up.
  Future<void> _configureExistingIsolates(
    vm.VmService vmService,
    vm.VM vmInfo,
  ) async {
    final existingIsolateRefs = vmInfo.isolates;
    final existingIsolates = existingIsolateRefs != null
        ? await Future.wait(existingIsolateRefs
            .map((isolateRef) => isolateRef.id)
            .nonNulls
            .map(vmService.getIsolate))
        : <vm.Isolate>[];
    await Future.wait(existingIsolates.map((isolate) async {
      // Isolates may have the "None" pauseEvent kind at startup, so infer it
      // from the runnable field.
      final pauseEventKind = isolate.runnable ?? false
          ? vm.EventKind.kIsolateRunnable
          : vm.EventKind.kIsolateStart;
      final thread =
          await isolateManager.registerIsolate(isolate, pauseEventKind);

      // If the Isolate already has a Pause event we can give it to the
      // IsolateManager to handle (if it's PausePostStart it will re-configure
      // the isolate before resuming), otherwise we can just resume it (if it's
      // runnable - otherwise we'll handle this when it becomes runnable in an
      // event later).
      if (isolate.pauseEvent?.kind?.startsWith('Pause') ?? false) {
        await isolateManager.handleEvent(
          isolate.pauseEvent!,
        );
      } else if (isolate.runnable == true) {
        await isolateManager.handleThreadStartup(thread,
            sendStoppedOnEntry: false);
      }
    }));
  }

  /// Handles the clients "continue" ("resume") request for the thread in
  /// [args.threadId].
  @override
  Future<void> continueRequest(
    Request request,
    ContinueArguments args,
    void Function(ContinueResponseBody) sendResponse,
  ) async {
    // When we resume, it's always possible that the VM will shut down (because
    // it was paused-on-exit and we just allowed it to complete and exit), so
    // we should handle shutdown errors and just accept them as successful
    // resumes.
    await _withErrorHandling(() => isolateManager.resumeThread(args.threadId));
    sendResponse(ContinueResponseBody(allThreadsContinued: false));
  }

  /// [customRequest] handles any messages that do not match standard messages
  /// in the spec.
  ///
  /// This is used to allow a client/DA to have custom methods outside of the
  /// spec. It is up to the client/DA to negotiate which custom messages are
  /// allowed.
  ///
  /// Implementations of this method must call super for any requests they are
  /// not handling. The base implementation will reject the request as unknown.
  ///
  /// Custom message starting with _ are considered internal and are liable to
  /// change without warning.
  @override
  Future<void> customRequest(
    Request request,
    RawRequestArguments? args,
    void Function(Object?) sendResponse,
  ) async {
    switch (request.command) {
      // Used by tests to validate available protocols (e.g. DDS). There may be
      // value in making this available to clients in future, but for now it's
      // internal.
      case '_getSupportedProtocols':
        final protocols = await vmService?.getSupportedProtocols();
        sendResponse(protocols?.toJson());
        break;

      // Used to toggle debug settings such as whether SDK/Packages are
      // debuggable while the session is in progress.
      case 'updateDebugOptions':
        if (args != null) {
          await _updateDebugOptions(args.args);
        }
        sendResponse(_noResult);
        break;

      // Used to enable/disable sending logs to the client. This can also be
      // enabled in launch args, but this allows selective logging to produce
      // more targeted log files (used by Dart-Code's "Capture Debugging Logs"
      // command).
      case 'updateSendLogsToClient':
        if (args != null) {
          await _updateSendLogsToClient(args.args);
        }
        sendResponse(_noResult);
        break;

      // Allows an editor to call a service/service extension that it was told
      // about via a custom 'dart.serviceRegistered' or
      // 'dart.serviceExtensionAdded' event.
      case 'callService':
        final method = args?.args['method'] as String?;
        if (method == null) {
          throw DebugAdapterException(
            'Method is required to call services/service extensions',
          );
        }
        final params = args?.args['params'] as Map<String, Object?>?;
        final response = await vmService?.callServiceExtension(
          method,
          args: params,
        );
        sendResponse(response?.json);
        break;

      // Used to reload sources for all isolates. This supports Hot Reload for
      // Dart apps. Flutter's DAP handles this command itself (and sends it
      // through the run daemon) as it needs to perform additional work to
      // rebuild widgets afterwards.
      case 'hotReload':
        await isolateManager.reloadSources();
        sendResponse(_noResult);
        break;

      // Called by VS Code extension to have us force a re-evaluation of
      // variables if settings are modified that globally change the format
      // of numbers (in the case where format specifiers are not explicitly
      // provided, such as the Variables pane).
      case '_invalidateAreas':
        // We just send the invalidate request back to the client. DAP only
        // allows these to originate in the DAP server, but we have case where
        // the client knows that these have become stale (because the user
        // changed some config) so we have to bounce it through the server.
        final areas = args?.args['areas'] as List<Object?>?;
        final stringArears = areas?.whereType<String>().toList();
        // Trigger the invalidation.
        sendEvent(InvalidatedEventBody(areas: stringArears));
        // Respond to the incoming request.
        sendResponse(_noResult);
        break;

      // Used by tests to force a GC for a given DAP threadId.
      case '_collectAllGarbage':
        final threadId = args?.args['threadId'] as int;
        final isolateId = isolateManager.getThread(threadId)?.isolate.id;
        // Trigger the GC.
        if (isolateId != null) {
          await vmService?.callMethod(
            '_collectAllGarbage',
            isolateId: isolateId,
          );
        }

        // Respond to the incoming request.
        sendResponse(_noResult);
        break;

      default:
        await super.customRequest(request, args, sendResponse);
    }
  }

  /// Overridden by sub-classes to perform any additional setup after the VM
  /// Service is connected.
  Future<void> debuggerConnected(vm.VM vmInfo);

  /// Overridden by sub-classes to handle when the client sends a
  /// `disconnectRequest` (a forceful request to shut down).
  Future<void> disconnectImpl();

  /// [disconnectRequest] is called by the client when it wants to forcefully shut
  /// us down quickly. This comes after the `terminateRequest` which is intended
  /// to allow a graceful shutdown.
  ///
  /// It's not very obvious from the names, but `terminateRequest` is sent first
  /// (a request for a graceful shutdown) and `disconnectRequest` second (a
  /// request for a forced shutdown).
  ///
  /// https://microsoft.github.io/debug-adapter-protocol/overview#debug-session-end
  @override
  Future<void> disconnectRequest(
    Request request,
    DisconnectArguments? args,
    void Function() sendResponse,
  ) async {
    isTerminating = true;

    await disconnectImpl();
    sendResponse();

    await shutdown();
  }

  /// evaluateRequest is called by the client to evaluate a string expression.
  ///
  /// This could come from the user typing into an input (for example VS Code's
  /// Debug Console), automatic refresh of a Watch window, or called as part of
  /// an operation like "Copy Value" for an item in the watch/variables window.
  ///
  /// If execution is not paused, the `frameId` will not be provided.
  @override
  Future<void> evaluateRequest(
    Request request,
    EvaluateArguments args,
    void Function(EvaluateResponseBody) sendResponse,
  ) async {
    final frameId = args.frameId;

    // If the frameId was supplied, it maps to an ID we provided from stored
    // data so we need to look up the isolate + frame index for it.
    ThreadInfo? thread;
    int? frameIndex;
    if (frameId != null) {
      final data = isolateManager.getStoredData(frameId);
      if (data != null) {
        thread = data.thread;
        frameIndex = (data.data as vm.Frame).index;
      }
    }

    // To support global evaluation, we allow passing a file:/// URI in the
    // context argument. This is always from the repl.
    final context = args.context;
    final targetScriptFileUri = context != null &&
            context.startsWith('file://') &&
            context.endsWith('.dart')
        ? Uri.tryParse(context)
        : null;

    /// Clipboard context means the user has chosen to copy the value to the
    /// clipboard, so we should strip any quotes and expand to the full string.
    final isClipboard = args.context == 'clipboard';

    /// In the repl, we should also expand the full string, but keep the quotes
    /// because that's our indicator it is a string (eg. "1" vs 1). Since
    /// we override context with script IDs for global evaluation, we must
    /// also treat presence of targetScriptFileUri as repl.
    final isRepl = args.context == 'repl' || targetScriptFileUri != null;

    final shouldSuppressQuotes = isClipboard;
    final shouldExpandTruncatedValues = isClipboard || isRepl;

    if ((thread == null || frameIndex == null) && targetScriptFileUri == null) {
      throw DebugAdapterException(
          'Evaluation is only supported when the debugger is paused '
          'unless you have a Dart file active in the editor');
    }

    // Parse the expression for trailing format specifiers.
    final expressionData = EvaluationExpression.parse(
      args.expression
          .trim()
          // Remove any trailing semicolon as the VM only evaluates expressions
          // but a user may have highlighted a whole line/statement to send for
          // evaluation.
          .replaceFirst(_trailingSemicolonPattern, ''),
    );
    final expression = expressionData.expression;
    var format = expressionData.format ??
        // If we didn't parse a format specifier, fall back to the format in
        // the arguments.
        VariableFormat.fromDapValueFormat(args.format);

    if (shouldSuppressQuotes) {
      format = format != null
          ? VariableFormat.from(format, noQuotes: true)
          : VariableFormat.noQuotes();
    }

    final exceptionReference = thread?.exceptionReference;
    // The value in the constant `frameExceptionExpression` is used as a special
    // expression that evaluates to the exception on the current thread. This
    // allows us to construct evaluateNames that evaluate to the fields down the
    // tree to support some of the debugger functionality (for example
    // "Copy Value", which re-evaluates).
    final isExceptionExpression = expression == threadExceptionExpression ||
        expression.startsWith('$threadExceptionExpression.');

    vm.Response? result;
    try {
      if (thread != null &&
          exceptionReference != null &&
          isExceptionExpression) {
        result = await _evaluateExceptionExpression(
          exceptionReference,
          expression,
          thread,
        );
      } else if (thread != null && frameIndex != null) {
        result = await vmEvaluateInFrame(
          thread,
          frameIndex,
          expression,
        );
      } else if (targetScriptFileUri != null &&
          // Since we can't currently get a thread, we assume the first thread is
          // a reasonable target for global evaluation.
          (thread = isolateManager.threads.firstOrNull) != null &&
          thread != null) {
        final library = await thread.getLibraryForFileUri(targetScriptFileUri);
        if (library == null) {
          // Wrapped in DebugAdapterException in the catch below.
          throw 'Unable to find the library for $targetScriptFileUri';
        }

        result = await vmEvaluate(thread, library.id!, expression);
      }
    } catch (e) {
      final rawMessage = '$e';

      // Error messages can be quite verbose and don't fit well into a
      // single-line watch window. For example:
      //
      //    evaluateInFrame: (113) Expression compilation error
      //    org-dartlang-debug:synthetic_debug_expression:1:5: Error: A value of type 'String' can't be assigned to a variable of type 'num'.
      //    1 + "a"
      //        ^
      //
      // So in the case of a Watch context, try to extract the useful message.
      if (args.context == 'watch') {
        throw DebugAdapterException(extractEvaluationErrorMessage(rawMessage));
      }

      throw DebugAdapterException(rawMessage);
    }

    if (result is vm.ErrorRef) {
      throw DebugAdapterException(result.message ?? '<error ref>');
    } else if (result is vm.Sentinel) {
      throw DebugAdapterException(result.valueAsString ?? '<collected>');
    } else if (result is vm.InstanceRef && thread != null) {
      final variable = await _converter.convertVmResponseToVariable(
        thread,
        result,
        name: null,
        evaluateName: expression,
        allowCallingToString:
            evaluateToStringInDebugViews || shouldExpandTruncatedValues,
        allowTruncatedValue: !shouldExpandTruncatedValues,
        format: format,
      );

      // Store the expression that gets this object as we may need it to
      // compute evaluateNames for child objects later.
      storeEvaluateName(result, expression);

      sendResponse(EvaluateResponseBody(
        // EvaluateResponse is mostly the same as a Variable response but
        // do not share a class, so copy all fields off manually (this allows
        // us to have a single implementation of building these fields for
        // an instance instead of duplicating logic here).
        result: variable.value,
        variablesReference: variable.variablesReference,
        indexedVariables: variable.indexedVariables,
        namedVariables: variable.namedVariables,
        memoryReference: variable.memoryReference,
        presentationHint: variable.presentationHint,
        type: variable.type,
        valueLocationReference: variable.valueLocationReference,
      ));
    } else {
      throw DebugAdapterException(
        'Unknown evaluation response type: ${result?.runtimeType}',
      );
    }
  }

  /// Tries to extract the useful part from an evaluation exception message.
  ///
  /// If no message could be extracted, returns the whole original error.
  String extractEvaluationErrorMessage(String rawError) {
    final match = _evalErrorMessagePattern.firstMatch(rawError);
    final shortError = match?.group(1);
    return shortError ?? rawError;
  }

  /// Tries to extract the useful part from an unhandled exception message.
  ///
  /// If no message could be extracted, returns the whole original error.
  String extractUnhandledExceptionMessage(String rawError) {
    final match = _exceptionMessagePattern.firstMatch(rawError);
    final shortError = match?.group(1);
    return shortError ?? rawError;
  }

  /// Handles a detach request, removing breakpoints and unpausing paused
  /// isolates.
  Future<void> handleDetach() async {
    isDetaching = true;
    await preventBreakingAndResume();
  }

  /// Sends a [TerminatedEvent] if one has not already been sent.
  ///
  /// Waits for any in-progress output events to complete first.
  void handleSessionTerminate([String exitSuffix = '']) async {
    await _waitForPendingOutputEvents();

    if (_hasSentTerminatedEvent) {
      return;
    }

    isTerminating = true;
    _hasSentTerminatedEvent = true;

    // Always add a leading newline since the last written text might not have
    // had one.
    final reason = isDetaching ? 'Detached' : 'Exited';
    sendConsoleOutput('\n$reason$exitSuffix.');
    sendEvent(TerminatedEventBody());
  }

  /// [initializeRequest] is the first call from the client during
  /// initialization and allows exchanging capabilities and configuration
  /// between client and server.
  ///
  /// The lifecycle is described in the DAP spec here:
  /// https://microsoft.github.io/debug-adapter-protocol/overview#initialization
  /// with a summary in this classes description.
  @override
  Future<void> initializeRequest(
    Request request,
    DartInitializeRequestArguments args,
    void Function(Capabilities) sendResponse,
  ) async {
    // Capture args so we can read capabilities later.
    _initializeArgs = args;

    // TODO(dantup): Capture/honor editor-specific settings like linesStartAt1
    sendResponse(Capabilities(
      exceptionBreakpointFilters: [
        ExceptionBreakpointsFilter(
          filter: 'All',
          label: 'All Exceptions',
          defaultValue: false,
        ),
        ExceptionBreakpointsFilter(
          filter: 'Unhandled',
          label: 'Uncaught Exceptions',
          defaultValue: true,
        ),
      ],
      supportsANSIStyling: true,
      supportsClipboardContext: true,
      supportsConditionalBreakpoints: true,
      supportsConfigurationDoneRequest: true,
      supportsDelayedStackTraceLoading: true,
      supportsEvaluateForHovers: true,
      supportsValueFormattingOptions: true,
      supportsLogPoints: true,
      supportsRestartRequest: supportsRestartRequest,
      supportsRestartFrame: true,
      supportsTerminateRequest: true,
    ));

    // This must only be sent AFTER the response!
    sendEvent(InitializedEventBody());
  }

  /// Checks whether this library is from an external package.
  ///
  /// This is used to support debugging "Just My Code" so Pub packages can be
  /// marked as not-debuggable.
  ///
  /// A library is considered local if the path is within the 'cwd' or
  /// 'additionalProjectPaths' in the launch arguments. An editor should include
  /// the paths of all open workspace folders in 'additionalProjectPaths' to
  /// support this feature correctly.
  Future<bool> isExternalPackageLibrary(ThreadInfo thread, Uri uri) async {
    if (!uri.isScheme('package')) {
      return false;
    }

    final packageFileLikeUri = await thread.resolveUriToPackageLibPath(uri);
    if (packageFileLikeUri == null) {
      return false;
    }

    return !isInUserProject(packageFileLikeUri);
  }

  /// Checks whether [uri] is inside the users project. This is used to support
  /// debugging "Just My Code" (via [isExternalPackageLibrary]) and also for
  /// stack trace highlighting, where non-user code will be faded.
  bool isInUserProject(Uri targetUri) {
    if (!isSupportedFileScheme(targetUri)) {
      return false;
    }

    // We could already be 'file', or we could be another supported file scheme
    // like dart-macro+file, but we can only call toFilePath() on a file URI
    // and we use the equivalent path to decide if this is within the workspace.
    var targetPath = targetUri.replace(scheme: 'file').toFilePath();

    // Always compare paths case-insensitively to avoid any issues where APIs
    // may have returned different casing (e.g. Windows drive letters). It's
    // almost certain a user wouldn't have a "local" package and an "external"
    // package with paths differing only be case.
    targetPath = targetPath.toLowerCase();

    return projectPaths
        .map((projectPath) => projectPath.toLowerCase())
        .any((projectPath) => path.isWithin(projectPath, targetPath));
  }

  /// Checks whether this library is from the SDK.
  bool isSdkLibrary(Uri uri) => uri.isScheme('dart');

  /// Overridden by sub-classes to handle when the client sends a
  /// `launchRequest` (a request to start running/debugging an app).
  ///
  /// Sub-classes can use the [args] field to access the arguments provided
  /// to this request.
  Future<void> launchImpl();

  /// [launchRequest] is called by the client when it wants us to start the app
  /// to be run/debug. This will only be called once (and only one of this or
  /// [attachRequest] will be called).
  @override
  Future<void> launchRequest(
    Request request,
    TL args,
    void Function() sendResponse,
  ) async {
    try {
      this.args = args as DartCommonLaunchAttachRequestArguments;
      isAttach = false;

      // Common setup.
      await _prepareForLaunchOrAttach(args.noDebug);

      // Delegate to the sub-class to launch the process.
      await launchAndRespond(sendResponse);
    } on DebugAdapterException catch (e) {
      // Any errors that are thrown as part of an AttachRequest should be shown
      // to the user.
      throw DebugAdapterException(e.message, showToUser: true);
    }
  }

  /// Overridden by sub-classes that need to control when the response is sent
  /// during the launch process.
  Future<void> launchAndRespond(void Function() sendResponse) async {
    await launchImpl();
    sendResponse();
  }

  /// Checks whether a library URI should be considered debuggable.
  ///
  /// Initial values are provided in the launch arguments, but may be updated
  /// by the `updateDebugOptions` custom request.
  Future<bool> libraryIsDebuggable(ThreadInfo thread, Uri uri) async {
    if (isSdkLibrary(uri)) {
      return isolateManager.debugSdkLibraries;
    } else if (!isolateManager.debugExternalPackageLibraries &&
        await isExternalPackageLibrary(thread, uri)) {
      return false;
    } else {
      return true;
    }
  }

  /// Handles the clients "next" ("step over") request for the thread in
  /// [args.threadId].
  @override
  Future<void> nextRequest(
    Request request,
    NextArguments args,
    void Function() sendResponse,
  ) async {
    await isolateManager.resumeThread(args.threadId, vm.StepOption.kOver);
    sendResponse();
  }

  /// Handles the clients "pause" request for the thread in [args.threadId].
  @override
  Future<void> pauseRequest(
    Request request,
    PauseArguments args,
    void Function() sendResponse,
  ) async {
    await isolateManager.pauseThread(args.threadId);
    sendResponse();
  }

  /// Handles the clients "restartFrame" request for the frame in
  /// [args.frameId].
  @override
  Future<void> restartFrameRequest(
    Request request,
    RestartFrameArguments args,
    void Function() sendResponse,
  ) async {
    final data = isolateManager.getStoredData(args.frameId);
    if (data == null) {
      // Thread/frame is no longer valid.
      return;
    }

    final thread = data.thread;
    final frame = data.data;
    final frameIndex = frame is vm.Frame ? frame.index : null;
    if (frameIndex == null) {
      return;
    }

    await isolateManager.rewindThread(thread.threadId, frameIndex: frameIndex);
    sendResponse();
  }

  /// restart is called by the client when the user invokes a restart (for
  /// example with the button on the debug toolbar).
  ///
  /// The base implementation of this method throws. It is up to a debug adapter
  /// that advertises `supportsRestartRequest` to override this method.
  @override
  Future<void> restartRequest(
    Request request,
    RestartArguments? args,
    void Function() sendResponse,
  ) async {
    throw DebugAdapterException(
      'restartRequest was called on an adapter that '
      'does not provide an implementation',
    );
  }

  /// [scopesRequest] is called by the client to request all of the variables
  /// scopes available for a given stack frame.
  @override
  Future<void> scopesRequest(
    Request request,
    ScopesArguments args,
    void Function(ScopesResponseBody) sendResponse,
  ) async {
    final storedData = isolateManager.getStoredData(args.frameId);
    final thread = storedData?.thread;
    final data = storedData?.data;
    final frameData = data is vm.Frame ? data : null;
    final scopes = <Scope>[];

    if (frameData != null && thread != null) {
      scopes.add(Scope(
        name: 'Locals',
        presentationHint: 'locals',
        variablesReference: thread.storeData(
          FrameScopeData(frameData, FrameScopeDataKind.locals),
        ),
        expensive: false,
      ));

      scopes.add(Scope(
        name: 'Globals',
        presentationHint: 'globals',
        variablesReference: thread.storeData(
          FrameScopeData(frameData, FrameScopeDataKind.globals),
        ),
        expensive: false,
      ));

      // If the top frame has an exception, add an additional section to allow
      // that to be inspected.
      final exceptionReference = thread.exceptionReference;
      if (exceptionReference != null) {
        scopes.add(Scope(
          name: 'Exceptions',
          variablesReference: exceptionReference,
          expensive: false,
        ));
      }
    }

    sendResponse(ScopesResponseBody(scopes: scopes));
  }

  /// Sends an OutputEvent with a trailing newline to the console.
  ///
  /// This method sends output directly and does not go through [sendOutput]
  /// because that method is async and queues output. Console output is for
  /// adapter-level output that does not require this and we want to ensure
  /// it's sent immediately (for example during shutdown/exit).
  void sendConsoleOutput(String? message) {
    sendEvent(OutputEventBody(output: '$message\n'));
  }

  /// Sends an OutputEvent (without a newline, since calls to this method
  /// may be using buffered data that is not split cleanly on newlines).
  ///
  /// To ensure output is sent to the client in the correct order even if
  /// processing stack frames requires async calls, this function will insert
  /// output events into a queue and only send them when previous calls have
  /// been completed.
  void sendOutput(
    String category,
    String message, {
    int? variablesReference,
    @Deprecated(
        'parseStackFrames has no effect, stack frames are always parsed')
    bool? parseStackFrames,
  }) async {
    // Reserve our place in the queue be inserting a future that we can complete
    // after we have sent the output event.
    final completer = Completer<void>();
    final previousEvent = _lastOutputEvent ?? Future.value();
    _lastOutputEvent = completer.future;

    try {
      final outputEvents = await _buildOutputEvents(
        category,
        message,
        variablesReference: variablesReference,
      );

      // Chain our sends onto the end of the previous one, and complete our Future
      // once done so that the next one can go.
      await previousEvent;
      outputEvents.forEach(sendEvent);
    } finally {
      completer.complete();
    }
  }

  /// Sends an OutputEvent for [message], prefixed with [prefix] and with [message]
  /// indented to after the prefix.
  ///
  /// Assumes the output is in full lines and will always include a terminating
  /// newline.
  void sendPrefixedOutput(String category, String prefix, String message) {
    final indentString = ' ' * prefix.length;
    final indentedMessage =
        message.trimRight().split('\n').join('\n$indentString');
    sendOutput(category, '$prefix$indentedMessage\n');
  }

  /// Handles a request from the client to set breakpoints.
  ///
  /// This method can be called at any time (before the app is launched or while
  /// the app is running) and will include the new full set of breakpoints for
  /// the file URI in [args.source.path].
  ///
  /// The VM requires breakpoints to be set per-isolate so these will be passed
  /// to [isolateManager] that will fan them out to each isolate.
  ///
  /// When new isolates are registered, it is [isolateManager]'s responsibility
  /// to ensure all breakpoints are given to them (and like at startup, this
  /// must happen before they are resumed).
  @override
  Future<void> setBreakpointsRequest(
    Request request,
    SetBreakpointsArguments args,
    void Function(SetBreakpointsResponseBody) sendResponse,
  ) async {
    final breakpoints = args.breakpoints ?? [];

    final path = args.source.path;
    final name = args.source.name;
    final uri = path != null
        ? normalizeUri(fromClientPathOrUri(path)).toString()
        : name!;

    // Use a completer to track when the response is sent, so any events related
    // to new breakpoints will not be sent to the client before the response
    // here which provides the IDs to the client.
    final completer = Completer<void>();

    // Map the provided breakpoints onto either new or existing instances of
    // [ClientBreakpoint] that we use to track the clients breakpoints
    // internally.
    final clientBreakpoints = breakpoints.map((bp) {
      return
          // First try to match an existing breakpoint so we can avoid deleting
          // and re-creating all breakpoints if a new one is added to a file.
          isolateManager.findExistingClientBreakpoint(uri, bp) ??
              ClientBreakpoint(bp, completer.future);
    }).toList();

    // Any breakpoints that are not in our new set will need to be removed from
    // the VM.
    //
    // Because multiple client breakpoints may resolve to the same VM breakpoint
    // we must exclude any that still remain in one of the kept breakpoints.
    final referencedVmBreakpoints =
        clientBreakpoints.map((bp) => bp.forThread.values).toSet();
    final breakpointsToRemove = isolateManager.clientBreakpointsByUri[uri]
        ?.toSet()
        // Remove any we're reusing.
        .difference(clientBreakpoints.toSet())
        // Remove any that map to VM breakpoints that are still referenced
        // because we'll want to keep them.
        .where((clientBreakpoint) => clientBreakpoint.forThread.values
            .none(referencedVmBreakpoints.contains));

    // Store this new set of breakpoints as the current set for this URI.
    isolateManager.recordLatestClientBreakpoints(uri, clientBreakpoints);

    // Prepare the response with the existing values before we start updating.
    final breakpointResponse = SetBreakpointsResponseBody(
      breakpoints: clientBreakpoints
          .map((bp) => Breakpoint(
              id: bp.id,
              verified: bp.verified,
              line: bp.verified ? bp.resolvedLine : null,
              column: bp.verified ? bp.resolvedColumn : null,
              message: bp.verified ? null : bp.verifiedMessage,
              reason: bp.verified ? null : bp.verifiedReason))
          .toList(),
    );

    // Update the breakpoints for all existing threads.
    await Future.wait(isolateManager.threads.map((thread) async {
      // Remove the deleted breakpoints.
      if (breakpointsToRemove != null) {
        await Future.wait(breakpointsToRemove.map((clientBreakpoint) =>
            isolateManager.removeBreakpoint(clientBreakpoint, thread)));
      }

      // Add the new breakpoints.
      await Future.wait(clientBreakpoints.map((clientBreakpoint) async {
        if (!clientBreakpoint.isKnownToVm) {
          await isolateManager.addBreakpoint(clientBreakpoint, thread, uri);
        }
      }));
    }));

    sendResponse(breakpointResponse);
    completer.complete();
  }

  /// Handles a request from the client to set exception pause modes.
  ///
  /// This method can be called at any time (before the app is launched or while
  /// the app is running).
  ///
  /// The VM requires exception modes to be set per-isolate so these will be
  /// passed to [isolateManager] that will fan them out to each isolate.
  ///
  /// When new isolates are registered, it is [isolateManager]'s responsibility
  /// to ensure the pause mode is given to them (and like at startup, this
  /// must happen before they are resumed).
  @override
  Future<void> setExceptionBreakpointsRequest(
    Request request,
    SetExceptionBreakpointsArguments args,
    void Function(SetExceptionBreakpointsResponseBody) sendResponse,
  ) async {
    final mode = args.filters.contains('All')
        ? 'All'
        : args.filters.contains('Unhandled')
            ? 'Unhandled'
            : 'None';

    await isolateManager.setExceptionPauseMode(mode);

    sendResponse(SetExceptionBreakpointsResponseBody());
  }

  /// Shuts down the debug adapter, including terminating/detaching from the
  /// debugee if required.
  @override
  @nonVirtual
  Future<void> shutdown() async {
    await _waitForPendingOutputEvents();
    handleSessionTerminate();

    // Delay the shutdown slightly to allow any pending responses (such as the
    // terminate response) to be sent.
    //
    // If we don't wait long enough here, the client may miss events like the
    // TerminatedEvent. Waiting too long is generally not an issue, as the
    // client can terminate the process itself once it processes the
    // TerminatedEvent.

    Future.delayed(
      Duration(milliseconds: 500),
      () => super.shutdown(),
    );
  }

  /// Converts a URI in the form org-dartlang-sdk:///sdk/lib/collection/hash_set.dart
  /// to a local file-like URI based on the current SDK.
  Uri? convertOrgDartlangSdkToPath(Uri uri) {
    // org-dartlang-sdk URIs can be in multiple forms:
    //
    //   - org-dartlang-sdk:///sdk/lib/collection/hash_set.dart
    //   - org-dartlang-sdk:///runtime/lib/convert_patch.dart
    //
    // We currently only handle the sdk folder, as we don't know which runtime
    // is being used (this code is shared) and do not want to map to the wrong
    // sources.
    for (final mapping in orgDartlangSdkMappings.entries) {
      final mapPath = mapping.key;
      final mapUri = mapping.value;
      if (uri.isScheme(mapUri.scheme) && uri.path.startsWith(mapUri.path)) {
        return Uri.file(
          path.joinAll([
            mapPath,
            ...uri.pathSegments.skip(mapUri.pathSegments.length),
          ]),
        );
      }
    }

    return null;
  }

  /// Converts a file path inside the current SDK root into a URI in the
  /// form org-dartlang-sdk:///sdk/lib/collection/hash_set.dart.
  String? convertPathToOrgDartlangSdk(String input) {
    // TODO(dantup): Remove this once Flutter code has been updated to
    //  use convertUriToOrgDartlangSdk.
    return convertUriToOrgDartlangSdk(Uri.file(input))?.toFilePath();
  }

  /// Converts a file URI inside the current SDK root into a URI in the
  /// form org-dartlang-sdk:///sdk/lib/collection/hash_set.dart.
  Uri? convertUriToOrgDartlangSdk(Uri input) {
    // TODO(dantup): We may need to expand this if we start using
    //  macro-generated files in the SDK.
    if (!input.isScheme('file')) {
      return null;
    }
    final inputPath = input.toFilePath();

    for (final mapping in orgDartlangSdkMappings.entries) {
      final mapPath = mapping.key;
      final mapUri = mapping.value;
      if (path.isWithin(mapPath, inputPath)) {
        final relative = path.relative(inputPath, from: mapPath);
        return Uri(
          scheme: mapUri.scheme,
          host: '',
          pathSegments: [...mapUri.pathSegments, ...path.split(relative)],
        );
      }
    }

    return null;
  }

  /// [sourceRequest] is called by the client to request source code for a given
  /// source.
  ///
  /// The client may provide a whole source or just an int sourceReference (the
  /// spec originally had only sourceReference but now supports whole sources).
  ///
  /// The supplied sourceReference should correspond to a ScriptRef instance
  /// that was stored to generate the sourceReference when sent to the client.
  @override
  Future<void> sourceRequest(
    Request request,
    SourceArguments args,
    void Function(SourceResponseBody) sendResponse,
  ) async {
    final storedData = isolateManager.getStoredData(
      args.source?.sourceReference ?? args.sourceReference,
    );
    if (storedData == null) {
      throw StateError('source reference is no longer valid');
    }
    final thread = storedData.thread;
    final data = storedData.data;
    final scriptRef = data is vm.ScriptRef ? data : null;
    if (scriptRef == null) {
      throw StateError('source reference was not a valid script');
    }

    final script = await thread.getScript(scriptRef);
    final scriptSource = script.source;
    if (scriptSource == null) {
      throw DebugAdapterException('<source not available>');
    }

    sendResponse(
      SourceResponseBody(content: scriptSource, mimeType: dartMimeType),
    );
  }

  /// Handles a request from the client for the call stack for [args.threadId].
  ///
  /// This is usually called after we sent a [StoppedEvent] to the client
  /// notifying it that execution of an isolate has paused and it wants to
  /// populate the call stack view.
  ///
  /// Clients may fetch the frames in batches and VS Code in particular will
  /// send two requests initially - one for the top frame only, and then one for
  /// the next 19 frames. For better performance, the first request is satisfied
  /// entirely from the threads pauseEvent.topFrame so we do not need to
  /// round-trip to the VM Service.
  @override
  Future<void> stackTraceRequest(
    Request request,
    StackTraceArguments args,
    void Function(StackTraceResponseBody) sendResponse,
  ) async {
    // We prefer to provide frames in small batches. Rather than tell the client
    // how many frames there really are (which can be expensive to compute -
    // especially for web) we just add 20 on to the last frame we actually send,
    // as described in the spec:
    //
    // "Returning monotonically increasing totalFrames values for subsequent
    //  requests can be used to enforce paging in the client."
    const stackFrameBatchSize = 20;

    final threadId = args.threadId;
    final thread = isolateManager.getThread(threadId);
    final topFrame = thread?.pauseEvent?.topFrame;
    final startFrame = args.startFrame ?? 0;
    final numFrames = args.levels ?? 0;
    var totalFrames = 1;

    if (thread == null) {
      if (isolateManager.isInvalidThreadId(threadId)) {
        throw DebugAdapterException('Thread $threadId was not found');
      } else {
        // This condition means the thread ID was valid but the isolate has
        // since exited so rather than displaying an error, just return an empty
        // response because the client will be no longer interested in the
        // response.
        sendResponse(StackTraceResponseBody(
          stackFrames: [],
          totalFrames: 0,
        ));
        return;
      }
    }

    if (!thread.paused) {
      throw DebugAdapterException('Thread $threadId is not paused');
    }

    final stackFrames = <StackFrame>[];
    // If the request is only for the top frame, we may be able to satisfy it
    // from the threads `pauseEvent.topFrame`.
    if (startFrame == 0 && numFrames == 1 && topFrame != null) {
      totalFrames = 1 + stackFrameBatchSize;
      final dapTopFrame = await _converter.convertVmToDapStackFrame(
        thread,
        topFrame,
        isTopFrame: true,
      );
      stackFrames.add(dapTopFrame);
    } else {
      // Otherwise, send the request on to the VM.
      // The VM doesn't support fetching an arbitrary slice of frames, only a
      // maximum limit, so if the client asks for frames 20-30 we must send a
      // request for the first 30 and trim them ourselves.

      // DAP says if numFrames is 0 or missing (which we swap to 0 above) we
      // should return all.
      final limit = numFrames == 0 ? null : startFrame + numFrames;
      final stack = await vmService?.getStack(thread.isolate.id!, limit: limit);
      final frames = stack?.asyncCausalFrames ?? stack?.frames;

      if (stack != null && frames != null) {
        // When the call stack is truncated, we always add [stackFrameBatchSize]
        // to the count, indicating to the client there are more frames and
        // the size of the batch they should request when "loading more".
        //
        // It's ok to send a number that runs past the actual end of the call
        // stack and the client should handle this gracefully:
        //
        // "a client should be prepared to receive less frames than requested,
        //  which is an indication that the end of the stack has been reached."
        totalFrames = (stack.truncated ?? false)
            ? frames.length + stackFrameBatchSize
            : frames.length;

        // Find the first async marker, because some functionality only works
        // up until the first async boundary (e.g. rewind) since we're showing
        // the user async frames which are out-of-sync with the real frames
        // past that point.
        int? firstAsyncMarkerIndex = frames.indexWhere(
          (frame) => frame.kind == vm.FrameKind.kAsyncSuspensionMarker,
        );
        // indexWhere returns -1 if not found, we treat that as no marker (we
        // can rewind for all frames in the stack).
        if (firstAsyncMarkerIndex == -1) {
          firstAsyncMarkerIndex = null;
        }

        // Pre-resolve all URIs in batch so the call below does not trigger
        // many requests to the server.
        final allUris = frames
            .map((frame) => frame.location?.script?.uri)
            .nonNulls
            .map(Uri.parse)
            .toList();
        await thread.resolveUrisToPathsBatch(allUris);

        Future<StackFrame> convert(int index, vm.Frame frame) async {
          return _converter.convertVmToDapStackFrame(
            thread,
            frame,
            firstAsyncMarkerIndex: firstAsyncMarkerIndex,
            isTopFrame: startFrame == 0 && index == 0,
          );
        }

        final frameSubset = frames.sublist(startFrame);
        stackFrames.addAll(await Future.wait(frameSubset.mapIndexed(convert)));
      }
    }

    sendResponse(
      StackTraceResponseBody(
        stackFrames: stackFrames,
        totalFrames: totalFrames,
      ),
    );
  }

  /// Handles the clients "step in" request for the thread in [args.threadId].
  @override
  Future<void> stepInRequest(
    Request request,
    StepInArguments args,
    void Function() sendResponse,
  ) async {
    await isolateManager.resumeThread(args.threadId, vm.StepOption.kInto);
    sendResponse();
  }

  /// Handles the clients "step out" request for the thread in [args.threadId].
  @override
  Future<void> stepOutRequest(
    Request request,
    StepOutArguments args,
    void Function() sendResponse,
  ) async {
    await isolateManager.resumeThread(args.threadId, vm.StepOption.kOut);
    sendResponse();
  }

  /// Stores [evaluateName] as the expression that can be evaluated to get
  /// [instanceRef].
  void storeEvaluateName(vm.InstanceRef instanceRef, String? evaluateName) {
    if (evaluateName != null) {
      _evaluateNamesForInstanceRefIds[instanceRef.id!] = evaluateName;
    }
  }

  /// Overridden by sub-classes to handle when the client sends a
  /// `terminateRequest` (a request for a graceful shut down).
  Future<void> terminateImpl();

  /// [terminateRequest] is called by the client when it wants us to gracefully
  /// shut down.
  ///
  /// It's not very obvious from the names, but `terminateRequest` is sent first
  /// (a request for a graceful shutdown) and `disconnectRequest` second (a
  /// request for a forced shutdown).
  ///
  /// https://microsoft.github.io/debug-adapter-protocol/overview#debug-session-end
  @override
  Future<void> terminateRequest(
    Request request,
    TerminateArguments? args,
    void Function() sendResponse,
  ) async {
    isTerminating = true;

    await terminateImpl();
    sendResponse();

    await shutdown();
  }

  /// Handles a request from the client for the list of threads.
  ///
  /// This is usually called after we sent a [StoppedEvent] to the client
  /// notifying it that execution of an isolate has paused and it wants to
  /// populate the threads view.
  @override
  Future<void> threadsRequest(
    Request request,
    void args,
    void Function(ThreadsResponseBody) sendResponse,
  ) async {
    final threads = [
      for (final thread in isolateManager.threads)
        Thread(
          id: thread.threadId,
          name: thread.isolate.name ?? '<unnamed isolate>',
        )
    ];
    sendResponse(ThreadsResponseBody(threads: threads));
  }

  /// [variablesRequest] is called by the client to request child variables for
  /// a given variables variablesReference.
  ///
  /// The variablesReference provided by the client will be a reference the
  /// server has previously provided, for example in response to a scopesRequest
  /// or an evaluateRequest.
  ///
  /// We use the reference to look up the stored data and then create variables
  /// based on the type of data. For a Frame, we will return the local
  /// variables, for a List/MapAssociation we will return items from it, and for
  /// an instance we will return the fields (and possibly getters) for that
  /// instance.
  @override
  Future<void> variablesRequest(
    Request request,
    VariablesArguments args,
    void Function(VariablesResponseBody) sendResponse,
  ) async {
    final service = vmService;
    final childStart = args.start;
    final childCount = args.count;
    final storedData = isolateManager.getStoredData(args.variablesReference);
    if (storedData == null) {
      throw StateError('variablesReference is no longer valid');
    }
    final thread = storedData.thread;
    var data = storedData.data;

    VariableFormat? format;
    // Unwrap any variable we stored with formatting info.
    if (data is VariableData) {
      format = data.format;
      data = data.data;
    }

    // If no explicit formatting, use from args.
    format ??= VariableFormat.fromDapValueFormat(args.format);

    final variables = <Variable>[];

    if (data is FrameScopeData && data.kind == FrameScopeDataKind.locals) {
      final vars = data.frame.vars;
      if (vars != null) {
        Future<Variable> convert(int index, vm.BoundVariable variable) {
          // Store the expression that gets this object as we may need it to
          // compute evaluateNames for child objects later.
          final value = variable.value;
          if (value is vm.InstanceRef) {
            storeEvaluateName(value, variable.name);
          }
          return _converter.convertVmResponseToVariable(
            thread,
            variable.value,
            name: variable.name,
            allowCallingToString: evaluateToStringInDebugViews &&
                index < maxToStringsPerEvaluation,
            evaluateName: variable.name,
            format: format,
          );
        }

        variables.addAll(await Future.wait(vars.mapIndexed(convert)));

        // Sort the variables by name.
        variables.sortBy((v) => v.name);
      }
    } else if (data is FrameScopeData &&
        data.kind == FrameScopeDataKind.globals) {
      /// Helper to simplify calling converter.
      Future<Variable> convert(int index, vm.FieldRef fieldRef) async {
        return _converter.convertFieldRefToVariable(
          thread,
          fieldRef,
          allowCallingToString:
              evaluateToStringInDebugViews && index < maxToStringsPerEvaluation,
          format: format,
        );
      }

      final globals = await _getFrameGlobals(thread, data.frame);
      variables.addAll(await Future.wait(globals.mapIndexed(convert)));
      variables.sortBy((v) => v.name);
    } else if (data is InspectData) {
      // When sending variables as part of an OutputEvent, VS Code will only
      // show the first field, so we wrap the object to ensure there's always
      // a single field.
      final instance = data.instance;
      variables.add(Variable(
        name: '', // Unused.
        value: '<inspected variable>', // Shown to user, expandable.
        variablesReference: instance != null ? thread.storeData(instance) : 0,
      ));
    } else if (data is WrappedInstanceVariable) {
      // WrappedInstanceVariables are used to support DAP-over-DDS clients that
      // had a VM Instance ID and wanted to convert it to a variable for use in
      // `variables` requests.
      try {
        final response = await isolateManager.getObject(
          storedData.thread.isolate,
          vm.ObjRef(id: data.instanceId),
          offset: childStart,
          count: childCount,
        );
        // Because `variables` requests are a request for _child_ variables but we
        // want DAP-over-DDS clients to be able to get the whole variable (eg.
        // including toe initial string representation of the variable itself) the
        // initial request will return a list containing a single variable named
        // `value`. This will contain both the `variablesReference` to get the
        // children, and also a `value` field with the display string.
        final variable = await _converter.convertVmResponseToVariable(
          thread,
          response,
          name: 'value',
          evaluateName: null,
          allowCallingToString: evaluateToStringInDebugViews,
        );
        variables.add(variable);
      } on vm.SentinelException catch (e) {
        variables.add(Variable(
          name: 'value',
          value: e.sentinel.valueAsString ?? '<sentinel>',
          variablesReference: 0,
        ));
      }
    } else if (data is vm.MapAssociation) {
      final key = data.key;
      final value = data.value;
      if (key is vm.InstanceRef && value is vm.InstanceRef) {
        // For a MapAssociation, we create a dummy set of variables for "key" and
        // "value" so that each may be expanded if they are complex values.
        variables.addAll([
          Variable(
            name: 'key',
            value: await _converter.convertVmInstanceRefToDisplayString(
              thread,
              key,
              allowCallingToString: evaluateToStringInDebugViews,
              format: format,
            ),
            variablesReference: _converter.isSimpleKind(key.kind)
                ? 0
                : thread.storeData(VariableData(key, format)),
          ),
          Variable(
              name: 'value',
              value: await _converter.convertVmInstanceRefToDisplayString(
                thread,
                value,
                allowCallingToString: evaluateToStringInDebugViews,
                format: format,
              ),
              variablesReference: _converter.isSimpleKind(value.kind)
                  ? 0
                  : thread.storeData(VariableData(value, format)),
              evaluateName:
                  buildEvaluateName('', parentInstanceRefId: value.id)),
        ]);
      }
    } else if (data is vm.ObjRef) {
      try {
        final object = await isolateManager.getObject(
          storedData.thread.isolate,
          data,
          offset: childStart,
          count: childCount,
        );

        if (object is vm.Sentinel) {
          variables.add(Variable(
            name: '<eval error>',
            value: object.valueAsString ?? '<sentinel>',
            variablesReference: 0,
          ));
        } else if (object is vm.Instance) {
          variables.addAll(await _converter.convertVmInstanceToVariablesList(
            thread,
            object,
            evaluateName: buildEvaluateName('', parentInstanceRefId: data.id),
            allowCallingToString: evaluateToStringInDebugViews,
            startItem: childStart,
            numItems: childCount,
            format: format,
          ));
        } else {
          variables.add(Variable(
            name: '<eval error>',
            value: object.runtimeType.toString(),
            variablesReference: 0,
          ));
        }
      } on vm.SentinelException catch (e) {
        variables.add(Variable(
          name: '<eval error>',
          value: e.sentinel.valueAsString ?? '<sentinel>',
          variablesReference: 0,
        ));
      }
    } else if (data is VariableGetter && service != null) {
      final variable = await _converter.createVariableForGetter(
        service,
        thread,
        data.instance,
        // Empty names for lazy variable values because they were already shown
        // in the parent object.
        variableName: '',
        getterName: data.getterName,
        evaluateName: data.parentEvaluateName,
        allowCallingToString: data.allowCallingToString,
        format: format,
      );
      variables.add(variable);
    }

    sendResponse(VariablesResponseBody(variables: variables));
  }

  /// Gets global variables for the library of [frame].
  Future<List<vm.FieldRef>> _getFrameGlobals(
    ThreadInfo thread,
    vm.Frame frame,
  ) async {
    final scriptRef = frame.location?.script;
    if (scriptRef == null) {
      return [];
    }

    final script = await thread.getScript(scriptRef);
    final libraryRef = script.library;
    if (libraryRef == null) {
      return [];
    }

    final library = await thread.getObject(libraryRef);
    if (library is! vm.Library) {
      return [];
    }

    return library.variables ?? [];
  }

  /// Fixes up a VM Service WebSocket URI to not have a trailing /ws
  /// and use the HTTP scheme which is what DDS expects.
  Uri vmServiceUriToHttp(Uri uri) {
    final isSecure = uri.isScheme('https') || uri.isScheme('wss');
    uri = uri.replace(scheme: isSecure ? 'https' : 'http');

    final segments = uri.pathSegments;
    if (segments.isNotEmpty && segments.last == 'ws') {
      uri = uri.replace(pathSegments: segments.take(segments.length - 1));
    }

    return uri;
  }

  /// Fixes up a VM Service [uri] to a WebSocket URI with a trailing /ws
  /// for connecting when not using DDS.
  ///
  /// DDS does its own cleaning up of the URI.
  Uri vmServiceUriToWebSocket(Uri uri) {
    // The VM Service library always expects the WebSockets URI so fix the
    // scheme (http -> ws, https -> wss).
    final isSecure = uri.isScheme('https') || uri.isScheme('wss');
    uri = uri.replace(scheme: isSecure ? 'wss' : 'ws');

    if (uri.path.endsWith('/ws') || uri.path.endsWith('/ws/')) {
      return uri;
    }

    final append = uri.path.endsWith('/') ? 'ws' : '/ws';
    final newPath = '${uri.path}$append';
    return uri.replace(path: newPath);
  }

  /// Creates one or more OutputEvents for the provided [message].
  ///
  /// Messages that contain stack traces may be split up into separate events
  /// for each frame to allow location metadata to be attached.
  Future<List<OutputEventBody>> _buildOutputEvents(
    String category,
    String message, {
    int? variablesReference,
  }) async {
    if (variablesReference != null) {
      return [
        OutputEventBody(
          category: category,
          output: message,
          variablesReference: variablesReference,
        )
      ];
    } else {
      try {
        return await _buildOutputEventsWithSourceReferences(category, message);
      } catch (e, s) {
        // Since callers of [sendOutput] may not await it, don't allow unhandled
        // errors (for example if the VM Service quits while we were trying to
        // map URIs), just log and return the event without metadata.
        logger?.call('Failed to build OutputEvent: $e, $s');
        return [OutputEventBody(category: category, output: message)];
      }
    }
  }

  /// Builds OutputEvents with source references if they contain stack frames.
  ///
  /// If a stack trace can be parsed from [message], file/line information will
  /// be included in the metadata of the event.
  Future<List<OutputEventBody>> _buildOutputEventsWithSourceReferences(
      String category, String message) async {
    final events = <OutputEventBody>[];

    // Extract all the URIs so we can send a batch request for resolving them.
    final lines = message.split('\n');
    final frameLocations = lines.map(parseDartStackFrame).toList();
    final uris = frameLocations.nonNulls.map((f) => f.uri).toList();

    // We need an Isolate to resolve package URIs. Since we don't know what
    // isolate printed an error to stderr, we just have to use the first one and
    // hope the packages are available. If one is not available (which should
    // never be the case), we will just skip resolution.
    final thread = isolateManager.threads.firstOrNull;

    // Send a batch request. This will cache the results so we can easily use
    // them in the loop below by calling the method again.
    if (uris.isNotEmpty && thread != null) {
      try {
        await Future.wait<void>([
          // Used to resolve paths to make them clickable.
          thread.resolveUrisToPathsBatch(uris),
          // We'll also want to use isExternalPackageLibrary to fade out non-user
          // stack frames, so cache the result for the lib paths in bulk too.
          thread.resolveUrisToPackageLibPathsBatch(uris),
        ]);
      } catch (e, s) {
        // Ignore errors that may occur if the VM is shutting down before we got
        // this request out. In most cases we will have pre-cached the results
        // when the libraries were loaded (in order to check if they're user code)
        // so it's likely this won't cause any issues (dart:isolate-patch is an
        // exception seen that appears in the stack traces but was not previously
        // seen/cached).
        logger?.call('Failed to resolve URIs: $e\n$s');
      }
    }

    // Convert any URIs to paths and if we successfully get a path, check
    // whether it's inside the users workspace so we can fade out unrelated
    // frames.
    final framePaths = await Future.wait(frameLocations.map((frame) async {
      final uri = frame?.uri;
      if (uri == null) return null;
      if (isSupportedFileScheme(uri)) {
        return (uri: uri, isUserCode: isInUserProject(uri));
      }
      if (thread == null || !isResolvableUri(uri)) return null;
      try {
        final fileLikeUri = await thread.resolveUriToPath(uri);
        return fileLikeUri != null
            ? (uri: fileLikeUri, isUserCode: isInUserProject(fileLikeUri))
            : null;
      } catch (e, s) {
        // Swallow errors for the same reason noted above.
        logger?.call('Failed to resolve URIs: $e\n$s');
      }
      return null;
    }));

    final supportsAnsiColors = args.allowAnsiColorOutput ?? false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final frameLocation = frameLocations[i];
      final uri = frameLocation?.uri;
      final framePathInfo = framePaths[i];

      // A file-like URI ('file://' or 'dart-macro+file://').
      final fileLikeUri = framePathInfo?.uri;

      // Default to true so that if we don't know whether this is user-project
      // then we leave the formatting as-is and don't fade anything out.
      final isUserProject = framePathInfo?.isUserCode ?? true;

      // For the name, we usually use the package URI, but if we only had a file
      // URI to begin with, try to make it relative to cwd so it's not so long.
      final name = uri != null && fileLikeUri != null
          ? (uri.isScheme('file')
              ? _converter.convertToRelativePath(uri.toFilePath())
              : uri.toString())
          : null;

      // If this is non-user code, fade out the stack frame line so that user
      // lines are more visible.
      final linePrefix =
          !isUserProject && supportsAnsiColors ? '\u001B[2m' : ''; // 2=dim
      final lineSuffix =
          !isUserProject && supportsAnsiColors ? '\u001B[0m' : ''; // 0=reset

      // Because we split on newlines, all items except the last one need to
      // have their trailing newlines added back.
      final lineEnd = i != lines.length - 1 ? '\n' : '';
      final output = '$linePrefix$line$lineSuffix$lineEnd';

      // If the output is empty (for example the output ended with \n so after
      // splitting by \n, the last iteration is empty) then we don't need
      // to add any event.
      if (output.isEmpty) {
        continue;
      }

      final clientPath =
          fileLikeUri != null ? toClientPathOrUri(fileLikeUri) : null;
      events.add(
        OutputEventBody(
          category: category,
          output: output,
          source:
              clientPath != null ? Source(name: name, path: clientPath) : null,
          line: frameLocation?.line,
          column: frameLocation?.column,
        ),
      );
    }

    return events;
  }

  /// Handles evaluation of an expression that is (or begins with)
  /// `threadExceptionExpression` which corresponds to the exception at the top
  /// of [thread].
  Future<vm.Response?> _evaluateExceptionExpression(
    int exceptionReference,
    String expression,
    ThreadInfo thread,
  ) async {
    final exception = isolateManager.getStoredData(exceptionReference)?.data
        as vm.InstanceRef?;

    if (exception == null) {
      return null;
    }

    if (expression == threadExceptionExpression) {
      return exception;
    }

    // Strip the prefix off since we'll evaluate against the exception
    // by its ID.
    final expressionWithoutExceptionExpression =
        expression.substring(threadExceptionExpression.length + 1);

    return vmEvaluate(
      thread,
      exception.id!,
      expressionWithoutExceptionExpression,
    );
  }

  /// Sends a VM 'evaluate' request for [thread].
  Future<vm.Response?> vmEvaluate(
    ThreadInfo thread,
    String targetId,
    String expression, {
    bool? disableBreakpoints = true,
  }) async {
    final isolateId = thread.isolate.id!;
    final futureOrEvalZoneId = thread.currentEvaluationZoneId;
    final evalZoneId = futureOrEvalZoneId is String
        ? futureOrEvalZoneId
        : await futureOrEvalZoneId;

    return vmService?.evaluate(
      isolateId,
      targetId,
      expression,
      disableBreakpoints: disableBreakpoints,
      idZoneId: evalZoneId,
    );
  }

  /// Sends a VM 'evaluateInFrame' request for [thread].
  Future<vm.Response?> vmEvaluateInFrame(
    ThreadInfo thread,
    int frameIndex,
    String expression, {
    bool? disableBreakpoints = true,
  }) async {
    final isolateId = thread.isolate.id!;
    final futureOrEvalZoneId = thread.currentEvaluationZoneId;
    final evalZoneId = futureOrEvalZoneId is String
        ? futureOrEvalZoneId
        : await futureOrEvalZoneId;

    return vmService?.evaluateInFrame(
      isolateId,
      frameIndex,
      expression,
      disableBreakpoints: disableBreakpoints,
      idZoneId: evalZoneId,
    );
  }

  @protected
  @mustCallSuper
  Future<void> handleDebugEvent(vm.Event event) async {
    // Delay processing any events until the debugger initialization has
    // finished running, as events may arrive (for ex. IsolateRunnable) while
    // it's doing is own initialization that this may interfere with.
    await debuggerInitialized;

    await isolateManager.handleEvent(event);

    final eventKind = event.kind;
    final isolate = event.isolate;
    // We pause isolates on exit to allow requests for resolving URIs in
    // stderr call stacks, so when we see an isolate pause, wait for any
    // pending logs and then resume it (so it exits).
    if (eventKind == vm.EventKind.kPauseExit && isolate != null) {
      await _waitForPendingOutputEvents();
      await isolateManager.readyToResumeIsolate(isolate);
    }
  }

  @protected
  @mustCallSuper
  Future<void> handleExtensionEvent(vm.Event event) async {
    await debuggerInitialized;

    // Base Dart does not do anything here, but other DAs (like Flutter) may
    // override it to do their own handling.
  }

  @protected
  @mustCallSuper
  Future<void> handleIsolateEvent(vm.Event event) async {
    // Delay processing any events until the debugger initialization has
    // finished running, as events may arrive (for ex. IsolateRunnable) while
    // it's doing is own initialization that this may interfere with.
    await debuggerInitialized;

    // Allow IsolateManager to handle any state-related events.
    await isolateManager.handleEvent(event);

    switch (event.kind) {
      // Pass any Service Extension events on to the client so they can enable
      // functionality based upon them.
      case vm.EventKind.kServiceExtensionAdded:
        _sendServiceExtensionAdded(
          event.extensionRPC!,
          event.isolate!.id!,
        );
        break;
    }
  }

  /// Helper to convert to InstanceRef to a complete untruncated unquoted
  /// String, handling [vm.InstanceKind.kNull] which is the type for the unused
  /// fields of a log event.
  Future<String?> getFullString(ThreadInfo thread, vm.InstanceRef? ref) async {
    if (ref == null || ref.kind == vm.InstanceKind.kNull) {
      return null;
    }
    return _converter
        .convertVmInstanceRefToDisplayString(
      thread,
      ref,
      // Always allow calling toString() here as the user expects the full
      // string they logged regardless of the evaluateToStringInDebugViews
      // setting.
      allowCallingToString: true,
      allowTruncatedValue: false,
      format: VariableFormat.noQuotes(),
    )
        // Fetching strings from the server may throw if they have been
        // collected since (for example if a Hot Restart occurs while
        // we're running this) or if the app is terminating. Log the error and
        // just return null so nothing is shown.
        .then<String?>(
      (s) => s,
      onError: (Object e) {
        logger?.call('$e');
        return null;
      },
    );
  }

  /// Handles a dart:developer log() event, sending output to the client.
  @protected
  @mustCallSuper
  Future<void> handleLoggingEvent(vm.Event event) async {
    final record = event.logRecord;
    final thread = isolateManager.threadForIsolate(event.isolate);
    if (record == null || thread == null) {
      return;
    }

    var loggerName = await getFullString(thread, record.loggerName);
    if (loggerName?.isEmpty ?? true) {
      loggerName = 'log';
    }
    final message = await getFullString(thread, record.message);
    final error = await getFullString(thread, record.error);
    final stack = await getFullString(thread, record.stackTrace);

    final prefix = '[$loggerName] ';

    if (message != null) {
      sendPrefixedOutput('console', prefix, '$message\n');
    }
    if (error != null) {
      sendPrefixedOutput('console', prefix, '$error\n');
    }
    if (stack != null) {
      sendPrefixedOutput('console', prefix, '$stack\n');
    }
  }

  @protected
  @mustCallSuper
  Future<void> handleServiceEvent(vm.Event event) async {
    await debuggerInitialized;

    switch (event.kind) {
      // Service registrations are passed to the client so they can toggle
      // behaviour based on their presence.
      case vm.EventKind.kServiceRegistered:
        _sendServiceRegistration(event.service!, event.method!);
        break;
      case vm.EventKind.kServiceUnregistered:
        _sendServiceUnregistration(event.service!, event.method!);
        break;
    }
  }

  /// Resolves any URI stored in [data] with key [field] to a local file URI via
  /// the VM Service and adds it to [data] with a 'resolved' prefix.
  ///
  /// A resolved URI will not be added if the URI cannot be resolved or is
  /// already a 'file://' URI.
  Future<void> resolveToolEventUris(
    vm.IsolateRef? isolate,
    Map<String, Object?> data,
    String field,
  ) async {
    final thread = isolateManager.threadForIsolate(isolate);
    if (thread == null) {
      return;
    }

    final uriString = data[field];
    if (uriString is! String) {
      return;
    }
    final uri = Uri.tryParse(uriString);
    if (uri == null) {
      return;
    }

    // Doesn't need resolving if already file-like.
    if (isSupportedFileScheme(uri)) {
      return;
    }

    final fileLikeUri = await thread.resolveUriToPath(uri);
    if (fileLikeUri != null) {
      // Convert:
      //   uri -> resolvedUri
      //   fileUri -> resolvedFileUri
      final resolvedFieldName =
          'resolved${field.substring(0, 1).toUpperCase()}${field.substring(1)}';
      data[resolvedFieldName] = fileLikeUri.toString();
    }
  }

  @protected
  @mustCallSuper
  Future<void> handleToolEvent(vm.Event event) async {
    await debuggerInitialized;

    // Some events will contain URIs that need to first be mapped to file URIs
    // so the IDE can understand them.
    final data = event.extensionData?.data;
    if (data is Map<String, Object?>) {
      const uriFieldNames = ['fileUri', 'uri'];
      for (final fieldName in uriFieldNames) {
        await resolveToolEventUris(event.isolate, data, fieldName);
      }
    }

    sendEvent(
      RawEventBody({
        'kind': event.extensionKind,
        'data': data,
      }),
      eventType: 'dart.toolEvent',
    );
  }

  void _handleStderrEvent(vm.Event event) {
    _sendOutputStreamEvent('stderr', event);
  }

  void _handleStdoutEvent(vm.Event event) {
    _sendOutputStreamEvent('stdout', event);
  }

  Future<void> _handleVmServiceClosed() async {
    isTerminating = true;
    if (terminateOnVmServiceClose) {
      handleSessionTerminate();
    }
  }

  void _logTraffic(String message) {
    logger?.call(message);
    if (sendLogsToClient) {
      sendEvent(RawEventBody({"message": message}), eventType: 'dart.log');
    }
  }

  /// Performs some setup that is common to both [launchRequest] and
  /// [attachRequest].
  Future<void> _prepareForLaunchOrAttach(bool? noDebug) async {
    _sendLogsToClient = args.sendLogsToClient ?? false;

    // Don't start launching until configurationDone.
    if (!_configurationDoneCompleter.isCompleted) {
      logger?.call('Waiting for configurationDone request...');
      await _configurationDoneCompleter.future;
    }

    // Change our current directory to match that of the request. This solves
    // some issues parsing stack traces because `package:stack_trace` will
    // convert relative to absolute paths using `path.absolute()`.
    final cwd = args.cwd;
    if (cwd != null) {
      Directory.current = Directory(cwd);
    }

    // Also ensure the cwd always has uppercase drive letters to match what
    // we'll normalize to everywhere else.
    Directory.current = Directory(normalizePath(Directory.current.path));

    // Notify IsolateManager if we'll be debugging so it knows whether to set
    // up breakpoints etc. when isolates are registered.
    final debug = !(noDebug ?? false);
    isolateManager.debug = debug;
    isolateManager.debugSdkLibraries = args.debugSdkLibraries ?? true;
    isolateManager.debugExternalPackageLibraries =
        args.debugExternalPackageLibraries ?? true;
  }

  /// Sends output for a VM WriteEvent to the client.
  ///
  /// Used to pass stdout/stderr when there's no access to the streams directly.
  void _sendOutputStreamEvent(String type, vm.Event event) {
    final data = event.bytes;
    if (data == null) {
      return;
    }
    final message = utf8.decode(base64Decode(data));
    sendOutput('stdout', message);
  }

  void _sendServiceExtensionAdded(String extensionRPC, String isolateId) {
    sendEvent(
      RawEventBody({'extensionRPC': extensionRPC, 'isolateId': isolateId}),
      eventType: 'dart.serviceExtensionAdded',
    );
  }

  void _sendServiceRegistration(String service, String method) {
    sendEvent(
      RawEventBody({'service': service, 'method': method}),
      eventType: 'dart.serviceRegistered',
    );
  }

  void _sendServiceUnregistration(String service, String method) {
    sendEvent(
      RawEventBody({'service': service, 'method': method}),
      eventType: 'dart.serviceUnregistered',
    );
  }

  /// Updates the current debug options for the session.
  ///
  /// Clients may not know about all debug options, so anything not included
  /// in the map will not be updated by this method.
  Future<void> _updateDebugOptions(Map<String, Object?> args) async {
    if (args.containsKey('debugSdkLibraries')) {
      isolateManager.debugSdkLibraries = args['debugSdkLibraries'] as bool;
    }
    if (args.containsKey('debugExternalPackageLibraries')) {
      isolateManager.debugExternalPackageLibraries =
          args['debugExternalPackageLibraries'] as bool;
    }
    await isolateManager.applyDebugOptions();
  }

  /// Configures whether verbose logs should be sent to the client in `dart.log`
  /// events.
  Future<void> _updateSendLogsToClient(Map<String, Object?> args) async {
    if (args.containsKey('enabled')) {
      _sendLogsToClient = args['enabled'] as bool;
    }
  }

  /// A wrapper around the same name function from package:vm_service that
  /// allows logging all traffic over the VM Service.
  Future<vm.VmService> _vmServiceConnectUri(String wsUri) async {
    final socket = await WebSocket.connect(wsUri);
    final controller = StreamController();
    final streamClosedCompleter = Completer();
    final logger = this.logger;

    socket.listen(
      (data) {
        _logTraffic('<== [VM] $data');
        controller.add(data);
      },
      onDone: () => streamClosedCompleter.complete(),
    );

    return vm.VmService(
      controller.stream,
      (String message) {
        logger?.call('==> [VM] $message');
        _logTraffic('==> [VM] $message');
        socket.add(message);
      },
      log: logger != null ? VmServiceLogger(logger) : null,
      disposeHandler: () => socket.close(),
      streamClosed: streamClosedCompleter.future,
    );
  }

  /// Wraps a function with an error handler that handles errors that occur when
  /// the VM Service/DDS shuts down.
  ///
  /// When the debug adapter is terminating, it's possible in-flight requests
  /// triggered by handlers will fail with "Service Disappeared". This is
  /// normal and such errors can be ignored, rather than allowed to pass
  /// uncaught.
  _StreamEventHandler<T> _wrapHandlerWithErrorHandling<T>(
    _StreamEventHandler<T> handler,
  ) {
    return (data) => _withErrorHandling(() => handler(data));
  }

  /// Waits for any pending async output events that might be in progress.
  ///
  /// If another output event is queued while waiting, the new event will be
  /// waited for, until there are no more.
  Future<void> _waitForPendingOutputEvents() async {
    // Keep awaiting it as long as it's changing to allow for other
    // events being queued up while it runs.
    var lastEvent = _lastOutputEvent;
    do {
      lastEvent = _lastOutputEvent;
      await lastEvent;
    } while (lastEvent != _lastOutputEvent);
  }

  /// Calls a function with an error handler that handles errors that occur when
  /// the VM Service/DDS shuts down.
  ///
  /// When the debug adapter is terminating, it's possible in-flight requests
  /// will fail with "Service Disappeared". This is normal and such errors can
  /// be ignored, rather than allowed to pass uncaught.
  FutureOr<T?> _withErrorHandling<T>(FutureOr<T> Function() func) async {
    try {
      return await func();
    } on vm.RPCError catch (e) {
      // kServiceDisappeared is thrown sometimes when the VM Service is
      // shutting down. Usually this is because we're shutting down (and
      // `isTerminating` is true), but it can also happen if the app is closed
      // outside of the DAP (eg. closing the simulator) so it's possible our
      // requests will fail in this way before we've handled any event to set
      // `isTerminating`.
      if (e.isServiceDisposedError) {
        return null;
      }

      // For any other kind of server error, ignore it if we're shutting down
      // (because lots of requests can generate all sorts of errors if the VM
      // and Isolates are shutting down), or if it's a "client closed with
      // pending request" error (which also indicates a shutdown, but as above,
      // we might not have set `isTerminating` yet).
      if (e.code == json_rpc_errors.SERVER_ERROR) {
        // Ignore all server errors during shutdown.
        if (isTerminating) {
          return null;
        }
      }

      // Otherwise, it's an unexpected/unknown failure and should be rethrown.
      rethrow;
    }
  }

  /// Whether the current client supports URIs in place of file paths, including
  /// file-like URIs that are not the 'file' scheme (such as 'dart-macro+file').
  bool get clientSupportsUri => _initializeArgs?.supportsDartUris ?? false;

  /// Returns whether [uri] is a file-like URI scheme that is supported by the
  /// client.
  ///
  /// Returning `true` here does not guarantee that the client supports URIs,
  /// the caller should also check [clientSupportsUri].
  bool isSupportedFileScheme(Uri uri) {
    return uri.isScheme('file') ||
        // Handle all file-like schemes that end '+file' like
        // 'dart-macro+file://'.
        (clientSupportsUri && uri.scheme.endsWith('+file'));
  }

  /// Converts a URI into a form that can be used by the client.
  ///
  /// If the client supports URIs (like VS Code), it will be returned unchanged
  /// but otherwise it will be the `toFilePath()` equivalent if a 'file://' URI
  /// and otherwise `null`.
  String? toClientPathOrUri(Uri? uri) {
    if (uri == null) {
      return null;
    } else if (clientSupportsUri) {
      return uri.toString();
    } else if (uri.isScheme('file')) {
      return uri.toFilePath();
    } else {
      return null;
    }
  }

  /// Converts a String used by the client as a path/URI into a [Uri].
  Uri fromClientPathOrUri(String filePathOrUriString) {
    var uri = Uri.tryParse(filePathOrUriString);
    if (uri == null || !isSupportedFileScheme(uri)) {
      uri = Uri.file(filePathOrUriString);
    }
    return uri;
  }
}

/// An implementation of [LaunchRequestArguments] that includes all fields used
/// by the Dart CLI and test debug adapters.
///
/// This class represents the data passed from the client editor to the debug
/// adapter in launchRequest, which is a request to start debugging an
/// application.
///
/// Specialized adapters (such as Flutter) have their own versions of this
/// class.
class DartLaunchRequestArguments extends DartCommonLaunchAttachRequestArguments
    implements LaunchRequestArguments {
  /// A reader for protocol arguments that throws detailed exceptions if
  /// arguments aren't of the correct type.
  static final arg = DebugAdapterArgumentReader('launch');

  /// If noDebug is true the launch request should launch the program without
  /// enabling debugging.
  @override
  final bool? noDebug;

  /// The program/Dart script to be run.
  final String program;

  /// Arguments to be passed to [program].
  final List<String>? args;

  /// Arguments to be passed to the tool that will run [program] (for example,
  /// the VM or Flutter tool).
  final List<String>? toolArgs;

  /// Arguments to be passed directly to the Dart VM that will run [program].
  ///
  /// Unlike [toolArgs] which always go after the complete tool, these args
  /// always go directly after `dart`:
  ///
  ///   - dart {vmAdditionalArgs} {toolArgs}
  ///   - dart {vmAdditionalArgs} run test:test {toolArgs}
  final List<String>? vmAdditionalArgs;

  final int? vmServicePort;

  /// Which console to run the program in.
  ///
  /// If "terminal" or "externalTerminal" will cause the program to be run by
  /// the client by having the server call the `runInTerminal` request on the
  /// client (as long as the client advertises support for
  /// `runInTerminalRequest`).
  ///
  /// Otherwise will run inside the debug adapter and stdout/stderr will be
  /// routed to the client using [OutputEvent]s. This is the default (and
  /// simplest) way, but prevents the user from being able to type into `stdin`.
  final String? console;

  /// An optional tool to run instead of "dart".
  ///
  /// In combination with [customToolReplacesArgs] allows invoking a custom
  /// tool instead of "dart" to launch scripts/tests. The custom tool must be
  /// completely compatible with the tool/command it is replacing.
  ///
  /// This field should be a full absolute path if the tool may not be available
  /// in `PATH`.
  final String? customTool;

  /// The number of arguments to delete from the beginning of the argument list
  /// when invoking [customTool].
  ///
  /// For example, setting [customTool] to `dart_test` and
  /// `customToolReplacesArgs` to `2` for a test run would invoke
  /// `dart_test foo_test.dart` instead of `dart run test:test foo_test.dart`.
  final int? customToolReplacesArgs;

  DartLaunchRequestArguments({
    this.noDebug,
    required this.program,
    this.args,
    this.vmServicePort,
    this.toolArgs,
    this.vmAdditionalArgs,
    this.console,
    this.customTool,
    this.customToolReplacesArgs,
    super.restart,
    super.name,
    super.cwd,
    super.env,
    super.additionalProjectPaths,
    super.debugSdkLibraries,
    super.debugExternalPackageLibraries,
    super.showGettersInDebugViews,
    super.evaluateGettersInDebugViews,
    super.evaluateToStringInDebugViews,
    super.sendLogsToClient,
    super.sendCustomProgressEvents = null,
    super.allowAnsiColorOutput,
  });

  DartLaunchRequestArguments.fromMap(super.obj)
      : noDebug = arg.read<bool?>(obj, 'noDebug'),
        program = arg.read<String>(obj, 'program'),
        args = arg.readOptionalList<String>(obj, 'args'),
        toolArgs = arg.readOptionalList<String>(obj, 'toolArgs'),
        vmAdditionalArgs =
            arg.readOptionalList<String>(obj, 'vmAdditionalArgs'),
        vmServicePort = arg.read<int?>(obj, 'vmServicePort'),
        console = arg.read<String?>(obj, 'console'),
        customTool = arg.read<String?>(obj, 'customTool'),
        customToolReplacesArgs = arg.read<int?>(obj, 'customToolReplacesArgs'),
        super.fromMap();

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        if (noDebug != null) 'noDebug': noDebug,
        'program': program,
        if (args != null) 'args': args,
        if (toolArgs != null) 'toolArgs': toolArgs,
        if (vmAdditionalArgs != null) 'vmAdditionalArgs': vmAdditionalArgs,
        if (vmServicePort != null) 'vmServicePort': vmServicePort,
        if (console != null) 'console': console,
        if (customTool != null) 'customTool': customTool,
        if (customToolReplacesArgs != null)
          'customToolReplacesArgs': customToolReplacesArgs,
      };

  static DartLaunchRequestArguments fromJson(Map<String, Object?> obj) =>
      DartLaunchRequestArguments.fromMap(obj);
}

/// A helper for checking whether the available DDS instance has specific
/// capabilities.
class _DdsCapabilities {
  final int major;
  final int minor;

  static const empty = _DdsCapabilities(major: 0, minor: 0);

  const _DdsCapabilities({required this.major, required this.minor});

  /// Whether the DDS instance supports custom streams via `dart:developer`'s
  /// `postEvent`.
  bool get supportsCustomStreams => _isAtLeast(major: 1, minor: 4);

  bool _isAtLeast({required int major, required int minor}) {
    if (this.major > major) {
      return true;
    } else if (this.major == major && this.minor >= minor) {
      return true;
    } else {
      return false;
    }
  }
}
