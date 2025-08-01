// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/code_template.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/element_descriptor.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/element_matcher.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform_set.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform_set_manager.dart';
import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:meta/meta.dart';

class DataDriven extends MultiCorrectionProducer {
  /// The transform sets used by the current test.
  @visibleForTesting
  static List<TransformSet>? transformSetsForTests;

  DataDriven({required super.context});

  @override
  Future<List<ResolvedCorrectionProducer>> get producers async {
    var importedUris = <Uri>[];
    var library = unitResult.libraryElement;
    var fragment = library.firstFragment;
    for (var importElement in fragment.libraryImports) {
      // TODO(brianwilkerson): Filter based on combinators to help avoid making
      //  invalid suggestions.
      var uri = importElement.uri;
      if (uri is DirectiveUriWithRelativeUri) {
        // The [uri] is `null` if the literal string is not a valid URI.
        importedUris.add(uri.relativeUri);
      }
    }
    var matchers = ElementMatcher.matchersForNode(node, token);
    if (matchers.isEmpty) {
      // The node doesn't represent any element that can be transformed.
      return const [];
    }
    var transformSet = <Transform>{};
    for (var set in _availableTransformSetsForLibrary(library)) {
      for (var matcher in matchers) {
        for (var transform in set.transformsFor(
          matcher,
          applyingBulkFixes: applyingBulkFixes,
        )) {
          transformSet.add(transform);
        }
      }
    }
    return transformSet
        .map((transform) => DataDrivenFix(transform, context: context))
        .toList();
  }

  /// Return the transform sets that are available for fixing issues in the
  /// given [library].
  List<TransformSet> _availableTransformSetsForLibrary(LibraryElement library) {
    var setsForTests = transformSetsForTests;
    if (setsForTests != null) {
      return setsForTests;
    }
    return TransformSetManager.instance.forLibrary(library);
  }
}

/// A correction processor that can make one of the possible changes computed by
/// the [DataDriven] producer.
class DataDrivenFix extends ResolvedCorrectionProducer {
  /// The transform being applied to implement this fix.
  final Transform _transform;

  DataDrivenFix(this._transform, {required super.context});

  @override
  CorrectionApplicability get applicability =>
      // TODO(applicability): comment on why.
      CorrectionApplicability.singleLocation;

  /// Return a description of the element that was changed.
  ElementDescriptor get element => _transform.element;

  @override
  List<String> get fixArguments => [_transform.title];

  @override
  FixKind get fixKind => DartFixKind.DATA_DRIVEN;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    var changes = _transform.changesSelector.getChanges(
      TemplateContext.forInvocation(node, utils),
    );
    if (changes == null) {
      return;
    }
    var data = <Object>[];
    for (var change in changes) {
      var result = change.validate(this);
      if (result == null) {
        return;
      }
      data.add(result);
    }
    await builder.addDartFileEdit(file, (builder) {
      for (var i = 0; i < changes.length; i++) {
        changes[i].apply(builder, this, data[i]);
      }
    });
  }
}
