// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/src/correction/fix_generators.dart';
import 'package:analyzer/error/error.dart';

import 'parse_utils.dart';

/// Print diagnostic bulk-fix info.
Future<void> main() async {
  var overrideDetails = await BulkFixDetails().collectOverrides();

  print('diagnostics w/ correction producers:\n');

  var hintEntries = registeredFixGenerators.nonLintProducers.entries.where(
    (e) =>
        e.key.type == DiagnosticType.HINT ||
        e.key.type == DiagnosticType.STATIC_WARNING,
  );

  var diagnostics = [
    ...hintEntries,
    ...registeredFixGenerators.lintProducers.entries,
  ];
  for (var diagnostic in diagnostics) {
    var canBeAppliedInBulk = false;
    var missingExplanations = <String>[];
    var hasOverride = false;
    for (var generator in diagnostic.value) {
      var producer = generator(context: StubCorrectionProducerContext.instance);
      if (!producer.canBeAppliedAcrossFiles) {
        var producerName = producer.runtimeType.toString();
        if (overrideDetails.containsKey(producerName)) {
          hasOverride = true;
          var override = overrideDetails[producerName];
          var hasComment = override!.hasComment;
          if (!hasComment) {
            missingExplanations.add(producerName);
          }
        }
      } else {
        canBeAppliedInBulk = true;
      }
    }

    print('${diagnostic.key} bulk fixable: $canBeAppliedInBulk');
    if (!canBeAppliedInBulk && !hasOverride) {
      print('  => override missing');
    }
    for (var producer in missingExplanations) {
      print('  => override explanation missing for: $producer');
    }
  }
}
