// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer_utilities/tools.dart';

import 'api.dart';
import 'codegen_dart_protocol.dart';
import 'from_html.dart';
import 'implied_types.dart';

GeneratedFile clientTarget(bool responseRequiresRequestTime,
        CodegenUriConverterKind uriConverterKind) =>
    GeneratedFile(
        'analysis_server_client/lib/src/protocol/protocol_common.dart',
        (pkgRoot) async {
      var visitor = CodegenCommonVisitor('analyzer_plugin',
          responseRequiresRequestTime, uriConverterKind, readApi(pkgRoot),
          forClient: true);
      return visitor.collectCode(visitor.visitApi);
    });

GeneratedFile pluginTarget(bool responseRequiresRequestTime,
        CodegenUriConverterKind uriConverterKind) =>
    GeneratedFile('analyzer_plugin/lib/protocol/protocol_common.dart',
        (pkgRoot) async {
      var visitor = CodegenCommonVisitor('analyzer_plugin',
          responseRequiresRequestTime, uriConverterKind, readApi(pkgRoot));
      return visitor.collectCode(visitor.visitApi);
    });

/// A visitor that produces Dart code defining the common types associated with
/// the API.
class CodegenCommonVisitor extends CodegenProtocolVisitor {
  final bool forClient;

  /// Initialize a newly created visitor to generate code in the package with
  /// the given [packageName] corresponding to the types in the given [api] that
  /// are common to multiple protocols.
  CodegenCommonVisitor(super.packageName, super.responseRequiresRequestTime,
      super.uriConverterKind, super.api,
      {this.forClient = false});

  @override
  void emitImports() {
    writeln("import 'dart:convert' hide JsonDecoder;");
    writeln();
    writeln("import 'package:collection/collection.dart' show QueueList;");
    writeln();
    if (forClient) {
      writeln(
          "import 'package:analysis_server_client/src/protocol/protocol_internal.dart';");
    } else {
      writeln(
          "import 'package:$packageName/src/protocol/protocol_internal.dart';");
      writeln(
          "import 'package:$packageName/src/utilities/client_uri_converter.dart';");
    }
    writeln();
    writeln('// ignore_for_file: flutter_style_todos');
  }

  @override
  List<ImpliedType> getClassesToEmit() {
    var types = impliedTypes.values.where((ImpliedType type) {
      var node = type.apiNode;
      return node is TypeDefinition && node.isExternal;
    }).toList();
    types.sort((first, second) =>
        capitalize(first.camelName).compareTo(capitalize(second.camelName)));
    return types;
  }
}
