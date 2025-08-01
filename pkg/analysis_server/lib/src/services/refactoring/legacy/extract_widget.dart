// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart' hide Element;
import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/refactoring/legacy/naming_conventions.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring_internal.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analysis_server_plugin/edit/correction_utils.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/utilities/extensions/flutter.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

/// [ExtractWidgetRefactoring] implementation.
class ExtractWidgetRefactoringImpl extends RefactoringImpl
    implements ExtractWidgetRefactoring {
  final SearchEngine searchEngine;
  final ResolvedUnitResult resolveResult;
  final AnalysisSessionHelper sessionHelper;
  final int offset;
  final int length;

  final CorrectionUtils utils;

  ClassElement? classBuildContext;
  ClassElement? classKey;
  ClassElement? classStatelessWidget;
  ClassElement? classWidget;
  PropertyAccessorElement? accessorRequired;

  @override
  late String name;

  /// If [offset] is in a class, the node of this class, `null` otherwise.
  ClassDeclaration? _enclosingClassNode;

  /// If [offset] is in a class, the element of this class, `null` otherwise.
  ClassElement? _enclosingClassElement;

  /// The [CompilationUnitMember] that encloses the [offset].
  CompilationUnitMember? _enclosingUnitMember;

  /// The widget creation expression to extract.
  InstanceCreationExpression? _expression;

  /// The statements covered by [offset] and [length] to extract.
  List<Statement>? _statements;

  /// The [SourceRange] that covers [_statements].
  SourceRange? _statementsRange;

  /// The method returning widget to extract.
  MethodDeclaration? _method;

  /// The parameters for the new widget class - referenced fields of the
  /// [_enclosingClassElement], local variables referenced by [_expression],
  /// and [_method] parameters.
  final List<_Parameter> _parameters = [];

  ExtractWidgetRefactoringImpl(
    this.searchEngine,
    this.resolveResult,
    this.offset,
    this.length,
  ) : sessionHelper = AnalysisSessionHelper(resolveResult.session),
      utils = CorrectionUtils(resolveResult);

  @override
  String get refactoringName {
    return 'Extract Widget';
  }

  FeatureSet get _featureSet {
    return resolveResult.unit.featureSet;
  }

  @override
  Future<RefactoringStatus> checkFinalConditions() async {
    var result = RefactoringStatus();
    result.addStatus(validateClassName(name));
    return result;
  }

  @override
  Future<RefactoringStatus> checkInitialConditions() async {
    var result = RefactoringStatus();

    result.addStatus(_checkSelection());
    if (result.hasFatalError) {
      return result;
    }

    var astNode = _expression ?? _method ?? _statements!.first;
    _enclosingUnitMember = astNode.thisOrAncestorMatching((n) {
      return n is CompilationUnitMember && n.parent is CompilationUnit;
    });

    result.addStatus(await _initializeClasses());
    result.addStatus(await _initializeParameters());

    return result;
  }

  @override
  RefactoringStatus checkName() {
    var result = RefactoringStatus();

    // Validate the name.
    result.addStatus(validateClassName(name));

    // Check for duplicate declarations.
    if (!result.hasFatalError) {
      for (var element in resolveResult.libraryElement.children) {
        if (element.displayName == name) {
          var message = formatList(
            "Library already declares {0} with name '{1}'.",
            [element.kind.displayName, name],
          );
          result.addError(message, newLocation_fromElement(element));
        }
      }
    }

    return result;
  }

  @override
  Future<SourceChange> createChange() async {
    var builder = ChangeBuilder(
      session: sessionHelper.session,
      eol: utils.endOfLine,
    );
    await builder.addDartFileEdit(resolveResult.path, (builder) {
      var expression = _expression;
      var statements = _statements;
      if (expression != null) {
        builder.addReplacement(range.node(expression), (builder) {
          _writeWidgetInstantiation(builder);
        });
      } else if (statements != null) {
        builder.addReplacement(_statementsRange!, (builder) {
          builder.write('return ');
          _writeWidgetInstantiation(builder);
          builder.write(';');
        });
      } else {
        _removeMethodDeclaration(builder);
        _replaceInvocationsWithInstantiations(builder);
      }

      _writeWidgetDeclaration(builder);
    });
    return builder.sourceChange;
  }

  @override
  bool isAvailable() {
    return !_checkSelection().hasFatalError;
  }

  /// Checks if [offset] is a widget creation expression that can be extracted.
  RefactoringStatus _checkSelection() {
    var node = resolveResult.unit.nodeCovering(offset: offset, length: length);

    // Treat single ReturnStatement as its expression.
    if (node is ReturnStatement) {
      node = node.expression;
    }

    // Find the enclosing class.
    _enclosingClassNode = node?.thisOrAncestorOfType<ClassDeclaration>();
    _enclosingClassElement = _enclosingClassNode?.declaredFragment?.element;

    // `new MyWidget(...)`
    var newExpression = node.findInstanceCreationExpression;
    if (newExpression?.isWidgetCreation ?? false) {
      _expression = newExpression;
      return RefactoringStatus();
    }

    // Block with selected statements.
    if (node is Block) {
      var selectionRange = SourceRange(offset, length);
      var statements = <Statement>[];
      for (var statement in node.statements) {
        var statementRange = range.node(statement);
        if (statementRange.intersects(selectionRange)) {
          statements.add(statement);
        }
      }
      if (statements.isNotEmpty) {
        var lastStatement = statements.last;
        if (lastStatement is ReturnStatement &&
            lastStatement.expression.isWidgetExpression) {
          _statements = statements;
          _statementsRange = range.startEnd(statements.first, statements.last);
          return RefactoringStatus();
        } else {
          return RefactoringStatus.fatal(
            'The last selected statement must return a widget.',
          );
        }
      }
    }

    // Widget myMethod(...) { ... }
    for (; node != null; node = node.parent) {
      if (node is FunctionBody) {
        break;
      }
      if (node is MethodDeclaration) {
        var returnType = node.returnType?.type;
        if (returnType.isWidgetType) {
          _method = node;
          return RefactoringStatus();
        }
        break;
      }
    }

    // Invalid selection.
    return RefactoringStatus.fatal(
      'Can only extract a widget expression or a method returning widget.',
    );
  }

  Future<RefactoringStatus> _initializeClasses() async {
    var result = RefactoringStatus();

    Future<ClassElement?> getClass(String name) async {
      var element = await sessionHelper.getFlutterClass(name);
      if (element == null) {
        result.addFatalError("Unable to find '$name' in $widgetsUri");
      }
      return element;
    }

    Future<PropertyAccessorElement?> getAccessor(
      String uri,
      String name,
    ) async {
      var element = await sessionHelper.getTopLevelPropertyAccessor(uri, name);
      if (element == null) {
        result.addFatalError("Unable to find 'required' in $uri");
      }
      return element;
    }

    classBuildContext = await getClass('BuildContext');
    classKey = await getClass('Key');
    classStatelessWidget = await getClass('StatelessWidget');
    classWidget = await getClass('Widget');

    accessorRequired = await getAccessor('package:meta/meta.dart', 'required');

    return result;
  }

  /// Prepare referenced local variables and fields, that should be turned
  /// into the widget class fields and constructor parameters.
  Future<RefactoringStatus> _initializeParameters() async {
    _ParametersCollector? collector;

    var expression = _expression;
    if (expression != null) {
      var localRange = range.node(expression);
      collector = _ParametersCollector(_enclosingClassElement, localRange);
      expression.accept(collector);
    }

    var statements = _statements;
    if (statements != null) {
      collector = _ParametersCollector(
        _enclosingClassElement,
        _statementsRange!,
      );
      for (var statement in statements) {
        statement.accept(collector);
      }
    }

    var method = _method;
    if (method != null) {
      var localRange = range.node(method);
      collector = _ParametersCollector(_enclosingClassElement, localRange);
      method.body.accept(collector);
    }

    _parameters
      ..clear()
      ..addAll(collector!.parameters);

    // We added fields, now add the method parameters.
    if (method != null) {
      var parameterList = method.parameters;
      if (parameterList != null) {
        for (var parameter in parameterList.parameters) {
          parameter = parameter.notDefault;
          if (parameter is NormalFormalParameter) {
            var element = parameter.declaredFragment!.element;
            _parameters.add(
              _Parameter(element.name!, element.type, isMethodParameter: true),
            );
          }
        }
      }
    }

    var status = collector.status;

    // If there is an existing parameter "key" warn the user.
    // We could rename it, but that would require renaming references to it.
    // It is probably pretty rare, and the user can always rename before.
    for (var parameter in _parameters) {
      if (parameter.name == 'key') {
        status.addError(
          "The parameter 'key' will conflict with the widget 'key'.",
        );
      }
    }

    // Collect used public names.
    var usedNames = <String>{};
    for (var parameter in _parameters) {
      if (!parameter.name.startsWith('_')) {
        usedNames.add(parameter.name);
      }
    }

    // Give each private parameter a public name for the constructor.
    for (var parameter in _parameters) {
      var name = parameter.name;
      if (name.startsWith('_')) {
        var baseName = name.substring(1);
        for (var i = 1; ; i++) {
          name = i == 1 ? baseName : '$baseName$i';
          if (usedNames.add(name)) {
            break;
          }
        }
      }
      parameter.constructorName = name;
    }

    return collector.status;
  }

  /// Remove the [_method] declaration.
  void _removeMethodDeclaration(DartFileEditBuilder builder) {
    var methodRange = range.node(_method!);
    var linesRange = utils.getLinesRange(
      methodRange,
      skipLeadingEmptyLines: true,
    );
    builder.addDeletion(linesRange);
  }

  /// Replace invocations of the [_method] with instantiations of the new
  /// widget class.
  void _replaceInvocationsWithInstantiations(DartFileEditBuilder builder) {
    var collector = _MethodInvocationsCollector(
      _method!.declaredFragment!.element,
    );
    _enclosingClassNode!.accept(collector);
    for (var invocation in collector.invocations) {
      List<Expression> arguments = invocation.argumentList.arguments;
      builder.addReplacement(range.node(invocation), (builder) {
        builder.write('$name(');

        // Insert field references (as named arguments).
        // Ensure that invocation arguments are named.
        var argumentIndex = 0;
        for (var parameter in _parameters) {
          if (parameter != _parameters.first) {
            builder.write(', ');
          }
          builder.write(parameter.name);
          builder.write(': ');
          if (parameter.isMethodParameter) {
            var argument = arguments[argumentIndex++];
            if (argument is NamedExpression) {
              argument = argument.expression;
            }
            builder.write(utils.getNodeText(argument));
          } else {
            builder.write(parameter.name);
          }
        }
        builder.write(')');
      });
    }
  }

  /// Write declaration of the new widget class.
  void _writeWidgetDeclaration(DartFileEditBuilder builder) {
    builder.addInsertion(_enclosingUnitMember!.end, (builder) {
      builder.writeln();
      builder.writeln();
      var useSuperParameters = _featureSet.isEnabled(Feature.super_parameters);
      var paramsToInitialize =
          _parameters.where((p) => p.constructorName != p.name).toList();
      builder.writeClassDeclaration(
        name,
        superclass: classStatelessWidget!.instantiate(
          typeArguments: const [],
          nullabilitySuffix: NullabilitySuffix.none,
        ),
        membersWriter: () {
          // Add the constructor.
          builder.write('  ');
          builder.writeConstructorDeclaration(
            name,
            isConst: true,
            parameterWriter: () {
              builder.writeln('{');

              // Add the required `key` parameter.
              builder.write('    ');
              if (useSuperParameters) {
                builder.write('super.key');
              } else {
                builder.writeParameter(
                  'key',
                  type: classKey!.instantiate(
                    typeArguments: const [],
                    nullabilitySuffix: NullabilitySuffix.question,
                  ),
                );
              }
              builder.writeln(',');

              // Add parameters for fields, local, and method parameters.
              for (var parameter in _parameters) {
                builder.write('    required ');
                if (parameter.constructorName != parameter.name) {
                  builder.writeType(parameter.type);
                  builder.write(' ');
                  builder.write(parameter.constructorName);
                } else {
                  builder.write('this.');
                  builder.write(parameter.name);
                }
                builder.writeln(',');
              }

              builder.write('  }');
            },
            initializerWriter:
                useSuperParameters && paramsToInitialize.isEmpty
                    ? null
                    : () {
                      for (var i = 0; i < paramsToInitialize.length; ++i) {
                        var parameter = paramsToInitialize[i];
                        if (i > 0) {
                          builder.write(', ');
                        }
                        builder.write(parameter.name);
                        builder.write(' = ');
                        builder.write(parameter.constructorName);
                      }
                      if (!useSuperParameters) {
                        if (paramsToInitialize.isNotEmpty) {
                          builder.write(', ');
                        }
                        builder.write('super(key: key)');
                      }
                    },
          );
          builder.writeln();
          builder.writeln();

          // Add the fields for the parameters.
          if (_parameters.isNotEmpty) {
            for (var parameter in _parameters) {
              builder.write('  ');
              builder.writeFieldDeclaration(
                parameter.name,
                isFinal: true,
                type: parameter.type,
              );
              builder.writeln();
            }
            builder.writeln();
          }

          // Widget build(BuildContext context) { ... }
          builder.writeln('  @override');
          builder.write('  ');
          builder.writeFunctionDeclaration(
            'build',
            returnType: classWidget!.instantiate(
              typeArguments: const [],
              nullabilitySuffix: NullabilitySuffix.none,
            ),
            parameterWriter: () {
              builder.writeParameter(
                'context',
                type: classBuildContext!.instantiate(
                  typeArguments: const [],
                  nullabilitySuffix: NullabilitySuffix.none,
                ),
              );
            },
            bodyWriter: () {
              var expression = _expression;
              if (expression != null) {
                var indentOld = utils.getLinePrefix(expression.offset);
                var indentNew = '    ';

                var code = utils.getNodeText(expression);
                code = utils.replaceSourceIndent(code, indentOld, indentNew);

                builder.writeln('{');

                builder.write('    return ');
                builder.write(code);
                builder.writeln(';');

                builder.writeln('  }');
              } else if (_statements != null) {
                var indentOld = utils.getLinePrefix(_statementsRange!.offset);
                var indentNew = '    ';

                var code = utils.getRangeText(_statementsRange!);
                code = utils.replaceSourceIndent(code, indentOld, indentNew);

                builder.writeln('{');

                builder.write(indentNew);
                builder.write(code);
                builder.writeln();

                builder.writeln('  }');
              } else {
                var code = utils.getNodeText(_method!.body);
                builder.writeln(code);
              }
            },
          );
        },
      );
    });
  }

  /// Write instantiation of the new widget class.
  void _writeWidgetInstantiation(DartEditBuilder builder) {
    builder.write('$name(');

    for (var parameter in _parameters) {
      if (parameter != _parameters.first) {
        builder.write(', ');
      }
      builder.write(parameter.constructorName);
      builder.write(': ');
      builder.write(parameter.name);
    }

    builder.write(')');
  }
}

class _MethodInvocationsCollector extends RecursiveAstVisitor<void> {
  final ExecutableElement methodElement;
  final List<MethodInvocation> invocations = [];

  _MethodInvocationsCollector(this.methodElement);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.element == methodElement) {
      invocations.add(node);
    } else {
      super.visitMethodInvocation(node);
    }
  }
}

class _Parameter {
  /// The name which is used to reference this parameter in the expression
  /// being extracted, and also the name of the field in the new widget.
  final String name;

  final DartType type;

  /// Whether the parameter is a parameter of the method being extracted.
  final bool isMethodParameter;

  /// If the [name] is private, the public name to use in the new widget
  /// constructor. If the [name] is already public, then the [name].
  late String constructorName;

  _Parameter(this.name, this.type, {this.isMethodParameter = false});
}

class _ParametersCollector extends RecursiveAstVisitor<void> {
  final InterfaceElement? enclosingClass;
  final SourceRange expressionRange;

  final RefactoringStatus status = RefactoringStatus();
  final Set<Element> uniqueElements = <Element>{};
  final List<_Parameter> parameters = [];

  List<InterfaceElement>? enclosingClasses;

  _ParametersCollector(this.enclosingClass, this.expressionRange);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    var element = node.writeOrReadElement;
    if (element == null) {
      return;
    }
    var elementName = element.displayName;

    DartType? type;
    if (element is MethodElement) {
      if (_isMemberOfEnclosingClass(element)) {
        status.addError(
          'Reference to an enclosing class method cannot be extracted.',
        );
      }
    } else if (element is LocalVariableElement) {
      if (!expressionRange.contains(element.firstFragment.nameOffset!)) {
        if (node.inSetterContext()) {
          status.addError("Write to '$elementName' cannot be extracted.");
        } else {
          type = element.type;
        }
      }
    } else if (element is PropertyAccessorElement) {
      var field = element.variable;
      if (_isMemberOfEnclosingClass(field)) {
        if (node.inSetterContext()) {
          status.addError("Write to '$elementName' cannot be extracted.");
        } else {
          type = field.type;
          element = element.baseElement;
        }
      }
    }
    // TODO(scheglov): support for ParameterElement

    if (type != null && uniqueElements.add(element)) {
      parameters.add(_Parameter(elementName, type));
    }
  }

  /// Return `true` if the given [element] is a member of the [enclosingClass]
  /// or one of its supertypes, interfaces, or mixins.
  bool _isMemberOfEnclosingClass(Element element) {
    var enclosingClass = this.enclosingClass;
    if (enclosingClass != null) {
      var enclosingClasses =
          this.enclosingClasses ??= <InterfaceElement>[
            enclosingClass,
            ...enclosingClass.allSupertypes.map((t) => t.element),
          ];
      return enclosingClasses.contains(element.enclosingElement);
    }
    return false;
  }
}
