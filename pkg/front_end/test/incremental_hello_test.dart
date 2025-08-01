// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/async_helper.dart' show asyncTest;
import 'package:expect/expect.dart' show Expect;
import "package:front_end/src/api_prototype/compiler_options.dart"
    show CompilerOptions, DiagnosticMessage;
import 'package:front_end/src/api_prototype/incremental_kernel_generator.dart'
    show IncrementalCompilerResult;
import 'package:front_end/src/base/compiler_context.dart' show CompilerContext;
import 'package:front_end/src/base/incremental_compiler.dart'
    show IncrementalCompiler;
import 'package:front_end/src/base/processed_options.dart'
    show ProcessedOptions;
import 'package:front_end/src/compute_platform_binaries_location.dart'
    show computePlatformBinariesLocation;
import 'package:kernel/ast.dart' show Component;
import 'package:kernel/target/targets.dart' show TargetFlags;
import 'package:vm/modular/target/vm.dart' show VmTarget;

void diagnosticMessageHandler(DiagnosticMessage message) {
  throw "Unexpected message: ${message.plainTextFormatted.join('\n')}";
}

Future<void> test({required bool sdkFromSource}) async {
  final CompilerOptions optionBuilder = new CompilerOptions()
    ..packagesFileUri = Uri.base.resolve(".dart_tool/package_config.json")
    ..target = new VmTarget(new TargetFlags())
    ..omitPlatform = true
    ..onDiagnostic = diagnosticMessageHandler
    ..environmentDefines = const {};

  if (sdkFromSource) {
    optionBuilder.librariesSpecificationUri =
        Uri.base.resolve("sdk/lib/libraries.json");
  } else {
    optionBuilder.sdkSummary =
        computePlatformBinariesLocation(forceBuildDir: true)
            .resolve("vm_platform.dill");
  }

  final Uri helloDart =
      Uri.base.resolve("pkg/front_end/testcases/general/hello.dart");

  final ProcessedOptions options =
      new ProcessedOptions(options: optionBuilder, inputs: [helloDart]);

  IncrementalCompiler compiler =
      new IncrementalCompiler(new CompilerContext(options));

  IncrementalCompilerResult compilerResult = await compiler.computeDelta();
  Component component = compilerResult.component;

  if (sdkFromSource) {
    // Expect that the new component contains at least the following libraries:
    // dart:core, dart:async, and hello.dart.
    Expect.isTrue(
        component.libraries.length > 2, "${component.libraries.length} <= 2");
  } else {
    // Expect that the new component contains exactly hello.dart.
    Expect.isTrue(
        component.libraries.length == 1, "${component.libraries.length} != 1");
  }

  compiler.invalidate(helloDart);

  compilerResult = await compiler.computeDelta(entryPoints: [helloDart]);
  component = compilerResult.component;
  // Expect that the new component contains exactly hello.dart
  Expect.isTrue(
      component.libraries.length == 1, "${component.libraries.length} != 1");

  compilerResult = await compiler.computeDelta(entryPoints: [helloDart]);
  component = compilerResult.component;
  Expect.isTrue(component.libraries.isEmpty);
}

void main() {
  asyncTest(() async {
    await test(sdkFromSource: true);
    await test(sdkFromSource: false);
  });
}
