// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library;

import 'package:js_runtime/synced/array_flags.dart';
import 'package:js_runtime/synced/embedded_names.dart' as embedded_names;

import '../common/elements.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/types.dart' show InterfaceType;
import '../js/js.dart' as js_ast;
import '../js/js.dart' show js;
import '../js_backend/namer.dart' show Namer;
import '../js_backend/custom_elements_analysis.dart'
    show CustomElementsCodegenAnalysis;
import '../js_backend/native_data.dart';
import '../js_backend/interceptor_data.dart';
import '../js_model/js_world.dart' show JClosedWorld;
import '../native/enqueue.dart';
import '../universe/codegen_world_builder.dart';
import '../universe/selector.dart' show Selector;

import 'js_emitter.dart' show Emitter;

class InterceptorStubGenerator {
  final CommonElements _commonElements;
  final Emitter _emitter;
  final NativeCodegenEnqueuer _nativeCodegenEnqueuer;
  final Namer _namer;
  final CustomElementsCodegenAnalysis _customElementsCodegenAnalysis;
  final CodegenWorld _codegenWorld;
  final JClosedWorld _closedWorld;

  InterceptorStubGenerator(
    this._commonElements,
    this._emitter,
    this._nativeCodegenEnqueuer,
    this._namer,
    this._customElementsCodegenAnalysis,
    this._codegenWorld,
    this._closedWorld,
  );

  NativeData get _nativeData => _closedWorld.nativeData;

  InterceptorData get _interceptorData => _closedWorld.interceptorData;

  js_ast.Expression generateGetInterceptorMethod(
    SpecializedGetInterceptor interceptor,
  ) {
    Set<ClassEntity> classes = interceptor.classes;

    js_ast.Expression interceptorFor(ClassEntity cls) {
      return _emitter.interceptorPrototypeAccess(cls);
    }

    /// Build a JavaScript AST node for doing a type check on
    /// [cls]. [cls] must be a non-native interceptor class.
    js_ast.Statement buildInterceptorCheck(ClassEntity cls) {
      js_ast.Expression condition;
      assert(_interceptorData.isInterceptedClass(cls));
      if (cls == _commonElements.jsBoolClass) {
        condition = js('(typeof receiver) == "boolean"');
      } else if (cls == _commonElements.jsIntClass ||
          cls == _commonElements.jsNumNotIntClass ||
          cls == _commonElements.jsNumberClass) {
        throw 'internal error';
      } else if (cls == _commonElements.jsArrayClass ||
          cls == _commonElements.jsMutableArrayClass ||
          cls == _commonElements.jsFixedArrayClass ||
          cls == _commonElements.jsExtendableArrayClass) {
        condition = js('Array.isArray(receiver)');
      } else if (cls == _commonElements.jsStringClass) {
        condition = js('(typeof receiver) == "string"');
      } else if (cls == _commonElements.jsNullClass) {
        condition = js('receiver == null');
      } else if (cls == _commonElements.jsJavaScriptBigIntClass) {
        condition = js('(typeof receiver) == "bigint"');
      } else if (cls == _commonElements.jsJavaScriptFunctionClass) {
        condition = js('(typeof receiver) == "function"');
      } else if (cls == _commonElements.jsJavaScriptSymbolClass) {
        condition = js('(typeof receiver) == "symbol"');
      } else {
        throw 'internal error';
      }
      return js.statement('if (#) return #', [condition, interceptorFor(cls)]);
    }

    bool hasArray = false;
    bool hasBool = false;
    bool hasNumNotInt = false;
    bool hasInt = false;
    bool hasNull = false;
    bool hasNumber = false;
    bool hasString = false;
    bool hasNative = false;
    bool anyNativeClasses = _nativeCodegenEnqueuer.hasInstantiatedNativeClasses;
    bool hasJavaScriptFunction = false;
    bool hasJavaScriptBigInt = false;
    bool hasJavaScriptObject = false;
    bool hasJavaScriptSymbol = false;

    for (ClassEntity cls in classes) {
      if (cls == _commonElements.jsArrayClass ||
          cls == _commonElements.jsMutableArrayClass ||
          cls == _commonElements.jsFixedArrayClass ||
          cls == _commonElements.jsExtendableArrayClass) {
        hasArray = true;
      } else if (cls == _commonElements.jsBoolClass) {
        hasBool = true;
      } else if (cls == _commonElements.jsNumNotIntClass) {
        hasNumNotInt = true;
      } else if (cls == _commonElements.jsIntClass) {
        hasInt = true;
      } else if (cls == _commonElements.jsNullClass) {
        hasNull = true;
      } else if (cls == _commonElements.jsNumberClass) {
        hasNumber = true;
      } else if (cls == _commonElements.jsStringClass) {
        hasString = true;
      } else if (cls == _commonElements.jsJavaScriptBigIntClass) {
        hasJavaScriptBigInt = true;
      } else if (cls == _commonElements.jsJavaScriptFunctionClass) {
        hasJavaScriptFunction = true;
      } else if (cls == _commonElements.jsJavaScriptSymbolClass) {
        hasJavaScriptSymbol = true;
      } else if (cls == _commonElements.jsJavaScriptObjectClass) {
        hasJavaScriptObject = true;
      } else {
        // The set of classes includes classes mixed-in to interceptor classes
        // and user extensions of native classes.
        //
        // The set of classes also includes the 'primitive' interceptor
        // PlainJavaScriptObject even when it has not been resolved, since it is
        // only resolved through the reference in getNativeInterceptor when
        // getNativeInterceptor is marked as used.  Guard against probing
        // unresolved PlainJavaScriptObject by testing for anyNativeClasses.

        if (anyNativeClasses) {
          if (_nativeData.isNativeOrExtendsNative(cls)) hasNative = true;
        }
      }
    }
    if (hasNumNotInt) {
      hasNumber = true;
    }
    if (hasInt) hasNumber = true;

    if (classes.containsAll(_interceptorData.interceptedClasses)) {
      // I.e. this is the general interceptor.
      hasNative = anyNativeClasses;
    }

    List<js_ast.Statement> statements = [];

    if (hasNumber) {
      js_ast.Statement whenNumber;

      if (hasInt) {
        whenNumber = js.statement(
          '''{
            if (Math.floor(receiver) == receiver) return #;
            return #;
        }''',
          [
            interceptorFor(_commonElements.jsIntClass),
            interceptorFor(_commonElements.jsNumNotIntClass),
          ],
        );
      } else {
        // If we don't have methods defined on the JSInt interceptor, use the
        // JSNumber interceptor, unless we have a method defined only for
        // non-integral values.
        js_ast.Expression interceptorForNumber = interceptorFor(
          hasNumNotInt
              ? _commonElements.jsNumNotIntClass
              : _commonElements.jsNumberClass,
        );

        whenNumber = js.statement('return #', interceptorForNumber);
      }
      statements.add(
        js.statement('if (typeof receiver == "number") #;', whenNumber),
      );
    }

    if (hasString) {
      statements.add(buildInterceptorCheck(_commonElements.jsStringClass));
    }
    if (hasNull) {
      statements.add(buildInterceptorCheck(_commonElements.jsNullClass));
    } else {
      // Returning "undefined" or "null" here will provoke a JavaScript
      // TypeError which is later identified as a null-error by
      // [unwrapException] in js_helper.dart.
      statements.add(js.statement('if (receiver == null) return receiver'));
    }
    if (hasBool) {
      statements.add(buildInterceptorCheck(_commonElements.jsBoolClass));
    }
    // TODO(ahe): It might be faster to check for Array before
    // function and bool.
    if (hasArray) {
      statements.add(buildInterceptorCheck(_commonElements.jsArrayClass));
    }

    // If a program `hasNative` then we will insert a check for
    // `JavaScriptFunction` in the `hasNative` block of the interceptor logic.
    // Otherwise, we have to insert a specific check for `JavaScriptFunction.
    if (!hasNative) {
      if (hasJavaScriptFunction) {
        statements.add(
          buildInterceptorCheck(_commonElements.jsJavaScriptFunctionClass),
        );
      }
      if (hasJavaScriptSymbol) {
        statements.add(
          buildInterceptorCheck(_commonElements.jsJavaScriptSymbolClass),
        );
      }
      if (hasJavaScriptBigInt) {
        statements.add(
          buildInterceptorCheck(_commonElements.jsJavaScriptBigIntClass),
        );
      }
    }

    if (hasJavaScriptObject && !hasNative) {
      statements.add(
        js.statement(
          r'''
          if (typeof receiver == "object") {
            if (receiver instanceof #) {
              return receiver;
            } else {
              return #;
            }
          }
      ''',
          [
            _emitter.constructorAccess(_commonElements.objectClass),
            interceptorFor(_commonElements.jsJavaScriptObjectClass),
          ],
        ),
      );
    }

    if (hasNative) {
      statements.add(
        js.statement(
          r'''{
          if (typeof receiver != "object") {
              if (typeof receiver == "function" ) return #;
              if (typeof receiver == "symbol" ) return #;
              if (typeof receiver == "bigint" ) return #;
              return receiver;
          }
          if (receiver instanceof #) return receiver;
          return #(receiver);
      }''',
          [
            interceptorFor(_commonElements.jsJavaScriptFunctionClass),
            interceptorFor(_commonElements.jsJavaScriptSymbolClass),
            interceptorFor(_commonElements.jsJavaScriptBigIntClass),
            _emitter.constructorAccess(_commonElements.objectClass),
            _emitter.staticFunctionAccess(
              _commonElements.getNativeInterceptorMethod,
            ),
          ],
        ),
      );
    } else {
      ClassEntity jsUnknown = _commonElements.jsUnknownJavaScriptObjectClass;
      if (_codegenWorld.directlyInstantiatedClasses.contains(jsUnknown)) {
        statements.add(
          js.statement('if (!(receiver instanceof #)) return #;', [
            _emitter.constructorAccess(_commonElements.objectClass),
            interceptorFor(jsUnknown),
          ]),
        );
      }

      statements.add(js.statement('return receiver'));
    }

    return js('''function(receiver) { #; }''', js_ast.Block(statements));
  }

  js_ast.Call _generateIsJsIndexableCall(
    js_ast.Expression use1,
    js_ast.Expression use2,
  ) {
    String dispatchPropertyName = embedded_names.DISPATCH_PROPERTY_NAME;
    js_ast.Expression dispatchProperty = _emitter.generateEmbeddedGlobalAccess(
      dispatchPropertyName,
    );

    // We pass the dispatch property record to the isJsIndexable
    // helper rather than reading it inside the helper to increase the
    // chance of making the dispatch record access monomorphic.
    js_ast.PropertyAccess record = js_ast.PropertyAccess(
      use2,
      dispatchProperty,
    );

    List<js_ast.Expression> arguments = [use1, record];
    FunctionEntity helper = _commonElements.isJsIndexable;
    js_ast.Expression helperExpression = _emitter.staticFunctionAccess(helper);
    return js_ast.Call(helperExpression, arguments);
  }

  // Returns a statement that takes care of performance critical
  // common case for a one-shot interceptor, or null if there is no
  // fast path.
  js_ast.Statement? _fastPathForOneShotInterceptor(
    Selector selector,
    Set<ClassEntity> classes,
  ) {
    if (selector.isOperator) {
      String name = selector.name;
      if (name == '==') {
        return js.statement('''{
          if (receiver == null) return a0 == null;
          if (typeof receiver != "object")
            return a0 != null && receiver === a0;
        }''');
      }
      if (!classes.contains(_commonElements.jsIntClass) &&
          !classes.contains(_commonElements.jsNumberClass) &&
          !classes.contains(_commonElements.jsNumNotIntClass)) {
        return null;
      }
      if (selector.argumentCount == 1) {
        // The following operators do not map to a JavaScript operator.
        if (name == '~/' || name == '<<' || name == '%' || name == '>>') {
          return null;
        }
        js_ast.Expression result = js('receiver $name a0');
        if (name == '&' || name == '|' || name == '^') {
          result = js('# >>> 0', result);
        }
        return js.statement(
          'if (typeof receiver == "number" && typeof a0 == "number")'
          '  return #;',
          result,
        );
      } else if (name == 'unary-') {
        return js.statement(
          'if (typeof receiver == "number") return -receiver',
        );
      } else {
        assert(name == '~');
        return js.statement('''
          if (typeof receiver == "number" && Math.floor(receiver) == receiver)
            return (~receiver) >>> 0;
          ''');
      }
    } else if (selector.isIndex || selector.isIndexSet) {
      // For an index operation, this code generates:
      //
      //    if (typeof a0 === "number") {
      //      if (Array.isArray(receiver) || typeof receiver == "string") {
      //        if (a0 >>> 0 === a0 && a0 < receiver.length) {
      //          return receiver[a0];
      //        }
      //      }
      //    }
      //
      // For an index set operation, this code generates:
      //
      //    if (typeof a0 === "number") {
      //      if (Array.isArray(receiver) && !receiver.immutable$list) {
      //        if (a0 >>> 0 === a0 && a0 < receiver.length) {
      //          return receiver[a0] = a1;
      //        }
      //      }
      //    }
      bool containsArray = classes.contains(_commonElements.jsArrayClass);
      bool containsString = classes.contains(_commonElements.jsStringClass);
      bool containsJsIndexable =
          _closedWorld.isImplemented(
            _commonElements.jsIndexingBehaviorInterface,
          ) &&
          classes.any((cls) {
            return _closedWorld.classHierarchy.isSubtypeOf(
              cls,
              _commonElements.jsIndexingBehaviorInterface,
            );
          });
      // The index set operator requires a check on its set value in
      // checked mode, so we don't optimize the interceptor if the
      // _compiler has type assertions enabled.
      if (selector.isIndexSet &&
          // TODO(johnniwinther): Support annotations on the possible targets
          // and used their parameter check policy here.
          (_closedWorld.annotationsData
                  .getParameterCheckPolicy(null)
                  .isEmitted ||
              !containsArray)) {
        return null;
      }
      if (!containsArray && !containsString) {
        return null;
      }
      js_ast.Expression arrayCheck = js('Array.isArray(receiver)');

      // Lazy generation of the indexable check. If indexable behavior isn't
      // used, the isJsIndexable function isn't part of the closed world.
      js_ast.Expression genericIndexableCheck() =>
          _generateIsJsIndexableCall(js('receiver'), js('receiver'));

      js_ast.Expression orExp(
        js_ast.Expression? left,
        js_ast.Expression right,
      ) {
        return left == null ? right : js('# || #', [left, right]);
      }

      if (selector.isIndex) {
        js_ast.Expression? typeCheck;
        if (containsArray) {
          typeCheck = arrayCheck;
        }

        if (containsString) {
          typeCheck = orExp(typeCheck, js('typeof receiver == "string"'));
        }

        if (containsJsIndexable) {
          typeCheck = orExp(typeCheck, genericIndexableCheck());
        }

        return js.statement('''
          if (typeof a0 === "number")
            if (#)
              if ((a0 >>> 0) === a0 && a0 < receiver.length)
                return receiver[a0];
          ''', typeCheck);
      } else {
        js_ast.Expression? typeCheck;
        if (containsArray) {
          typeCheck = arrayCheck;
        }

        if (containsJsIndexable) {
          typeCheck = orExp(typeCheck, genericIndexableCheck());
        }

        return js.statement(
          r'''
          if (typeof a0 === "number")
            if (# && !(receiver.# & #) &&
                (a0 >>> 0) === a0 && a0 < receiver.length)
              return receiver[a0] = a1;
          ''',
          [
            typeCheck,
            _namer.fixedNames.arrayFlagsPropertyName,
            js.number(ArrayFlags.unmodifiableCheck),
          ],
        );
      }
    } else if (selector.isCall) {
      if (selector.name == 'abs' && selector.argumentCount == 0) {
        return js.statement(r'''
          if (typeof receiver === "number") return Math.abs(receiver);
        ''');
      }
    } else if (selector.isGetter) {
      if (selector.name == 'sign') {
        return js.statement(r'''
          if (typeof receiver === "number")
             return receiver > 0 ? 1 : receiver < 0 ? -1 : receiver;
        ''');
      }
    }
    return null;
  }

  js_ast.Expression generateOneShotInterceptor(OneShotInterceptor interceptor) {
    Selector selector = interceptor.selector;
    Set<ClassEntity> classes = interceptor.classes;
    js_ast.Name getInterceptorName = _namer.nameForGetInterceptor(classes);

    List<String> parameterNames = [];
    parameterNames.add('receiver');

    if (selector.isSetter) {
      parameterNames.add('value');
    } else {
      for (int i = 0; i < selector.argumentCount; i++) {
        parameterNames.add('a$i');
      }
      for (int i = 1; i <= selector.typeArgumentCount; i++) {
        parameterNames.add('\$T$i');
      }
    }

    js_ast.Name invocationName = _namer.invocationName(selector);
    var globalObject = _namer.readGlobalObjectForInterceptors();

    js_ast.Statement? optimizedPath = _fastPathForOneShotInterceptor(
      selector,
      classes,
    );
    optimizedPath ??= js.statement(';');

    return js('function(#) { #; return #.#(receiver).#(#) }', [
      parameterNames,
      optimizedPath,
      globalObject,
      getInterceptorName,
      invocationName,
      parameterNames,
    ]);
  }

  js_ast.ArrayInitializer? generateTypeToInterceptorMap() {
    // TODO(sra): Perhaps inject a constant instead?
    CustomElementsCodegenAnalysis analysis = _customElementsCodegenAnalysis;
    if (!analysis.needsTable) return null;

    List<js_ast.Expression> elements = [];
    Iterable<ConstantValue> constants = _codegenWorld.getConstantsForEmission(
      _emitter.compareConstants,
    );
    for (ConstantValue constant in constants) {
      if (constant is TypeConstantValue &&
          constant.representedType is InterfaceType) {
        InterfaceType type = constant.representedType as InterfaceType;
        ClassEntity classElement = type.element;
        if (!analysis.needsClass(classElement)) continue;

        elements.add(_emitter.constantReference(constant));
        elements.add(_emitter.interceptorClassAccess(classElement));

        // Create JavaScript Object map for by-name lookup of generative
        // constructors.  For example, the class A has three generative
        // constructors
        //
        //     class A {
        //       A() {}
        //       A.foo() {}
        //       A.bar() {}
        //     }
        //
        // Which are described by the map
        //
        //     {"": A.A$, "foo": A.A$foo, "bar": A.A$bar}
        //
        // We expect most of the time the map will be a singleton.
        var properties = <js_ast.Property>[];
        for (ConstructorEntity member in analysis.constructors(classElement)) {
          properties.add(
            js_ast.Property(
              js.string(member.name!),
              _emitter.staticFunctionAccess(member),
            ),
          );
        }

        var map = js_ast.ObjectInitializer(properties);
        elements.add(map);
      }
    }

    return js_ast.ArrayInitializer(elements);
  }
}
