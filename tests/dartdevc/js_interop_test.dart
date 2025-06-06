// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@JS()
library js_interop_test;

import 'dart:_foreign_helper' as helper show JS;
import 'dart:_interceptors' as interceptors;
import 'dart:_runtime' as dart;
import 'dart:js' show context;

import 'package:expect/expect.dart';
import 'package:js/js.dart';

@JS()
class Console {
  @JS()
  external void log(arg);
}

@JS('console')
external Console get console;

@JS('console.log')
external Function get _log;

@JS('console.log')
external void log(String s);

String dartStaticMethod() => 'hello';

@JS('jsStaticVariable')
external Function? get _jsStaticVariable;

@JS('jsStaticVariable')
external set _jsStaticVariable(Function? f);

@JS('jsStaticVariable')
external void jsStaticVariable(String s);

@JS('jsStaticFunction')
external Function get _jsStaticFunction;

@JS('jsStaticFunction')
external set _jsStaticFunction(Function f);

@JS('jsStaticFunction')
external void jsStaticFunction(String Function() f);

@JS()
class SomeClass {
  external factory SomeClass(String Function() f);
  external set jsFunctionFieldSetter(String Function() f);
  external void Function(String Function() f) get jsFunctionFieldGetter;
  external String jsInstanceMethod(String Function() f);

  external NestedJs get jsNonFunctionField;
}

@JS()
@anonymous
class NestedJs {
  external factory NestedJs({required String Function() constructorArg});
  external String get stringField;
}

@JS('someClass')
external set _someClass(dynamic s);
@JS('someClass')
external SomeClass get someClass;

void main() {
  Function(String) jsFunc = helper.JS('', '(x) => {}');
  Expect.equals(dart.assertInterop(jsFunc), jsFunc);

  Expect.equals(dart.assertInterop(_log), _log);
  Expect.equals(dart.assertInterop(console.log), console.log);
  Expect.throws(() => dart.assertInterop(dartStaticMethod));

  Expect.isNull(_jsStaticVariable);
  _jsStaticVariable = jsFunc;
  Expect.isNotNull(_jsStaticVariable);
  Expect.equals(dart.assertInterop(_jsStaticVariable), _jsStaticVariable);

  final dynamic wrappedDartStaticMethod = allowInterop(dartStaticMethod);

  final Function localNonNullLegacy = () => 'hello';
  final String Function() localNonNull = () => 'hello';
  final Function? localNullableLegacy = () => 'hello';
  final String Function()? localNullable = () => 'hello';

  // Assignment to JS static field.
  Expect.throws(() {
    _jsStaticVariable = () => 'hello';
  });
  Expect.throws(() {
    _jsStaticVariable = dartStaticMethod;
  });
  Expect.throws(() {
    _jsStaticVariable = localNonNullLegacy;
  });
  Expect.throws(() {
    _jsStaticVariable = localNonNull;
  });
  Expect.throws(() {
    _jsStaticVariable = localNullableLegacy!;
  });
  Expect.throws(() {
    _jsStaticVariable = localNullable!;
  });
  _jsStaticVariable = allowInterop(dartStaticMethod);
  _jsStaticVariable = wrappedDartStaticMethod;

  // Argument to static JS function.
  Function(Function(String), String) jsFunc2 = helper.JS('', '(f) => f()');
  _jsStaticFunction = jsFunc2;
  Expect.throws(() {
    jsStaticFunction(() => 'hello');
  });
  Expect.throws(() {
    jsStaticFunction(dartStaticMethod);
  });
  Expect.throws(() {
    jsStaticFunction(localNonNullLegacy as String Function());
  });
  Expect.throws(() {
    jsStaticFunction(localNonNull);
  });
  Expect.throws(() {
    jsStaticFunction(localNullableLegacy as String Function());
  });
  Expect.throws(() {
    jsStaticFunction(localNullable!);
  });
  jsStaticFunction(allowInterop(() => 'hello'));
  jsStaticFunction(wrappedDartStaticMethod);

  // Argument to torn off static JS function
  dynamic method = jsStaticFunction;
  Expect.throws(() {
    method(() => 'hello');
  });
  Expect.throws(() {
    method(dartStaticMethod);
  });
  Expect.throws(() {
    method(localNonNullLegacy);
  });
  Expect.throws(() {
    method(localNonNull);
  });
  Expect.throws(() {
    method(localNullableLegacy!);
  });
  Expect.throws(() {
    method(localNullable!);
  });
  method(allowInterop(() => 'hello'));
  method(wrappedDartStaticMethod);

  // Assignment to instance field.
  _someClass = helper.JS(
    '',
    '{"jsInstanceMethod": function(f) {return f();}, '
        '"jsNonFunctionField": {"stringField":"hello js"}, '
        '"jsFunctionFieldGetter": function(f) {return f();}}',
  );
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = () => 'hello';
  }));
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = dartStaticMethod;
  }));
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = localNonNullLegacy as String Function();
  }));
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = localNonNull;
  }));
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = localNullableLegacy as String Function();
  }));
  Expect.throws((() {
    someClass.jsFunctionFieldSetter = localNullable!;
  }));
  someClass.jsFunctionFieldSetter = allowInterop(() => 'hello');
  someClass.jsFunctionFieldSetter = wrappedDartStaticMethod;

  // Argument to instance method.
  Expect.throws(() {
    someClass.jsInstanceMethod(() => 'hello');
  });
  Expect.throws(() {
    someClass.jsInstanceMethod(dartStaticMethod);
  });
  Expect.throws(() {
    someClass.jsInstanceMethod(localNonNullLegacy as String Function());
  });
  Expect.throws(() {
    someClass.jsInstanceMethod(localNonNull);
  });
  Expect.throws(() {
    someClass.jsInstanceMethod(localNullableLegacy as String Function());
  });
  Expect.throws(() {
    someClass.jsInstanceMethod(localNullable!);
  });
  someClass.jsInstanceMethod(allowInterop(() => 'hello'));
  someClass.jsInstanceMethod(wrappedDartStaticMethod);

  // Argument to  constructor.
  context.callMethod('eval', ['function SomeClass(a) { a(); }']);
  Expect.throws(() {
    SomeClass(() => 'hello');
  });
  Expect.throws(() {
    SomeClass(dartStaticMethod);
  });
  Expect.throws(() {
    SomeClass(localNonNullLegacy as String Function());
  });
  Expect.throws(() {
    SomeClass(localNonNull);
  });
  Expect.throws(() {
    SomeClass(localNullableLegacy as String Function());
  });
  Expect.throws(() {
    SomeClass(localNullable!);
  });
  SomeClass(allowInterop(() => 'hello'));
  SomeClass(wrappedDartStaticMethod);

  // Argument to anonymous constructor.
  Expect.throws(() {
    NestedJs(constructorArg: () => 'hello');
  });
  Expect.throws(() {
    NestedJs(constructorArg: dartStaticMethod);
  });
  Expect.throws(() {
    NestedJs(constructorArg: localNonNullLegacy as String Function());
  });
  Expect.throws(() {
    NestedJs(constructorArg: localNonNull);
  });
  Expect.throws(() {
    NestedJs(constructorArg: localNullableLegacy as String Function());
  });
  Expect.throws(() {
    NestedJs(constructorArg: localNullable!);
  });
  NestedJs(constructorArg: allowInterop(() => 'hello'));
  NestedJs(constructorArg: wrappedDartStaticMethod);

  // Argument to torn off instance method.
  method = someClass.jsInstanceMethod;
  Expect.throws(() {
    method(() => 'hello');
  });
  Expect.throws(() {
    method(dartStaticMethod);
  });
  Expect.throws(() {
    method(localNonNullLegacy);
  });
  Expect.throws(() {
    method(localNonNull);
  });
  Expect.throws(() {
    method(localNullableLegacy!);
  });
  Expect.throws(() {
    method(localNullable!);
  });
  method(allowInterop(() => 'hello'));
  method(wrappedDartStaticMethod);

  // Function typed getter
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(() => 'hello');
  });
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(dartStaticMethod);
  });
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(localNonNullLegacy as String Function());
  });
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(localNonNull);
  });
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(localNullableLegacy as String Function());
  });
  Expect.throws(() {
    someClass.jsFunctionFieldGetter(localNullable!);
  });
  someClass.jsFunctionFieldGetter(allowInterop(() => 'hello'));
  someClass.jsFunctionFieldGetter(wrappedDartStaticMethod);

  // Stored Function typed getter
  method = someClass.jsFunctionFieldGetter;
  // We lose safety after calling a getter that returns a function, which takes
  // a function as an argument. Since this can be modeled with a method, instead
  // of a getter returning a function, we don't expect this is a pattern likely
  // to show up in real code.
  //Expect.throws(() {
  //  method(() => 'hello');
  //});
  //Expect.throws(() {
  //  method(dartStaticMethod);
  //});
  //Expect.throws(() {
  //  method(localNonNullLegacy);
  //});
  //Expect.throws(() {
  //  method(localNonNull);
  //});
  //Expect.throws(() {
  //  method(localNullableLegacy as String Function());
  //});
  //Expect.throws(() {
  //  method(localNullable!);
  //});
  method(allowInterop(() => 'hello'));
  method(wrappedDartStaticMethod);

  // Non-function fields
  Expect.equals(
    'hello js',
    someClass.jsNonFunctionField.stringField,
    'Does not wrap access to a field',
  );

  // No such method errors from interop calls.
  // The current behavior is that DDC does not treat these errors from the
  // JavaScript side as a LegacyJavaScriptObject.
  Expect.throwsNoSuchMethodError(
    () => context.callMethod('eval', ['self.foo()']),
  );
  Expect.throws<interceptors.JSNoSuchMethodError>(
    () => context.callMethod('eval', ['self.foo()']),
  );
  var error = Expect.throws(() => context.callMethod('eval', ['self.foo()']));
  Expect.notType<interceptors.LegacyJavaScriptObject>(error);
  Expect.notEquals(interceptors.LegacyJavaScriptObject, error.runtimeType);
  Expect.throwsNoSuchMethodError(
    () => context.callMethod('eval', ['self.foo.bar()']),
  );
  Expect.throws<interceptors.JSNoSuchMethodError>(
    () => context.callMethod('eval', ['self.foo.bar()']),
  );
  error = Expect.throws(() => context.callMethod('eval', ['self.foo.bar()']));
  Expect.notType<interceptors.LegacyJavaScriptObject>(error);
  Expect.notEquals(interceptors.LegacyJavaScriptObject, error.runtimeType);
}
