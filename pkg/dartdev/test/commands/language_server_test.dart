// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../utils.dart' as utils;

void main() {
  utils.ensureRunFromSdkBinDart();

  group(
    'language-server',
    defineLanguageServerTests,
    timeout: utils.longTimeout,
  );
}

void defineLanguageServerTests() {
  late utils.TestProject project;
  Process? process;

  setUp(() {
    project = utils.project();
  });

  Future<void> runWithLsp(List<String> args) async {
    process = await project.start(args);

    // Send an LSP init.
    final String message = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'processId': pid,
        'clientInfo': {'name': 'dart-cli-tester'},
        'capabilities': {},
        'rootUri': project.dir.uri.toString(),
      },
    });

    // If we get stderr output (for example because we passed invalid args)
    // then throw rather than waiting forever on stdout content that will never
    // arrive.
    process!.stderr.transform(utf8.decoder).listen((data) {
      throw data.toString();
    });

    process!.stdin.write('Content-Length: ${message.length}\r\n');
    process!.stdin.write('\r\n');
    process!.stdin.write(message);

    // Expect
    final response = await _readLspMessage(process!.stdout);

    final json = jsonDecode(response);
    expect(json['id'], 1);
    expect(json['result'], isNotNull);
    final result = json['result'];
    expect(result['capabilities'], isNotNull);
    expect(result['serverInfo'], isNotNull);
    final serverInfo = result['serverInfo'];
    expect(serverInfo['name'], isNotEmpty);

    process!.kill();
    process = null;
  }

  Future<void> runWithLegacy(List<String> args) async {
    process = await project.start(args);

    final Stream<String> inStream = process!.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter());

    final line = await inStream.first;
    final json = jsonDecode(line);

    expect(json['event'], 'server.connected');
    expect(json['params'], isNotNull);
    final params = json['params'];
    expect(params['version'], isNotEmpty);
    expect(params['pid'], isNot(0));

    process!.kill();
    process = null;
  }

  test('protocol default', () async {
    return runWithLsp(['language-server']);
  });

  test('protocol default with --protocol-log-file', () async {
    // https://github.com/dart-lang/sdk/issues/52501
    final logFile = path.join(project.dir.path, 'log.txt');
    return runWithLsp(['language-server', '--protocol-traffic-log=$logFile']);
  });

  test('--protocol=lsp', () async {
    return runWithLsp(['language-server', '--protocol=lsp']);
  });

  test('--protocol lsp', () async {
    return runWithLsp(['language-server', '--protocol', 'lsp']);
  });

  test('--use-aot-snapshot', () async {
    return runWithLsp(['language-server', '--use-aot-snapshot']);
  });

  test('--use-aot-snapshot --enable-experiment=foo', () async {
    return runWithLsp([
      'language-server',
      '--use-aot-snapshot',
      '--enable-experiment=foo',
    ]);
  });

  test('--no-use-aot-snapshot', () async {
    return runWithLsp(['language-server', '--no-use-aot-snapshot']);
  });

  test('--no-use-aot-snapshot --enable-experiment=foo', () async {
    return runWithLsp([
      'language-server',
      '--no-use-aot-snapshot',
      '--enable-experiment=foo',
    ]);
  });

  test('--protocol=analyzer', () async {
    await runWithLegacy(['language-server', '--protocol=analyzer']);
  });

  test('--protocol analyzer', () async {
    await runWithLegacy(['language-server', '--protocol', 'analyzer']);
  });
}

/// Reads the first LSP message from [stream].
Future<String> _readLspMessage(Stream<List<int>> stream) {
  // Headers are complete if there are 2x '\r\n\'. The '\r' is part of the LSP
  // spec for headers and included on all platforms, not just Windows.
  const lspHeaderBodySeparator = '\r\n\r\n';
  final contentLengthRegExp = RegExp(r'Content-Length: (\d+)\r\n');

  final completer = Completer<String>();
  final buffer = StringBuffer();
  late final StreamSubscription<String> inSubscription;
  inSubscription = stream.transform<String>(utf8.decoder).listen(
    (data) {
      // Collect the output into the buffer.
      buffer.write(data);

      // Check whether the buffer has a complete message.
      final bufferString = buffer.toString();

      // If the buffer has what looks like the legacy banner, then just fail
      // because we will never get an LSP message.
      if (bufferString.contains('"event":"server.connected"')) {
        completer.completeError(
            'Expected LSP message but got legacy message: $bufferString');
      }

      // To know if we have a complete message, we need to check we have the
      // headers, extract the content-length, then check we have that many
      // bytes in the body.
      if (bufferString.contains(lspHeaderBodySeparator)) {
        final parts = bufferString.split(lspHeaderBodySeparator);
        final headers = parts[0];
        final body = parts[1];
        final length =
            int.parse(contentLengthRegExp.firstMatch(headers)!.group(1)!);
        // Check if we're already had the full payload.
        if (body.length >= length) {
          completer.complete(body.substring(0, length));
          inSubscription.cancel();
        }
      }
    },
  );

  return completer.future;
}
