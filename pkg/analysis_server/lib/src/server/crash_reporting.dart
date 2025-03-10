// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/exception/exception.dart';
import 'package:analyzer/instrumentation/noop_service.dart';
import 'package:analyzer/instrumentation/plugin_data.dart';
import 'package:analyzer/instrumentation/service.dart';
import 'package:telemetry/crash_reporting.dart';

class CrashReportingInstrumentation extends NoopInstrumentationService {
  // A prod reporter, for analysis server crashes.
  final CrashReportSender serverReporter;

  CrashReportingInstrumentation(this.serverReporter);

  @override
  void logException(
    Object exception, [
    StackTrace? stackTrace,
    List<InstrumentationServiceAttachment>? attachments,
  ]) {
    var crashReportAttachments =
        (attachments ?? []).map((e) {
          return CrashReportAttachment.string(
            field: 'attachment_${e.id}',
            value: e.stringValue,
          );
        }).toList();

    if (exception is CaughtException) {
      // Get the root CaughtException, which matters most for debugging.
      var root = exception.rootCaughtException;
      var message = root.message;
      if (message == null) {
        _sendServerReport(
          root.exception,
          root.stackTrace,
          attachments: crashReportAttachments,
        );
      } else {
        _sendServerReport(
          root.exception,
          root.stackTrace,
          attachments: crashReportAttachments,
          comment: message,
        );
      }
    } else {
      _sendServerReport(
        exception,
        stackTrace ?? StackTrace.current,
        attachments: crashReportAttachments,
      );
    }
  }

  @override
  void logPluginException(
    PluginData plugin,
    Object exception,
    StackTrace? stackTrace,
  ) {
    _sendServerReport(
      exception,
      stackTrace ?? StackTrace.current,
      comment: 'plugin: ${plugin.name}',
    );
  }

  void _sendServerReport(
    Object exception,
    StackTrace stackTrace, {
    String? comment,
    List<CrashReportAttachment>? attachments,
  }) {
    serverReporter
        .sendReport(
          exception,
          stackTrace,
          attachments: attachments ?? const [],
          comment: comment,
        )
        .catchError((error) {
          // We silently ignore errors sending crash reports (network issues, ...).
        });
  }
}
