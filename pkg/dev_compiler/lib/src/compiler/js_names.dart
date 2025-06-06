// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:path/path.dart' as p;

import '../js_ast/js_ast.dart';

/// The ES6 name for the Dart SDK.  All dart:* libraries are in this module.
const String dartSdkModule = 'dart_sdk';

/// Names expected to be used without renaming.
///
/// These are fixed by the dart:_rti library and are accessed through the
/// `JsGetName` enum.
abstract class FixedNames {
  static const operatorIsPrefix = r'$is_';
  static const operatorSignature = r'_functionRti';
  static const rtiName = r'$ti';
  static const rtiAsField = '_as';
  static const rtiIsField = '_is';
}

/// Identifier tagged with a value shared by other instances representing the
/// same variable.
///
/// When printed will be renamed consistently across the entire
/// file. Instances with different IDs will be named differently even if they
/// have the same name, this makes it safe to use in code generation without
/// needing global knowledge. See [ScopedNamer].
class ScopedId extends Identifier {
  final int _id;

  /// If true, this variable can be used across different async scopes and must
  /// therefore be specially captured.
  final bool needsCapture;

  @override
  ScopedId withSourceInformation(dynamic sourceInformation) =>
      ScopedId.from(this)..sourceInformation = sourceInformation;

  static int _idCounter = 0;

  ScopedId(super.name, {this.needsCapture = false}) : _id = _idCounter++;
  ScopedId.from(ScopedId other)
    : _id = other._id,
      needsCapture = other.needsCapture,
      super(other.name);

  @override
  int get hashCode => _id;

  @override
  bool operator ==(Object other) {
    return other is ScopedId && other._id == _id;
  }
}

/// Creates a qualified identifier, without determining for sure if it needs to
/// be qualified until [setQualified] is called.
///
/// This expression is transparent to visiting after [setQualified].
class MaybeQualifiedId extends Expression {
  Expression _expr;

  final Identifier qualifier;
  final Expression name;

  MaybeQualifiedId(this.qualifier, this.name)
    : _expr = PropertyAccess(qualifier, name);

  /// Helper to create an [Identifier] from something that starts as a property.
  static Identifier identifier(LiteralString propertyName) =>
      Identifier(propertyName.valueWithoutQuotes);

  void setQualified(bool qualified) {
    var name = this.name;
    if (!qualified && name is LiteralString) {
      _expr = identifier(name);
    }
  }

  @override
  int get precedenceLevel => _expr.precedenceLevel;

  @override
  T accept<T>(NodeVisitor<T> visitor) => _expr.accept(visitor);

  @override
  void visitChildren(NodeVisitor visitor) => _expr.visitChildren(visitor);
}

/// Provides a mechanism to listen for naming choices when `Identifier` nodes
/// are compiled into an actual name in the JavaScript.
class NameListener {
  /// A mapping of all name selections that were made.
  final identifierNames = <Identifier, String>{};

  /// Signals that [name] was selected to represent [identifier].
  void nameSelected(Identifier identifier, String name) =>
      identifierNames[identifier] = name;
}

/// This class has two purposes:
///
/// * rename JS identifiers to avoid keywords.
/// * rename temporary variables to avoid colliding with user-specified names,
///   or other temporaries
///
/// Each instance of [ScopedId] is treated as a unique variable, with its
/// `name` field simply the suggestion of what name to use. By contrast
/// [Identifier]s are never renamed unless they are an invalid identifier, like
/// `function` or `instanceof`, and their `name` field controls whether they
/// refer to the same variable.
class ScopedNamer extends LocalNamer {
  _FunctionScope? _scope;

  /// Listener to be notified when a name is selected (rename or not) for an
  /// `Identifier`.
  ///
  /// Can be `null` when there is no listener attached.
  final NameListener? _nameListener;

  ScopedNamer(Node node, [this._nameListener])
    : _scope = _RenameVisitor.build(node).rootScope;

  @override
  String getName(Identifier node) {
    var name = _scope!.renames[identifierKey(node)] ?? node.name;
    _nameListener?.nameSelected(node, name);
    return name;
  }

  @override
  void enterScope(Node node) {
    _scope = _scope!.childScopes[node];
  }

  @override
  void leaveScope() {
    _scope = _scope!.parent;
  }
}

/// Represents a complete function scope in JS.
///
/// We don't currently track ES6 block scopes.
class _FunctionScope {
  /// The parent scope.
  final _FunctionScope? parent;

  /// All names declared in this scope.
  final declared = HashSet<Object>();

  /// All names [declared] in this scope or its [parent]s, that is used in this
  /// scope and/or children. This is exactly the set of variable names we must
  /// not collide with inside this scope.
  final used = HashSet<String>();

  /// Nested scopes, these are visited after everything else so the names
  /// they might need are in scope.
  final childScopes = <Node, _FunctionScope>{};

  /// New names assigned for temps and identifiers.
  final renames = HashMap<Object, String>();

  _FunctionScope(this.parent);
}

/// Collects all names used in the visited tree.
class _RenameVisitor extends VariableDeclarationVisitor {
  final pendingRenames = <Object, Set<_FunctionScope>>{};

  final _FunctionScope globalScope = _FunctionScope(null);
  final _FunctionScope rootScope = _FunctionScope(null);
  _FunctionScope? scope;

  _RenameVisitor.build(Node root) {
    scope = rootScope;
    root.accept(this);
    _finishScopes();
    _finishNames();
  }

  @override
  void declare(Identifier node) {
    var id = identifierKey(node);
    var notAlreadyDeclared = scope!.declared.add(id);
    // Normal identifiers can be declared multiple times, because we don't
    // implement block scope yet. However temps should only be declared once.
    assert(notAlreadyDeclared || node is! ScopedId);
    _markUsed(node, id, scope!);
  }

  @override
  void visitIdentifier(Identifier node) {
    var id = identifierKey(node);

    // Find where the node was declared.
    var declScope = scope;
    while (declScope != null && !declScope.declared.contains(id)) {
      declScope = declScope.parent;
    }
    if (declScope == null) {
      // Assume it comes from the global scope.
      declScope = globalScope;
      declScope.declared.add(id);
    }
    _markUsed(node, id, declScope);
  }

  void _markUsed(Identifier node, Object id, _FunctionScope declScope) {
    // If it needs rename, we can't add it to the used name set yet, instead we
    // will record all scopes it is visible in.
    Set<_FunctionScope>? usedIn;
    var rename = declScope != globalScope && needsRename(node);
    if (rename) {
      usedIn = pendingRenames.putIfAbsent(id, () => HashSet());
    }
    for (
      var s = scope, end = declScope.parent;
      s != end && s != null;
      s = s.parent
    ) {
      if (usedIn != null) {
        usedIn.add(s);
      } else {
        s.used.add(node.name);
      }
    }
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Visit nested functions after all identifiers are declared.
    scope!.childScopes[node] = _FunctionScope(scope);
  }

  @override
  void visitClassExpression(ClassExpression node) {
    scope!.childScopes[node] = _FunctionScope(scope);
  }

  void _finishScopes() {
    scope!.childScopes.forEach((node, s) {
      scope = s;
      if (node is FunctionExpression) {
        super.visitFunctionExpression(node);
      } else {
        super.visitClassExpression(node as ClassExpression);
      }
      _finishScopes();
      scope = scope!.parent;
    });
  }

  void _finishNames() {
    pendingRenames.forEach((id, scopes) {
      var name = _findName(id, scopes);
      for (var s in scopes) {
        s.used.add(name);
        s.renames[id] = name;
      }
    });
  }

  static String _findName(Object id, Set<_FunctionScope> scopes) {
    String name;
    bool valid;
    if (id is ScopedId) {
      name = id.name;
      valid = !invalidVariableName(name);
    } else {
      name = id as String;
      valid = false;
    }

    // Try to use the temp's name, otherwise rename.
    String candidate;
    if (valid && !scopes.any((scope) => scope.used.contains(name))) {
      candidate = name;
    } else {
      // This assumes that collisions are rare, hence linear search.
      // If collisions become common we need a better search.
      // TODO(jmesserly): what's the most readable scheme here? Maybe 1-letter
      // names in some cases?
      candidate = name == 'function' ? 'func' : '$name\$';
      for (
        var i = 0;
        scopes.any((scope) => scope.used.contains(candidate));
        i++
      ) {
        candidate = '$name\$$i';
      }
    }
    return candidate;
  }
}

bool needsRename(Identifier node) =>
    node is ScopedId || node.allowRename && invalidVariableName(node.name);

Object /*String|ScopedId*/ identifierKey(Identifier node) =>
    node is ScopedId ? node : node.name;

/// Returns true for invalid JS variable names, such as keywords.
/// Also handles invalid variable names in strict mode, like "arguments".
bool invalidVariableName(String keyword, {bool strictMode = true}) {
  switch (keyword) {
    // https: //262.ecma-international.org/6.0/#sec-reserved-words
    case 'true':
    case 'false':
    case 'null':
    // https://262.ecma-international.org/6.0/#sec-keywords
    case 'await':
    case 'break':
    case 'case':
    case 'catch':
    case 'class':
    case 'const':
    case 'continue':
    case 'debugger':
    case 'default':
    case 'delete':
    case 'do':
    case 'else':
    case 'enum':
    case 'export':
    case 'extends':
    case 'finally':
    case 'for':
    case 'function':
    case 'if':
    case 'import':
    case 'in':
    case 'instanceof':
    case 'new':
    case 'return':
    case 'super':
    case 'switch':
    case 'this':
    case 'throw':
    case 'try':
    case 'typeof':
    case 'var':
    case 'void':
    case 'while':
    case 'with':
      return true;
    case 'arguments':
    case 'eval':
    // http://www.ecma-international.org/ecma-262/6.0/#sec-future-reserved-words
    // http://www.ecma-international.org/ecma-262/6.0/#sec-identifiers-static-semantics-early-errors
    case 'implements':
    case 'interface':
    case 'let':
    case 'package':
    case 'private':
    case 'protected':
    case 'public':
    case 'static':
    case 'yield':
      return strictMode;
  }
  return false;
}

/// Returns true for names that cannot be set via `className.fieldName = ...`
/// on a JS class/constructor function.
///
/// These are getters on `Function.prototype` so we cannot set them but we can
/// define them on our object using `Object.defineProperty` or equivalent.
/// They are also valid as static getter/setter/method names if we use the JS
/// class syntax.
bool isFunctionPrototypeGetter(String name) {
  switch (name) {
    case 'arguments':
    case 'caller':
    case 'callee':
    case 'name':
    case 'length':
      return true;
  }
  return false;
}

/// See ES6 spec (and `Object.getOwnPropertyNames(Object.prototype)`):
///
/// http://www.ecma-international.org/ecma-262/6.0/#sec-properties-of-the-object-prototype-object
/// http://www.ecma-international.org/ecma-262/6.0/#sec-additional-properties-of-the-object.prototype-object
final objectProperties = <String>{
  'constructor',
  'toString',
  'toLocaleString',
  'valueOf',
  'hasOwnProperty',
  'isPrototypeOf',
  'propertyIsEnumerable',
  '__defineGetter__',
  '__lookupGetter__',
  '__defineSetter__',
  '__lookupSetter__',
  '__proto__',
};

/// Returns the JS member name for a public Dart instance member, before it
/// is symbolized; generally you should use [_emitMemberName] or
/// [_declareMemberName] instead of this.
String memberNameForDartMember(String name, [bool isExternal = false]) {
  // When generating synthetic names, we use _ as the prefix, since Dart names
  // won't have this, nor will static names reach here.
  switch (name) {
    case '[]':
      return '_get';
    case '[]=':
      return '_set';
    case 'unary-':
      return '_negate';
    case '==':
      return '_equals';
    case 'constructor':
    case 'prototype':
      // If [isExternal], assume the JS member is intended.
      return isExternal ? name : '_$name';
  }
  return name;
}

final friendlyNameForDartOperator = {
  '<': 'lessThan',
  '>': 'greaterThan',
  '<=': 'lessOrEquals',
  '>=': 'greaterOrEquals',
  '-': 'minus',
  '+': 'plus',
  '/': 'divide',
  '~/': 'floorDivide',
  '*': 'times',
  '%': 'modulo',
  '|': 'bitOr',
  '^': 'bitXor',
  '&': 'bitAnd',
  '<<': 'leftShift',
  '>>': 'rightShift',
  '>>>': 'tripleShift',
  '~': 'bitNot',
  // These ones are always renamed, hence the choice of `_` to avoid conflict
  // with Dart names. See _emitMemberName.
  '==': '_equals',
  '[]': '_get',
  '[]=': '_set',
  'unary-': '_negate',
};

// Invalid characters for identifiers, which would need to be escaped.
final invalidCharInIdentifier = RegExp(r'[^A-Za-z_$0-9]');

/// Escape [name] to make it into a valid identifier.
String toJSIdentifier(String name) {
  if (name.isEmpty) return r'$';

  // Escape any invalid characters
  StringBuffer? buffer;
  for (var i = 0; i < name.length; i++) {
    var ch = name[i];
    var needsEscape = ch == r'$' || invalidCharInIdentifier.hasMatch(ch);
    if (needsEscape) {
      buffer ??= StringBuffer(name.substring(0, i));
    }

    buffer?.write(needsEscape ? '\$${ch.codeUnits.join("")}' : ch);
  }

  var result = buffer != null ? '$buffer' : name;
  // Ensure the identifier first character is not numeric and that the whole
  // identifier is not a keyword.
  if (result.startsWith(RegExp('[0-9]')) || invalidVariableName(result)) {
    return '\$$result';
  }
  return result;
}

/// Converts an entire arbitrary path string into a string compatible with
/// JS identifier naming rules while conserving path information.
///
/// NOT guaranteed to result in a unique string. E.g.,
///   1) '__' appears in a file name.
///   2) An escaped '/' or '\' appears in a filename (a/b and a$47b).
String pathToJSIdentifier(String path) {
  path = p.normalize(path);
  if (path.startsWith('/') || path.startsWith('\\')) {
    path = path.substring(1, path.length);
  }
  return toJSIdentifier(
    path
        .replaceAll('\\', '__')
        .replaceAll('/', '__')
        .replaceAll('..', '__')
        .replaceAll('-', '_'),
  );
}
