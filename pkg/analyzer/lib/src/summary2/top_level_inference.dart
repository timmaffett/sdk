// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/scope.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/error/inference_error.dart';
import 'package:analyzer/src/summary2/ast_resolver.dart';
import 'package:analyzer/src/summary2/instance_member_inferrer.dart';
import 'package:analyzer/src/summary2/library_builder.dart';
import 'package:analyzer/src/summary2/link.dart';
import 'package:analyzer/src/summary2/linking_node_scope.dart';
import 'package:analyzer/src/utilities/extensions/element.dart';
import 'package:analyzer/src/utilities/extensions/object.dart';
import 'package:collection/collection.dart';

/// Resolver for typed constant top-level variables and fields initializers.
///
/// Initializers of untyped variables are resolved during [TopLevelInference].
class ConstantInitializersResolver {
  final Linker linker;

  late LibraryBuilder _libraryBuilder;
  late LibraryFragmentImpl _libraryFragment;
  late LibraryElementImpl _library;
  late Scope _scope;

  ConstantInitializersResolver(this.linker);

  void perform() {
    for (var builder in linker.builders.values) {
      _library = builder.element;
      _libraryBuilder = builder;
      for (var libraryFragment in _library.fragments) {
        _libraryFragment = libraryFragment;
        libraryFragment.classes.forEach(_resolveInterfaceFields);
        libraryFragment.enums.forEach(_resolveInterfaceFields);
        libraryFragment.extensions.forEach(_resolveExtensionFields);
        libraryFragment.extensionTypes.forEach(_resolveInterfaceFields);
        libraryFragment.mixins.forEach(_resolveInterfaceFields);

        _scope = libraryFragment.scope;
        libraryFragment.topLevelVariables.forEach(_resolveVariable);
      }
    }
  }

  void _resolveExtensionFields(ExtensionFragmentImpl extension_) {
    var node = linker.getLinkingNode(extension_)!;
    _scope = LinkingNodeContext.get(node).scope;
    extension_.fields.forEach(_resolveVariable);
  }

  void _resolveInterfaceFields(InterfaceFragmentImpl class_) {
    var node = linker.getLinkingNode(class_)!;
    _scope = LinkingNodeContext.get(node).scope;
    class_.fields.forEach(_resolveVariable);
  }

  void _resolveVariable(PropertyInducingFragmentImpl element) {
    if (element is FieldFragmentImpl && element.isEnumConstant) {
      return;
    }

    if (element.constantInitializer == null) return;

    var variable = linker.getLinkingNode(element);
    if (variable is! VariableDeclarationImpl) return;
    if (variable.initializer == null) return;

    var analysisOptions = _libraryBuilder.kind.file.analysisOptions;
    var astResolver = AstResolver(
      linker,
      _libraryFragment,
      _scope,
      analysisOptions,
    );
    astResolver.resolveExpression(
      () => variable.initializer!,
      contextType: element.type,
    );

    // We could have rewritten the initializer.
    element.constantInitializer = variable.initializer;
  }
}

class TopLevelInference {
  final Linker linker;

  TopLevelInference(this.linker);

  void infer() {
    var initializerInference = _InitializerInference(linker);
    initializerInference.createNodes();

    _performOverrideInference();

    initializerInference.perform();
  }

  void _performOverrideInference() {
    var inferrer = InstanceMemberInferrer(linker.inheritance);
    for (var builder in linker.builders.values) {
      for (var unit in builder.element.units) {
        inferrer.inferCompilationUnit(unit);
      }
    }
  }
}

enum _InferenceStatus { notInferred, beingInferred, inferred }

class _InitializerInference {
  final Linker _linker;
  final List<PropertyInducingFragmentImpl> _toInfer = [];
  final List<_PropertyInducingElementTypeInference> _inferring = [];

  late LibraryBuilder _libraryBuilder;
  late LibraryFragmentImpl _unitElement;
  late Scope _scope;

  _InitializerInference(this._linker);

  void createNodes() {
    for (var builder in _linker.builders.values) {
      _libraryBuilder = builder;
      for (var unit in builder.element.units) {
        _unitElement = unit;
        unit.classes.forEach(_addClassElementFields);
        unit.enums.forEach(_addClassElementFields);
        unit.extensions.forEach(_addExtensionElementFields);
        unit.extensionTypes.forEach(_addClassElementFields);
        unit.mixins.forEach(_addClassElementFields);

        _scope = unit.scope;
        unit.topLevelVariables.forEach(_addVariableNode);
      }
    }
  }

  /// Perform type inference for variables for which it was not done yet.
  void perform() {
    for (var element in _toInfer) {
      // Will perform inference, if not done yet.
      element.type;
    }
  }

  void _addClassElementFields(InterfaceFragmentImpl class_) {
    var node = _linker.getLinkingNode(class_)!;
    _scope = LinkingNodeContext.get(node).scope;
    class_.fields.forEach(_addVariableNode);
  }

  void _addExtensionElementFields(ExtensionFragmentImpl extension_) {
    var node = _linker.getLinkingNode(extension_)!;
    _scope = LinkingNodeContext.get(node).scope;
    extension_.fields.forEach(_addVariableNode);
  }

  void _addVariableNode(PropertyInducingFragmentImpl element) {
    if (element.isSynthetic &&
        !(element is FieldFragmentImpl && element.isSyntheticEnumField)) {
      return;
    }

    if (!element.hasImplicitType) return;

    _toInfer.add(element);

    var node = _linker.getLinkingNode(element) as VariableDeclarationImpl;
    element.typeInference = _PropertyInducingElementTypeInference(
      _linker,
      _inferring,
      _unitElement,
      _scope,
      element,
      node,
      _libraryBuilder,
    );
  }
}

class _PropertyInducingElementTypeInference
    implements PropertyInducingElementTypeInference {
  final Linker _linker;

  /// The stack of objects performing inference now. A new object is pushed
  /// when we start resolving the initializer, and popped when we are done.
  final List<_PropertyInducingElementTypeInference> _inferring;

  /// The status is used to identify a cycle, when we are asked to infer the
  /// type, but the status is already [_InferenceStatus.beingInferred].
  _InferenceStatus _status = _InferenceStatus.notInferred;

  final LibraryBuilder _libraryBuilder;
  final LibraryFragmentImpl _unitElement;
  final Scope _scope;
  final PropertyInducingFragmentImpl _element;
  final VariableDeclarationImpl _node;

  _PropertyInducingElementTypeInference(
    this._linker,
    this._inferring,
    this._unitElement,
    this._scope,
    this._element,
    this._node,
    this._libraryBuilder,
  );

  @override
  TypeImpl perform() {
    if (_node.initializer == null) {
      _status = _InferenceStatus.inferred;
      return DynamicTypeImpl.instance;
    }

    // With this status the type must be already set.
    // So, the element knows the type, ans should not call the inferrer.
    if (_status == _InferenceStatus.inferred) {
      assert(false, 'Should not happen: $_element');
      return DynamicTypeImpl.instance;
    }

    // If we are already inferring this element, we found a cycle.
    if (_status == _InferenceStatus.beingInferred) {
      var startIndex = _inferring.indexOf(this);
      var cycle = _inferring.slice(startIndex);
      var inferenceError = TopLevelInferenceError(
        kind: TopLevelInferenceErrorKind.dependencyCycle,
        arguments: cycle.map((e) => e._element.name2 ?? '').sorted(),
      );
      for (var inference in cycle) {
        if (inference._status == _InferenceStatus.beingInferred) {
          var element = inference._element;
          element.typeInferenceError = inferenceError;
          element.type = DynamicTypeImpl.instance;
          inference._status = _InferenceStatus.inferred;
        }
      }
      return DynamicTypeImpl.instance;
    }

    assert(_status == _InferenceStatus.notInferred);

    // Push self into the stack, and mark.
    _inferring.add(this);
    _status = _InferenceStatus.beingInferred;

    var enclosingElement = _element.enclosingElement3;
    var enclosingInterfaceElement =
        enclosingElement.ifTypeOrNull<InterfaceFragmentImpl>()?.asElement2;

    var analysisOptions = _libraryBuilder.kind.file.analysisOptions;
    var astResolver = AstResolver(
      _linker,
      _unitElement,
      _scope,
      analysisOptions,
      enclosingClassElement: enclosingInterfaceElement,
    );
    astResolver.resolveExpression(() => _node.initializer!);

    // Pop self from the stack.
    var self = _inferring.removeLast();
    assert(identical(self, this));

    // We might have found a cycle, and already set the type.
    // Anyway, we are done.
    if (_status == _InferenceStatus.inferred) {
      return _element.type;
    } else {
      _status = _InferenceStatus.inferred;
    }

    var initializerType = _node.initializer!.typeOrThrow;
    return _refineType(initializerType);
  }

  TypeImpl _refineType(TypeImpl type) {
    if (type.isDartCoreNull) {
      return DynamicTypeImpl.instance;
    }

    return type;
  }
}
