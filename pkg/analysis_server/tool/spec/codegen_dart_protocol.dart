// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:analyzer_utilities/html_dom.dart' as dom;
import 'package:analyzer_utilities/tools.dart';

import 'api.dart';
import 'codegen_dart.dart';
import 'from_html.dart';
import 'implied_types.dart';
import 'to_html.dart';

/// Special flags that need to be inserted into the declaration of the Element
/// class.
const Map<String, String> specialElementFlags = {
  'abstract': '0x01',
  'const': '0x02',
  'final': '0x04',
  'static': '0x08',
  'private': '0x10',
  'deprecated': '0x20',
};

GeneratedFile clientTarget(
  bool responseRequiresRequestTime,
  CodegenUriConverterKind clientUriConverterKind,
) {
  return GeneratedFile(
    'analysis_server_client/lib/src/protocol/protocol_generated.dart',
    (pkgRoot) async {
      var visitor = CodegenProtocolVisitor(
        'analysis_server_client',
        responseRequiresRequestTime,
        clientUriConverterKind,
        false,
        readApi(pkgRoot),
      );
      return visitor.collectCode(visitor.visitApi);
    },
  );
}

GeneratedFile serverTarget(
  bool responseRequiresRequestTime,
  CodegenUriConverterKind clientUriConverterKind,
) {
  return GeneratedFile('analysis_server/lib/protocol/protocol_generated.dart', (
    pkgRoot,
  ) async {
    var visitor = CodegenProtocolVisitor(
      'analysis_server',
      responseRequiresRequestTime,
      clientUriConverterKind,
      true,
      readApi(pkgRoot),
    );
    return visitor.collectCode(visitor.visitApi);
  });
}

/// Callback type used to represent arbitrary code generation.
typedef CodegenCallback = void Function();

typedef FromJsonSnippetCallback = String Function(String jsonPath, String json);

typedef ToJsonSnippetCallback = String Function(String value);

/// Visitor which produces Dart code representing the API.
class CodegenProtocolVisitor extends DartCodegenVisitor with CodeGenerator {
  /// Class members for which the constructor argument should be optional, even
  /// if the member is not an optional part of the protocol.  For list types,
  /// the constructor will default the member to the empty list.
  static const Map<String, List<String>> _optionalConstructorArguments = {
    'AnalysisErrorFixes': ['fixes'],
    'SourceChange': ['edits', 'linkedEditGroups'],
    'SourceFileEdit': ['edits'],
    'TypeHierarchyItem': ['interfaces', 'mixins', 'subclasses'],
  };

  /// The disclaimer added to the documentation comment for each of the classes
  /// that are generated.
  static const String disclaimer =
      'Clients may not extend, implement or mix-in this class.';

  /// The name of the package into which code is being generated.
  final String packageName;

  /// A flag indicating whether the class [Response] requires a `requestTime`
  /// parameter.
  final bool responseRequiresRequestTime;

  /// The kind or URI Conversion to be used in generated code.
  final CodegenUriConverterKind clientUriConverterKind;

  /// A flag indicating whether this generated code is for the server
  /// (analysis_server) or for the client (analysis_server_client).
  final bool isServer;

  /// Visitor used to produce doc comments.
  final ToHtmlVisitor toHtmlVisitor;

  /// Types implied by the API.  This includes types explicitly named in the
  /// API as well as those implied by the definitions of requests, responses,
  /// notifications, etc.
  final Map<String, ImpliedType> impliedTypes;

  CodegenProtocolVisitor(
    this.packageName,
    this.responseRequiresRequestTime,
    this.clientUriConverterKind,
    this.isServer,
    Api api,
  ) : toHtmlVisitor = ToHtmlVisitor(api),
      impliedTypes = computeImpliedTypes(api),
      super(api) {
    codeGeneratorSettings.commentLineLength = 79;
    codeGeneratorSettings.docCommentStartMarker = null;
    codeGeneratorSettings.docCommentLineLeader = '/// ';
    codeGeneratorSettings.docCommentEndMarker = null;
    codeGeneratorSettings.languageName = 'dart';
  }

  /// Compute the code necessary to compare two objects for equality.
  String compareEqualsCode(TypeDecl type, String thisVar, String otherVar) {
    var resolvedType = resolveTypeReferenceChain(type);
    if (resolvedType is TypeReference ||
        resolvedType is TypeEnum ||
        resolvedType is TypeObject ||
        resolvedType is TypeUnion) {
      return '$thisVar == $otherVar';
    } else if (resolvedType is TypeList) {
      var itemTypeName = dartType(resolvedType.itemType);
      var subComparison = compareEqualsCode(resolvedType.itemType, 'a', 'b');
      var closure = '($itemTypeName a, $itemTypeName b) => $subComparison';
      return 'listEqual($thisVar, $otherVar, $closure)';
    } else if (resolvedType is TypeMap) {
      var valueTypeName = dartType(resolvedType.valueType);
      var subComparison = compareEqualsCode(resolvedType.valueType, 'a', 'b');
      var closure = '($valueTypeName a, $valueTypeName b) => $subComparison';
      return 'mapEqual($thisVar, $otherVar, $closure)';
    }
    throw Exception("Don't know how to compare for equality: $resolvedType");
  }

  /// Translate each of the given [types] implied by the API to a class.
  void emitClasses(List<ImpliedType> types) {
    for (var impliedType in types) {
      var type = impliedType.type;
      var dartTypeName = capitalize(impliedType.camelName);
      if (type == null) {
        writeln();
        emitEmptyObjectClass(dartTypeName, impliedType);
      } else if (type is TypeObject) {
        writeln();
        emitObjectClass(dartTypeName, type, impliedType);
      } else if (type is TypeEnum) {
        writeln();
        emitEnum(dartTypeName, type, impliedType);
      }
    }
  }

  /// Emit a convenience constructor for decoding a piece of protocol, if
  /// appropriate. Return true if a constructor was emitted.
  bool emitConvenienceConstructor(String className, ImpliedType impliedType) {
    // The type of object from which this piece of protocol should be decoded.
    String inputType;
    // The name of the input object.
    String inputName;
    // The field within the input object to decode.
    String fieldName;
    // Constructor call to create the JsonDecoder object.
    String makeDecoder;
    // Name of the constructor to create.
    String constructorName;
    // Extra arguments for the constructor.
    var extraArgs = <String>[];
    switch (impliedType.kind) {
      case 'requestParams':
        inputType = 'Request';
        inputName = 'request';
        fieldName = 'params';
        makeDecoder = 'RequestDecoder(request)';
        constructorName = 'fromRequest';
      case 'requestResult':
        inputType = 'Response';
        inputName = 'response';
        fieldName = 'result';
        makeDecoder =
            'ResponseDecoder(REQUEST_ID_REFACTORING_KINDS.remove(response.id))';
        constructorName = 'fromResponse';
      case 'notificationParams':
        inputType = 'Notification';
        inputName = 'notification';
        fieldName = 'params';
        makeDecoder = 'ResponseDecoder(null)';
        constructorName = 'fromNotification';
      case 'refactoringOptions':
        inputType = 'EditGetRefactoringParams';
        inputName = 'refactoringParams';
        fieldName = 'options';
        makeDecoder = 'RequestDecoder(request)';
        constructorName = 'fromRefactoringParams';
        extraArgs.add('Request request');
      default:
        return false;
    }

    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', { ${clientUriConverterKind.namedParameterString} }'
            : '';
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', ${clientUriConverterKind.namedArgumentString}'
            : '';

    var args = <String>['$inputType $inputName'];
    args.addAll(extraArgs);
    writeln(
      'factory $className.$constructorName(${args.join(', ')}$namedParameters) {',
    );
    indent(() {
      var fieldNameString = _literalString(
        fieldName.replaceFirst(RegExp('^_'), ''),
      );
      if (className == 'EditGetRefactoringParams') {
        writeln('var params = $className.fromJson(');
        writeln(
          '    $makeDecoder, $fieldNameString, $inputName.$fieldName$namedArguments);',
        );
        writeln('REQUEST_ID_REFACTORING_KINDS[request.id] = params.kind;');
        writeln('return params;');
      } else {
        writeln('return $className.fromJson(');
        writeln(
          '    $makeDecoder, $fieldNameString, $inputName.$fieldName$namedArguments);',
        );
      }
    });
    writeln('}');
    return true;
  }

  /// Emit a class representing an data structure that doesn't exist in the
  /// protocol because it is empty (e.g. the "params" object for a request that
  /// doesn't have any parameters).
  void emitEmptyObjectClass(String className, ImpliedType impliedType) {
    docComment(
      toHtmlVisitor.collectHtml(() {
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(impliedType.humanReadableName);
        });
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(disclaimer);
        });
      }),
    );
    write('class $className');
    if (impliedType.kind == 'refactoringFeedback') {
      writeln(' extends RefactoringFeedback implements HasToJson {');
    } else if (impliedType.kind == 'refactoringOptions') {
      writeln(' extends RefactoringOptions implements HasToJson {');
    } else if (impliedType.kind == 'requestParams') {
      writeln(' implements RequestParams {');
    } else if (impliedType.kind == 'requestResult') {
      writeln(' implements ResponseResult {');
    } else {
      writeln(' {');
    }
    indent(() {
      if (impliedType.kind == 'requestResult' ||
          impliedType.kind == 'requestParams') {
        emitEmptyToJsonMember();
        writeln();
      }
      if (emitToRequestMember(impliedType)) {
        writeln();
      }
      if (emitToResponseMember(impliedType)) {
        writeln();
      }
      if (emitToNotificationMember(impliedType)) {
        writeln();
      }
      emitObjectEqualsMember(null, className);
      writeln();
      emitObjectHashCode(null, className);
    });
    writeln('}');
  }

  /// Emit the toJson() code for an empty class.
  void emitEmptyToJsonMember() {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? '{ ${clientUriConverterKind.namedParameterString} }'
            : '';
    writeln('@override');
    writeln('Map<String, Object> toJson($namedParameters) => {};');
  }

  /// Emit a class to encapsulate an enum.
  void emitEnum(String className, TypeEnum type, ImpliedType impliedType) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? '{ ${clientUriConverterKind.namedParameterString} }'
            : '';

    docComment(
      toHtmlVisitor.collectHtml(() {
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(impliedType.humanReadableName);
        });
        var impliedTypeType = impliedType.type;
        if (impliedTypeType != null) {
          toHtmlVisitor.showType(null, impliedTypeType);
        }
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(disclaimer);
        });
      }),
    );
    writeln('enum $className {');
    indent(() {
      if (emitSpecialStaticMembers(className)) {
        writeln();
      }
      for (var value in type.values) {
        docComment(
          toHtmlVisitor.collectHtml(() {
            toHtmlVisitor.translateHtml(value.html);
          }),
        );
        if (value != type.values.last) {
          writeln('${value.value},');
        } else {
          writeln('${value.value};');
        }
        writeln();
      }

      writeln();
      emitEnumFromJsonConstructor(className, type, impliedType);
      writeln();
      if (emitSpecialConstructors(className)) {
        writeln();
      }
      if (emitSpecialGetters(className)) {
        writeln();
      }
      if (emitSpecialMethods(className)) {
        writeln();
      }
      writeln('@override');
      writeln("String toString() => '$className.\$name';");
      writeln();
      writeln('String toJson($namedParameters) => name;');
    });
    writeln('}');
  }

  /// Emit the method for decoding an enum from JSON.
  void emitEnumFromJsonConstructor(
    String className,
    TypeEnum type,
    ImpliedType impliedType,
  ) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', { ${clientUriConverterKind.namedParameterString} }'
            : '';
    writeln(
      'factory $className.fromJson(JsonDecoder jsonDecoder, String jsonPath, Object? json$namedParameters) {',
    );
    indent(() {
      writeln('if (json is String) {');
      indent(() {
        writeln('try {');
        indent(() {
          writeln('return values.byName(json);');
        });
        writeln('} catch(_) {');
        indent(() {
          writeln('// Fall through');
        });
        writeln('}');
      });
      writeln('}');
      var humanReadableNameString = _literalString(
        impliedType.humanReadableName,
      );
      writeln(
        'throw jsonDecoder.mismatch(jsonPath, $humanReadableNameString, json);',
      );
    });
    writeln('}');
  }

  void emitImports() {
    writeln("import 'dart:convert' hide JsonDecoder;");
    writeln();
    if (isServer) {
      writeln("import 'package:$packageName/protocol/protocol.dart';");
      writeln(
        "import 'package:$packageName/src/protocol/protocol_internal.dart';",
      );
      writeln(
        "import 'package:analyzer_plugin/src/utilities/client_uri_converter.dart';",
      );
      for (var uri in api.types.importUris) {
        write("import '");
        write(uri);
        writeln("';");
      }
    } else {
      writeln("import 'package:$packageName/src/protocol/protocol_base.dart';");
      writeln(
        "import 'package:$packageName/src/protocol/protocol_common.dart';",
      );
      writeln(
        "import 'package:$packageName/src/protocol/protocol_internal.dart';",
      );
    }
  }

  /// Emit the class to encapsulate an object type.
  void emitObjectClass(
    String className,
    TypeObject type,
    ImpliedType impliedType,
  ) {
    docComment(
      toHtmlVisitor.collectHtml(() {
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(impliedType.humanReadableName);
        });
        var impliedTypeType = impliedType.type;
        if (impliedTypeType != null) {
          toHtmlVisitor.showType(null, impliedTypeType);
        }
        toHtmlVisitor.p(() {
          toHtmlVisitor.write(disclaimer);
        });
      }),
    );
    write('class $className');
    if (impliedType.kind == 'refactoringFeedback') {
      writeln(' extends RefactoringFeedback {');
    } else if (impliedType.kind == 'refactoringOptions') {
      writeln(' extends RefactoringOptions {');
    } else if (impliedType.kind == 'requestParams') {
      writeln(' implements RequestParams {');
    } else if (impliedType.kind == 'requestResult') {
      writeln(' implements ResponseResult {');
    } else {
      writeln(' implements HasToJson {');
    }
    indent(() {
      if (emitSpecialStaticMembers(className)) {
        writeln();
      }
      for (var field in type.fields) {
        if (field.value != null) {
          continue;
        }
        docComment(
          toHtmlVisitor.collectHtml(() {
            toHtmlVisitor.translateHtml(field.html);
          }),
        );
        writeln('${fieldDartType(field)} ${field.name};');
        writeln();
      }
      emitObjectConstructor(type, className);
      writeln();
      emitObjectFromJsonConstructor(className, type, impliedType);
      writeln();
      if (emitConvenienceConstructor(className, impliedType)) {
        writeln();
      }
      if (emitSpecialConstructors(className)) {
        writeln();
      }
      if (emitSpecialGetters(className)) {
        writeln();
      }
      emitToJsonMember(type);
      writeln();
      if (emitToRequestMember(impliedType)) {
        writeln();
      }
      if (emitToResponseMember(impliedType)) {
        writeln();
      }
      if (emitToNotificationMember(impliedType)) {
        writeln();
      }
      if (emitSpecialMethods(className)) {
        writeln();
      }

      var namedArguments =
          clientUriConverterKind != CodegenUriConverterKind.none
              ? 'clientUriConverter: null'
              : '';
      writeln('@override');
      writeln('String toString() => json.encode(toJson($namedArguments));');
      writeln();

      emitObjectEqualsMember(type, className);
      writeln();
      emitObjectHashCode(type, className);
    });
    writeln('}');
  }

  /// Emit the constructor for an object class.
  void emitObjectConstructor(TypeObject type, String className) {
    var args = <String>[];
    var optionalArgs = <String>[];
    var initializers = <String>[];
    for (var field in type.fields) {
      if (field.value != null) {
        continue;
      }
      if (isOptionalConstructorArg(className, field)) {
        if (!field.optional) {
          optionalArgs.add('${dartType(field.type)}? ${field.name}');
          // Optional constructor arg, but non-optional field. If no arg is
          // given, the constructor should populate with the empty list.
          var fieldType = field.type;
          if (fieldType is TypeList) {
            var defaultValue = '<${dartType(fieldType.itemType)}>[]';
            initializers.add('${field.name} = ${field.name} ?? $defaultValue');
          } else {
            throw Exception("Don't know how to create default field value.");
          }
        } else {
          optionalArgs.add('this.${field.name}');
        }
      } else {
        args.add('this.${field.name}');
      }
    }
    if (optionalArgs.isNotEmpty) {
      args.add('{${optionalArgs.join(', ')}}');
    }
    write('$className(${args.join(', ')})');
    if (initializers.isNotEmpty) {
      writeln(' : ${initializers.join(', ')}');
    }
    writeln(';');
  }

  /// Emit the operator== code for an object class.
  void emitObjectEqualsMember(TypeObject? type, String className) {
    writeln('@override');
    write('bool operator ==(Object other) ');
    if (type == null) {
      writeln('=> other is $className;');
      return;
    }
    writeln('{');
    indent(() {
      writeln('if (other is $className) {');
      indent(() {
        var comparisons = <String>[];
        for (var field in type.fields) {
          if (field.value != null) {
            continue;
          }
          comparisons.add(
            compareEqualsCode(field.type, field.name, 'other.${field.name}'),
          );
        }
        if (comparisons.isEmpty) {
          writeln('return true;');
        } else {
          var concatenated = comparisons.join(' &&\n    ');
          writeln('return $concatenated;');
        }
      });
      writeln('}');
      writeln('return false;');
    });
    writeln('}');
  }

  /// Emit the method for decoding an object from JSON.
  void emitObjectFromJsonConstructor(
    String className,
    TypeObject type,
    ImpliedType impliedType,
  ) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', { ${clientUriConverterKind.namedParameterString} }'
            : '';
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', ${clientUriConverterKind.namedArgumentString}'
            : '';

    var humanReadableNameString = _literalString(impliedType.humanReadableName);
    if (className == 'RefactoringFeedback') {
      writeln(
        'static RefactoringFeedback? fromJson(JsonDecoder jsonDecoder, '
        'String jsonPath, '
        'Object? json, '
        'Map<Object?, Object?> responseJson$namedParameters) {',
      );
      indent(() {
        writeln(
          'return refactoringFeedbackFromJson(jsonDecoder, jsonPath, '
          'json, responseJson$namedArguments);',
        );
      });
      writeln('}');
      return;
    }
    if (className == 'RefactoringOptions') {
      writeln(
        'static RefactoringOptions? fromJson(JsonDecoder jsonDecoder, '
        'String jsonPath, Object? json, RefactoringKind kind$namedParameters) {',
      );
      indent(() {
        writeln(
          'return refactoringOptionsFromJson(jsonDecoder, jsonPath, '
          'json, kind$namedArguments);',
        );
      });
      writeln('}');
      return;
    }

    writeln(
      'factory $className.fromJson(JsonDecoder jsonDecoder, String jsonPath, Object? json$namedParameters) {',
    );
    indent(() {
      writeln('json ??= {};');
      writeln('if (json is Map) {');
      indent(() {
        var args = <String>[];
        var optionalArgs = <String>[];
        for (var field in type.fields) {
          var fieldNameString = _literalString(field.name);
          var fieldAccessor = 'json[$fieldNameString]';
          var jsonPath = _literalString('\$jsonPath.${field.name}');
          var fieldValue = field.value;
          if (fieldValue is String) {
            var valueString = _literalString(fieldValue);
            writeln('if ($fieldAccessor != $valueString) {');
            indent(() {
              writeln(
                "throw jsonDecoder.mismatch(jsonPath, 'equal $fieldValue', json);",
              );
            });
            writeln('}');
            continue;
          }
          if (isOptionalConstructorArg(className, field)) {
            optionalArgs.add('${field.name}: ${field.name}');
          } else {
            args.add(field.name);
          }
          var typeStr = fieldDartType(field);
          writeln('$typeStr ${field.name};');
          writeln('if (json.containsKey($fieldNameString)) {');
          indent(() {
            var fieldType = field.type;
            var fromJson = fromJsonCode(
              fieldType,
            ).asSnippet(jsonPath, fieldAccessor);
            writeln('${field.name} = $fromJson;');
          });
          write('}');
          if (!field.optional) {
            writeln(' else {');
            indent(() {
              writeln(
                'throw jsonDecoder.mismatch(jsonPath, $fieldNameString);',
              );
            });
            writeln('}');
          } else {
            writeln();
          }
        }
        args.addAll(optionalArgs);
        writeln('return $className(${args.join(', ')});');
      });
      writeln('} else {');
      indent(() {
        writeln(
          'throw jsonDecoder.mismatch(jsonPath, $humanReadableNameString, json);',
        );
      });
      writeln('}');
    });
    writeln('}');
  }

  /// Emit the hashCode getter for an object class.
  void emitObjectHashCode(TypeObject? type, String className) {
    writeln('@override');
    writeln('int get hashCode => ');

    String hashAll(String value) => 'Object.hashAll($value)';

    String fieldValue(TypeObjectField field, {required bool single}) {
      if (field.value != null) {
        return field.value.hashCode.toString();
      } else {
        var name = field.name;
        var type = field.type;
        if (type is TypeList) {
          var nullableString = field.optional ? ' ?? []' : '';
          return hashAll(name + nullableString);
        } else if (type is TypeMap) {
          var nullable = field.optional ? '?' : '';
          return hashAll(
            '[...$nullable$name$nullable.keys,'
            ' ...$nullable$name$nullable.values]',
          );
        }
        return single ? '$name.hashCode' : name;
      }
    }

    indent(() {
      if (type == null) {
        writeln(' ${className.hashCode}');
      } else {
        var fields = type.fields;
        if (fields.isEmpty) {
          writeln('0');
        } else if (fields.length == 1) {
          var field = fields.single;
          write(fieldValue(field, single: true));
        } else {
          writeln('Object.hash(');
          for (var field in fields) {
            write(fieldValue(field, single: false));
            writeln(',');
          }
          writeln(')');
        }
      }
      writeln(';');
    });
  }

  /// If the class named [className] requires special constructors, emit them
  /// and return true.
  bool emitSpecialConstructors(String className) {
    switch (className) {
      case 'LinkedEditGroup':
        docComment([dom.Text('Construct an empty LinkedEditGroup.')]);
        writeln(
          'LinkedEditGroup.empty() : this(<Position>[], 0, <LinkedEditSuggestion>[]);',
        );
        return true;
      case 'RefactoringProblemSeverity':
        docComment([
          dom.Text(
            'Returns the [RefactoringProblemSeverity] with the maximal severity.',
          ),
        ]);
        writeln(
          'static RefactoringProblemSeverity? max(RefactoringProblemSeverity? a, RefactoringProblemSeverity? b) =>',
        );
        writeln('    maxRefactoringProblemSeverity(a, b);');
        return true;
      default:
        return false;
    }
  }

  /// If the class named [className] requires special getters, emit them and
  /// return true.
  bool emitSpecialGetters(String className) {
    switch (className) {
      case 'Element':
        for (var name in specialElementFlags.keys) {
          var flag = 'FLAG_${name.toUpperCase()}';
          writeln(
            'bool get ${camelJoin(['is', name])} => (flags & $flag) != 0;',
          );
        }
        return true;
      case 'SourceEdit':
        docComment([dom.Text('The end of the region to be modified.')]);
        writeln('int get end => offset + length;');
        return true;
      default:
        return false;
    }
  }

  /// If the class named [className] requires special methods, emit them and
  /// return true.
  bool emitSpecialMethods(String className) {
    switch (className) {
      case 'LinkedEditGroup':
        docComment([dom.Text('Add a new position and change the length.')]);
        writeln('void addPosition(Position position, int length) {');
        indent(() {
          writeln('positions.add(position);');
          writeln('this.length = length;');
        });
        writeln('}');
        writeln();
        docComment([dom.Text('Add a new suggestion.')]);
        writeln('void addSuggestion(LinkedEditSuggestion suggestion) {');
        indent(() {
          writeln('suggestions.add(suggestion);');
        });
        writeln('}');
        return true;
      case 'SourceChange':
        docComment([
          dom.Text('Adds [edit] to the [FileEdit] for the given [file].'),
        ]);
        writeln('void addEdit(String file, int fileStamp, SourceEdit edit) =>');
        writeln('    addEditToSourceChange(this, file, fileStamp, edit);');
        writeln();
        docComment([dom.Text('Adds the given [FileEdit].')]);
        writeln('void addFileEdit(SourceFileEdit edit) {');
        indent(() {
          writeln('edits.add(edit);');
        });
        writeln('}');
        writeln();
        docComment([dom.Text('Adds the given [LinkedEditGroup].')]);
        writeln('void addLinkedEditGroup(LinkedEditGroup linkedEditGroup) {');
        indent(() {
          writeln('linkedEditGroups.add(linkedEditGroup);');
        });
        writeln('}');
        writeln();
        docComment([
          dom.Text(
            'Returns the [FileEdit] for the given [file], maybe `null`.',
          ),
        ]);
        writeln('SourceFileEdit? getFileEdit(String file) =>');
        writeln('    getChangeFileEdit(this, file);');
        return true;
      case 'SourceEdit':
        docComment([
          dom.Text('Get the result of applying the edit to the given [code].'),
        ]);
        writeln('String apply(String code) => applyEdit(code, this);');
        return true;
      case 'SourceFileEdit':
        docComment([dom.Text('Adds the given [Edit] to the list.')]);
        writeln('void add(SourceEdit edit) => addEditForSource(this, edit);');
        writeln();
        docComment([dom.Text('Adds the given [Edit]s.')]);
        writeln('void addAll(Iterable<SourceEdit> edits) =>');
        writeln('    addAllEditsForSource(this, edits);');
        return true;
      default:
        return false;
    }
  }

  /// If the class named [className] requires special static members, emit them
  /// and return true.
  bool emitSpecialStaticMembers(String className) {
    switch (className) {
      case 'Element':
        var makeFlagsArgs = <String>[];
        var makeFlagsStatements = <String>[];
        specialElementFlags.forEach((String name, String value) {
          var flag = 'FLAG_${name.toUpperCase()}';
          var camelName = camelJoin(['is', name]);
          writeln('static const int $flag = $value;');
          makeFlagsArgs.add('$camelName = false');
          makeFlagsStatements.add('if ($camelName) flags |= $flag;');
        });
        writeln();
        writeln('static int makeFlags({${makeFlagsArgs.join(', ')}}) {');
        indent(() {
          writeln('int flags = 0;');
          for (var statement in makeFlagsStatements) {
            writeln(statement);
          }
          writeln('return flags;');
        });
        writeln('}');
        return true;
      case 'SourceEdit':
        docComment([
          dom.Text(
            'Get the result of applying a set of [edits] to the given '
            '[code]. Edits are applied in the order they appear in [edits].',
          ),
        ]);
        writeln(
          'static String applySequence(String code, List<SourceEdit> edits) =>',
        );
        writeln('    applySequenceOfEdits(code, edits);');
        return true;
      default:
        return false;
    }
  }

  /// Emit the toJson() code for an object class.
  void emitToJsonMember(TypeObject type) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? '{ ${clientUriConverterKind.namedParameterString} }'
            : '';

    writeln('@override');
    writeln('Map<String, Object> toJson($namedParameters) {');
    indent(() {
      var resultMapName =
          type.fields.any((field) => field.name == 'result')
              ? 'result_'
              : 'result';
      writeln('var $resultMapName = <String, Object>{};');
      for (var field in type.fields) {
        var fieldNameString = _literalString(field.name);
        var fieldValue = field.value;
        if (fieldValue is String) {
          var valueString = _literalString(fieldValue);
          writeln('$resultMapName[$fieldNameString] = $valueString;');
          continue;
        }
        var fieldToJson = toJsonCode(field.type).asSnippet(field.name);
        var populateField = '$resultMapName[$fieldNameString] = $fieldToJson;';
        if (field.optional) {
          var name = field.name;
          writeln('var $name = this.$name;');
          writeln('if ($name != null) {');
          indent(() {
            writeln(populateField);
          });
          writeln('}');
        } else {
          writeln(populateField);
        }
      }
      writeln('return $resultMapName;');
    });
    writeln('}');
  }

  /// Emit the toNotification() code for a class, if appropriate. Returns true
  /// if code was emitted.
  bool emitToNotificationMember(ImpliedType impliedType) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? '{ ${clientUriConverterKind.namedParameterString} }'
            : '';
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? clientUriConverterKind.namedArgumentString
            : '';

    if (impliedType.kind == 'notificationParams') {
      writeln('Notification toNotification($namedParameters) {');
      indent(() {
        var eventString = _literalString(
          (impliedType.apiNode as Notification).longEvent,
        );
        var jsonPart =
            impliedType.type != null ? 'toJson($namedArguments)' : 'null';
        writeln('return Notification($eventString, $jsonPart);');
      });
      writeln('}');
      return true;
    }
    return false;
  }

  /// Emit the toRequest() code for a class, if appropriate. Returns true if
  /// code was emitted.
  bool emitToRequestMember(ImpliedType impliedType) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', { ${clientUriConverterKind.namedParameterString} }'
            : '';
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? clientUriConverterKind.namedArgumentString
            : '';

    if (impliedType.kind == 'requestParams') {
      writeln('@override');
      writeln('Request toRequest(String id$namedParameters) {');
      indent(() {
        var methodString = _literalString(
          (impliedType.apiNode as Request).longMethod,
        );
        if (impliedType.type != null) {
          writeln(
            'return Request(id, $methodString, toJson($namedArguments));',
          );
        } else {
          writeln('return Request(id, $methodString);');
        }
      });
      writeln('}');
      return true;
    }
    return false;
  }

  /// Emit the toResponse() code for a class, if appropriate. Returns true if
  /// code was emitted.
  bool emitToResponseMember(ImpliedType impliedType) {
    var namedParameters =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', { ${clientUriConverterKind.namedParameterString} }'
            : '';
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? clientUriConverterKind.namedArgumentString
            : '';

    if (impliedType.kind == 'requestResult') {
      writeln('@override');
      if (responseRequiresRequestTime) {
        writeln(
          'Response toResponse(String id, int requestTime$namedParameters) {',
        );
      } else {
        writeln('Response toResponse(String id$namedParameters) {');
      }
      indent(() {
        if (impliedType.type != null) {
          if (responseRequiresRequestTime) {
            writeln(
              'return Response(id, requestTime, result: toJson($namedArguments));',
            );
          } else {
            writeln('return Response(id, result: toJson($namedArguments));');
          }
        } else {
          if (responseRequiresRequestTime) {
            writeln('return Response(id, requestTime);');
          } else {
            writeln('return Response(id);');
          }
        }
      });
      writeln('}');
      return true;
    }
    return false;
  }

  /// Compute the code necessary to translate [type] from JSON.
  FromJsonCode fromJsonCode(TypeDecl type) {
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? ', ${clientUriConverterKind.namedArgumentString}'
            : '';

    if (type is TypeReference) {
      var referencedDefinition = api.types[type.typeName];
      if (referencedDefinition != null) {
        var referencedType = referencedDefinition.type;
        if (referencedType is TypeObject || referencedType is TypeEnum) {
          return FromJsonSnippet((String jsonPath, String json) {
            var typeName = dartType(type);
            if (typeName == 'RefactoringFeedback') {
              return '$typeName.fromJson(jsonDecoder, $jsonPath, $json, json$namedArguments)';
            } else if (typeName == 'RefactoringOptions') {
              return '$typeName.fromJson(jsonDecoder, $jsonPath, $json, kind$namedArguments)';
            } else {
              return '$typeName.fromJson(jsonDecoder, $jsonPath, $json$namedArguments)';
            }
          });
        } else if (clientUriConverterKind != CodegenUriConverterKind.none &&
            referencedDefinition.name == 'FilePath') {
          // TODO(dantup): Ensure if the client sends us filepaths instead of
          //  URIs that we generate good error responses.
          return FromJsonSnippet(
            (jsonPath, json) =>
                'clientUriConverter?.fromClientFilePath(jsonDecoder.decodeString($jsonPath, $json))'
                ' ?? jsonDecoder.decodeString($jsonPath, $json)',
          );
        } else {
          return fromJsonCode(referencedType);
        }
      } else {
        switch (type.typeName) {
          case 'String':
            return FromJsonFunction('jsonDecoder.decodeString');
          case 'bool':
            return FromJsonFunction('jsonDecoder.decodeBool');
          case 'double':
            return FromJsonFunction(
              'jsonDecoder.decodeDouble',
              castType: 'Object',
            );
          case 'int':
          case 'long':
            return FromJsonFunction('jsonDecoder.decodeInt');
          case 'object':
            return FromJsonSnippet((jsonPath, json) => '$json as Object');
          default:
            throw Exception('Unexpected type name ${type.typeName}');
        }
      }
    } else if (type is TypeMap) {
      FromJsonCode keyCode;
      var referencedDefinition = api.types[type.keyType.typeName];
      if (dartType(type.keyType) != 'String' ||
          (clientUriConverterKind != CodegenUriConverterKind.none &&
              referencedDefinition?.name == 'FilePath')) {
        keyCode = fromJsonCode(type.keyType);
      } else {
        keyCode = FromJsonIdentity();
      }
      var valueCode = fromJsonCode(type.valueType);
      if (keyCode.isIdentity && valueCode.isIdentity) {
        return FromJsonFunction('jsonDecoder.decodeMap');
      } else {
        return FromJsonSnippet((String jsonPath, String json) {
          var result = StringBuffer();
          result.write('jsonDecoder.decodeMap($jsonPath, $json');
          if (!keyCode.isIdentity) {
            result.write(', keyDecoder: ${keyCode.asClosure}');
          }
          if (!valueCode.isIdentity) {
            result.write(', valueDecoder: ${valueCode.asClosure}');
          }
          result.write(')');
          return result.toString();
        });
      }
    } else if (type is TypeList) {
      var itemCode = fromJsonCode(type.itemType);
      if (itemCode.isIdentity) {
        return FromJsonFunction('jsonDecoder.decodeList');
      } else {
        return FromJsonSnippet(
          (String jsonPath, String json) =>
              'jsonDecoder.decodeList($jsonPath, $json, ${itemCode.asClosure})',
        );
      }
    } else if (type is TypeUnion) {
      var decoders = <String>[];
      for (var choice in type.choices) {
        var resolvedChoice = resolveTypeReferenceChain(choice);
        if (resolvedChoice is TypeObject) {
          var field = resolvedChoice.getField(type.field);
          if (field == null) {
            throw Exception(
              'Each choice in the union needs a field named ${type.field}',
            );
          }
          if (field.value == null) {
            throw Exception(
              'Each choice in the union needs a constant value for the field ${type.field}',
            );
          }
          var closure = fromJsonCode(choice).asClosure;
          decoders.add('${_literalString(field.value as String)}: $closure');
        } else {
          throw Exception('Union types must be unions of objects.');
        }
      }
      return FromJsonSnippet((String jsonPath, String json) {
        var field = _literalString(type.field);
        var decodersString = decoders.join(', ');
        return 'jsonDecoder.decodeUnion('
            '$jsonPath, $json, $field, {$decodersString})';
      });
    } else {
      throw Exception("Can't convert $type from JSON");
    }
  }

  /// Return a list of the classes to be emitted.
  List<ImpliedType> getClassesToEmit() {
    var types =
        impliedTypes.values.where((ImpliedType type) {
          var node = type.apiNode;
          return !(node is TypeDefinition && node.isExternal);
        }).toList();
    types.sort(
      (first, second) =>
          capitalize(first.camelName).compareTo(capitalize(second.camelName)),
    );
    return types;
  }

  /// True if the constructor argument for the given field should be optional.
  bool isOptionalConstructorArg(String className, TypeObjectField field) {
    if (field.optional) {
      return true;
    }
    var forceOptional = _optionalConstructorArguments[className];
    if (forceOptional != null && forceOptional.contains(field.name)) {
      return true;
    }
    return false;
  }

  /// Compute the code necessary to convert [type] to JSON.
  ToJsonCode toJsonCode(TypeDecl type) {
    var namedArguments =
        clientUriConverterKind != CodegenUriConverterKind.none
            ? clientUriConverterKind.namedArgumentString
            : '';

    var resolvedType = resolveTypeReferenceChain(type);
    if (type is TypeReference &&
        clientUriConverterKind != CodegenUriConverterKind.none &&
        type.typeName == 'FilePath') {
      return ToJsonSnippet(
        dartType(type),
        (String value) =>
            'clientUriConverter?.toClientFilePath($value) ?? $value',
      );
    } else if (resolvedType is TypeReference) {
      return ToJsonIdentity(dartType(type));
    } else if (resolvedType is TypeList) {
      var itemCode = toJsonCode(resolvedType.itemType);
      if (itemCode.isIdentity) {
        return ToJsonIdentity(dartType(type));
      } else {
        return ToJsonSnippet(
          dartType(type),
          (String value) => '$value.map(${itemCode.asClosure}).toList()',
        );
      }
    } else if (resolvedType is TypeMap) {
      ToJsonCode keyCode;
      var referencedDefinition = api.types[resolvedType.keyType.typeName];
      if (dartType(resolvedType.keyType) != 'String' ||
          (clientUriConverterKind != CodegenUriConverterKind.none &&
              referencedDefinition?.name == 'FilePath')) {
        keyCode = toJsonCode(resolvedType.keyType);
      } else {
        keyCode = ToJsonIdentity(dartType(resolvedType.keyType));
      }
      var valueCode = toJsonCode(resolvedType.valueType);
      if (keyCode.isIdentity && valueCode.isIdentity) {
        return ToJsonIdentity(dartType(resolvedType));
      } else {
        return ToJsonSnippet(dartType(type), (String value) {
          var result = StringBuffer();
          result.write('mapMap($value');
          if (!keyCode.isIdentity) {
            result.write(', keyCallback: ${keyCode.asClosure}');
          }
          if (!valueCode.isIdentity) {
            result.write(', valueCallback: ${valueCode.asClosure}');
          }
          result.write(')');
          return result.toString();
        });
      }
    } else if (resolvedType is TypeUnion) {
      for (var choice in resolvedType.choices) {
        if (resolveTypeReferenceChain(choice) is! TypeObject) {
          throw Exception('Union types must be unions of objects');
        }
      }
      return ToJsonSnippet(
        dartType(type),
        (String value) => '($value as dynamic).toJson()',
      );
    } else if (resolvedType is TypeObject || resolvedType is TypeEnum) {
      return ToJsonSnippet(
        dartType(type),
        (String value) => '$value.toJson($namedArguments)',
      );
    } else {
      throw Exception("Can't convert $resolvedType from JSON");
    }
  }

  @override
  void visitApi() {
    outputHeader(year: '2017');
    writeln();
    emitImports();
    emitClasses(getClassesToEmit());
  }

  /// Create a string literal that evaluates to [s].
  String _literalString(String s) {
    if (s.contains("'")) {
      if (s.contains('"')) {
        return json.encode(s);
      }
      return '"$s"';
    }
    return "'$s'";
  }
}

/// The kind of URI converter that should be used in generated toJson/fromJson
/// methods.
enum CodegenUriConverterKind {
  /// No URI/Path conversion is done.
  ///
  /// This is used in analysis_server_client where the client code should handle
  /// getting/setting the raw values based on server parameters and no
  /// conversion is ever done.
  none,

  /// URI/Path conversion is done optionally with a UriConverter parameter.
  ///
  /// This is used in analyzer_plugin common protocol classes that are used by
  /// both server and plugins. Plugin protocol classes will not pass a converter
  /// but server classes will.
  optionalParameter,

  /// URI/Path conversion is done with a required converter.
  ///
  /// This is used in analysis_server where all calls should use the
  /// server-configured converter.
  requiredParameter;

  /// Dart code for a named argument to pass the converter to another
  /// `toJson`/`fromJson` method.
  ///
  /// Throws if this value is [none].
  String get namedArgumentString => switch (this) {
    optionalParameter ||
    requiredParameter => 'clientUriConverter: clientUriConverter',
    _ => throw "'namedArgumentString' cannot be used for 'none'",
  };

  /// Dart code for a named parameter for the converter.
  ///
  /// Throws if this value is [none].
  String get namedParameterString => switch (this) {
    optionalParameter => 'ClientUriConverter? clientUriConverter',
    requiredParameter => 'required ClientUriConverter? clientUriConverter',
    _ => throw "'namedParameterString' can only be used for 'parameter'",
  };
}

/// Container for code that can be used to translate a data type from JSON.
abstract class FromJsonCode {
  /// Get the translation code in the form of a closure.
  String get asClosure;

  /// True if the data type is already in JSON form, so the translation is the
  /// identity function.
  bool get isIdentity;

  /// Get the translation code in the form of a code snippet, where [jsonPath]
  /// is the variable holding the JSON path, and [json] is the variable holding
  /// the raw JSON.
  String asSnippet(String jsonPath, String json);
}

/// Representation of FromJsonCode for a function defined elsewhere.
class FromJsonFunction extends FromJsonCode {
  @override
  final String asClosure;

  final String? castType;

  FromJsonFunction(this.asClosure, {this.castType});

  @override
  bool get isIdentity => false;

  @override
  String asSnippet(String jsonPath, String json) =>
      castType == null
          ? '$asClosure($jsonPath, $json)'
          : '$asClosure($jsonPath, $json as $castType)';
}

/// Representation of FromJsonCode for the identity transformation.
class FromJsonIdentity extends FromJsonSnippet {
  FromJsonIdentity() : super((String jsonPath, String json) => json);

  @override
  bool get isIdentity => true;
}

/// Representation of FromJsonCode for a snippet of inline code.
class FromJsonSnippet extends FromJsonCode {
  /// Callback that can be used to generate the code snippet, once the names
  /// of the [jsonPath] and [json] variables are known.
  final FromJsonSnippetCallback callback;

  FromJsonSnippet(this.callback);

  @override
  String get asClosure =>
      '(String jsonPath, Object? json) => ${callback('jsonPath', 'json')}';

  @override
  bool get isIdentity => false;

  @override
  String asSnippet(String jsonPath, String json) => callback(jsonPath, json);
}

/// Container for code that can be used to translate a data type to JSON.
abstract class ToJsonCode {
  /// Get the translation code in the form of a closure.
  String get asClosure;

  /// True if the data type is already in JSON form, so the translation is the
  /// identity function.
  bool get isIdentity;

  /// Get the translation code in the form of a code snippet, where [value]
  /// is the variable holding the object to be translated.
  String asSnippet(String value);
}

/// Representation of ToJsonCode for a function defined elsewhere.
class ToJsonFunction extends ToJsonCode {
  @override
  final String asClosure;

  ToJsonFunction(this.asClosure);

  @override
  bool get isIdentity => false;

  @override
  String asSnippet(String value) => '$asClosure($value)';
}

/// Representation of FromJsonCode for the identity transformation.
class ToJsonIdentity extends ToJsonSnippet {
  ToJsonIdentity(String type) : super(type, (String value) => value);

  @override
  bool get isIdentity => true;
}

/// Representation of ToJsonCode for a snippet of inline code.
class ToJsonSnippet extends ToJsonCode {
  /// Callback that can be used to generate the code snippet, once the name
  /// of the [value] variable is known.
  final ToJsonSnippetCallback callback;

  /// Dart type of the [value] variable.
  final String type;

  ToJsonSnippet(this.type, this.callback);

  @override
  String get asClosure => '($type value) => ${callback('value')}';

  @override
  bool get isIdentity => false;

  @override
  String asSnippet(String value) => callback(value);
}
