// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/messages/codes.dart'
    show
        LocatedMessage,
        Message,
        MessageCode,
        codeBuiltInIdentifierInDeclaration,
        messageAbstractLateField,
        messageAbstractStaticField,
        messageConstConstructorWithBody,
        messageConstFactory,
        messageConstructorWithTypeParameters,
        messageDirectiveAfterDeclaration,
        messageExpectedStatement,
        messageExternalLateField,
        messageFieldInitializerOutsideConstructor,
        messageIllegalAssignmentToNonAssignable,
        messageInterpolationInUri,
        messageInvalidInitializer,
        messageInvalidSuperInInitializer,
        messageInvalidThisInInitializer,
        messageMissingAssignableSelector,
        messageNativeClauseShouldBeAnnotation,
        messageOperatorWithTypeParameters,
        messagePositionalAfterNamedArgument,
        templateDuplicateLabelInSwitchStatement,
        templateExpectedIdentifier,
        templateExperimentNotEnabled,
        templateExtraneousModifier,
        templateInternalProblemUnhandled;
import 'package:_fe_analyzer_shared/src/parser/parser.dart'
    show
        Assert,
        BlockKind,
        boolFromToken,
        ConstructorReferenceContext,
        DeclarationHeaderKind,
        DeclarationKind,
        doubleFromToken,
        FormalParameterKind,
        IdentifierContext,
        intFromToken,
        MemberKind,
        optional,
        Parser;
import 'package:_fe_analyzer_shared/src/parser/quote.dart';
import 'package:_fe_analyzer_shared/src/parser/stack_listener.dart'
    show NullValues, StackListener;
import 'package:_fe_analyzer_shared/src/scanner/errors.dart'
    show translateErrorToken;
import 'package:_fe_analyzer_shared/src/scanner/scanner.dart';
import 'package:_fe_analyzer_shared/src/scanner/token.dart'
    show KeywordToken, StringToken, SyntheticToken;
import 'package:_fe_analyzer_shared/src/scanner/token_constants.dart';
import 'package:_fe_analyzer_shared/src/util/null_value.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/token.dart' show Token, TokenType;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/dart/error/syntactic_errors.dart';
import 'package:analyzer/src/fasta/doc_comment_builder.dart';
import 'package:analyzer/src/fasta/error_converter.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/summary2/ast_binary_tokens.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

/// A parser listener that builds the analyzer's AST structure.
class AstBuilder extends StackListener {
  final FastaErrorReporter diagnosticReporter;
  final Uri fileUri;
  ScriptTagImpl? scriptTag;
  final List<DirectiveImpl> directives = [];
  final List<CompilationUnitMemberImpl> declarations = [];
  final List<AstNodeImpl> invalidNodes = [];

  @override
  final Uri uri;

  /// The parser that uses this listener, used to parse optional parts, e.g.
  /// `native` support.
  late Parser parser;

  /// The class like declaration being parsed.
  _ClassLikeDeclarationBuilder? _classLikeBuilder;

  /// If true, this is building a full AST. Otherwise, only create method
  /// bodies.
  final bool isFullAst;

  /// `true` if the `native` clause is allowed
  /// in class, method, and function declarations.
  ///
  /// This is being replaced by the @native(...) annotation.
  //
  // TODO(danrubel): Move this flag to a better location
  // and should only be true if either:
  // * The current library is a platform library
  // * The current library has an import that uses the scheme "dart-ext".
  bool allowNativeClause = false;

  StringLiteralImpl? nativeName;

  bool parseFunctionBodies = true;

  /// Whether the 'augmentations' feature is enabled.
  final bool enableAugmentations;

  /// `true` if triple-shift behavior is enabled
  final bool enableTripleShift;

  /// `true` if nonfunction-type-aliases behavior is enabled
  final bool enableNonFunctionTypeAliases;

  /// `true` if variance behavior is enabled
  final bool enableVariance;

  /// `true` if constructor tearoffs are enabled
  final bool enableConstructorTearoffs;

  /// `true` if named arguments anywhere are enabled
  final bool enableNamedArgumentsAnywhere;

  /// `true` if super parameters are enabled
  final bool enableSuperParameters;

  /// `true` if enhanced enums are enabled
  final bool enableEnhancedEnums;

  /// Whether the 'enhanced_parts' feature is enabled.
  final bool enableEnhancedParts;

  /// Whether the 'macros' feature is enabled.
  final bool enableMacros;

  /// `true` if records are enabled
  final bool enableRecords;

  /// `true` if unnamed-library behavior is enabled
  final bool enableUnnamedLibraries;

  /// `true` if inline-class is enabled
  final bool enableInlineClass;

  /// `true` if sealed-class is enabled
  final bool enableSealedClass;

  /// `true` if class-modifiers is enabled
  final bool enableClassModifiers;

  /// `true` if null-aware elements is enabled
  final bool enableNullAwareElements;

  /// `true` if dot-shorthands is enabled
  final bool enabledDotShorthands;

  /// `true` if digit-separators is enabled.
  final bool _enableDigitSeparators;

  final FeatureSet _featureSet;

  final LibraryLanguageVersion _languageVersion;

  final LineInfo _lineInfo;

  AstBuilder(
    DiagnosticReporter? errorReporter,
    this.fileUri,
    this.isFullAst,
    this._featureSet,
    this._languageVersion,
    this._lineInfo, [
    Uri? uri,
  ]) : diagnosticReporter = FastaErrorReporter(errorReporter),
       enableAugmentations = _featureSet.isEnabled(Feature.augmentations),
       enableTripleShift = _featureSet.isEnabled(Feature.triple_shift),
       enableNonFunctionTypeAliases = _featureSet.isEnabled(
         Feature.nonfunction_type_aliases,
       ),
       enableVariance = _featureSet.isEnabled(Feature.variance),
       enableConstructorTearoffs = _featureSet.isEnabled(
         Feature.constructor_tearoffs,
       ),
       enableNamedArgumentsAnywhere = _featureSet.isEnabled(
         Feature.named_arguments_anywhere,
       ),
       enableSuperParameters = _featureSet.isEnabled(Feature.super_parameters),
       enableEnhancedEnums = _featureSet.isEnabled(Feature.enhanced_enums),
       enableEnhancedParts = _featureSet.isEnabled(Feature.enhanced_parts),
       enableMacros = _featureSet.isEnabled(Feature.macros),
       enableRecords = _featureSet.isEnabled(Feature.records),
       enableUnnamedLibraries = _featureSet.isEnabled(Feature.unnamedLibraries),
       enableInlineClass = _featureSet.isEnabled(Feature.inline_class),
       enableSealedClass = _featureSet.isEnabled(Feature.sealed_class),
       enableClassModifiers = _featureSet.isEnabled(Feature.class_modifiers),
       enableNullAwareElements = _featureSet.isEnabled(
         Feature.null_aware_elements,
       ),
       enabledDotShorthands = _featureSet.isEnabled(Feature.dot_shorthands),
       _enableDigitSeparators = _featureSet.isEnabled(Feature.digit_separators),
       uri = uri ?? fileUri;

  @override
  bool get isDartLibrary =>
      uri.isScheme("dart") || uri.isScheme("org-dartlang-sdk");

  @override
  void addProblem(
    Message message,
    int charOffset,
    int length, {
    bool wasHandled = false,
    List<LocatedMessage>? context,
  }) {
    if (directives.isEmpty &&
        (message.code.analyzerCodes?.contains(
              'NON_PART_OF_DIRECTIVE_IN_PART',
            ) ??
            false)) {
      message = messageDirectiveAfterDeclaration;
    }
    diagnosticReporter.reportMessage(message, charOffset, length);
  }

  @override
  void beginAsOperatorType(Token asOperator) {}

  @override
  void beginCascade(Token token) {
    assert(optional('..', token) || optional('?..', token));
    debugEvent("beginCascade");

    var expression = pop() as ExpressionImpl;
    push(token);
    if (expression is CascadeExpressionImpl) {
      push(expression);
    } else {
      push(
        CascadeExpressionImpl(
          target: expression,
          cascadeSections: <ExpressionImpl>[],
        ),
      );
    }
    push(NullValues.CascadeReceiver);
  }

  @override
  void beginClassDeclaration(
    Token begin,
    Token? abstractToken,
    Token? macroToken,
    Token? sealedToken,
    Token? baseToken,
    Token? interfaceToken,
    Token? finalToken,
    Token? augmentToken,
    Token? mixinToken,
    Token name,
  ) {
    assert(_classLikeBuilder == null);
    push(_Modifiers()..abstractKeyword = abstractToken);
    if (!enableMacros) {
      if (macroToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.macros,
          startToken: macroToken,
        );
        // Pretend that 'macro' didn't occur while this feature is incomplete.
        macroToken = null;
      }
    }
    if (!enableSealedClass) {
      if (sealedToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.sealed_class,
          startToken: sealedToken,
        );
        // Pretend that 'sealed' didn't occur while this feature is incomplete.
        sealedToken = null;
      }
    }
    if (!enableClassModifiers) {
      if (baseToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: baseToken,
        );
        // Pretend that 'base' didn't occur while this feature is incomplete.
        baseToken = null;
      }
      if (interfaceToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: interfaceToken,
        );
        // Pretend that 'interface' didn't occur while this feature is
        // incomplete.
        interfaceToken = null;
      }
      if (finalToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: finalToken,
        );
        // Pretend that 'final' didn't occur while this feature is
        // incomplete.
        finalToken = null;
      }
      if (mixinToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: mixinToken,
        );
        // Pretend that 'mixin' didn't occur while this feature is incomplete.
        mixinToken = null;
      }
    }
    push(macroToken ?? NullValues.Token);
    push(sealedToken ?? NullValues.Token);
    push(baseToken ?? NullValues.Token);
    push(interfaceToken ?? NullValues.Token);
    push(finalToken ?? NullValues.Token);
    push(augmentToken ?? NullValues.Token);
    push(mixinToken ?? NullValues.Token);
  }

  @override
  void beginCompilationUnit(Token token) {
    push(token);
  }

  @override
  void beginConstantPattern(Token? constKeyword) {}

  @override
  void beginEnum(Token enumKeyword) {}

  @override
  void beginExtensionDeclaration(
    Token? augmentKeyword,
    Token extensionKeyword,
    Token? nameToken,
  ) {
    assert(optional('extension', extensionKeyword));
    assert(_classLikeBuilder == null);
    debugEvent("ExtensionHeader");

    var typeParameters = pop() as TypeParameterListImpl?;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, extensionKeyword);

    _classLikeBuilder = _ExtensionDeclarationBuilder(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      extensionKeyword: extensionKeyword,
      name: nameToken,
      typeParameters: typeParameters,
      leftBracket: Tokens.openCurlyBracket(),
      rightBracket: Tokens.closeCurlyBracket(),
    );
  }

  @override
  void beginExtensionTypeDeclaration(
    Token? augmentKeyword,
    Token extensionKeyword,
    Token name,
  ) {
    assert(optional('extension', extensionKeyword));
    assert(_classLikeBuilder == null);

    var typeParameters = pop() as TypeParameterListImpl?;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, extensionKeyword);

    _classLikeBuilder = _ExtensionTypeDeclarationBuilder(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      extensionKeyword: extensionKeyword,
      name: name,
      typeParameters: typeParameters,
      leftBracket: Tokens.openCurlyBracket(),
      rightBracket: Tokens.closeCurlyBracket(),
    );
  }

  @override
  void beginFactoryMethod(
    DeclarationKind declarationKind,
    Token lastConsumed,
    Token? externalToken,
    Token? constToken,
  ) {
    push(
      _Modifiers()
        ..externalKeyword = externalToken
        ..finalConstOrVarKeyword = constToken,
    );
  }

  @override
  void beginFormalParameter(
    Token token,
    MemberKind kind,
    Token? requiredToken,
    Token? covariantToken,
    Token? varFinalOrConst,
  ) {
    push(
      _Modifiers()
        ..covariantKeyword = covariantToken
        ..finalConstOrVarKeyword = varFinalOrConst
        ..requiredToken = requiredToken,
    );
  }

  @override
  void beginFormalParameterDefaultValueExpression() {}

  @override
  void beginIfControlFlow(Token ifToken) {
    push(ifToken);
  }

  @override
  void beginIsOperatorType(Token asOperator) {}

  @override
  void beginLibraryAugmentation(Token augmentKeyword, Token libraryKeyword) {}

  @override
  void beginLiteralString(Token literalString) {
    assert(identical(literalString.kind, STRING_TOKEN));
    debugEvent("beginLiteralString");

    push(literalString);
  }

  @override
  void beginMetadataStar(Token token) {
    debugEvent("beginMetadataStar");
  }

  @override
  void beginMethod(
    DeclarationKind declarationKind,
    Token? augmentToken,
    Token? externalToken,
    Token? staticToken,
    Token? covariantToken,
    Token? varFinalOrConst,
    Token? getOrSet,
    Token name,
    String? enclosingDeclarationName,
  ) {
    _Modifiers modifiers = _Modifiers();
    if (augmentToken != null) {
      assert(augmentToken.isModifier);
      modifiers.augmentKeyword = augmentToken;
    }
    if (externalToken != null) {
      assert(externalToken.isModifier);
      modifiers.externalKeyword = externalToken;
    }
    if (staticToken != null) {
      assert(staticToken.isModifier);
      var builder = _classLikeBuilder;
      if (builder is! _ClassDeclarationBuilder ||
          builder.name.lexeme != name.lexeme ||
          getOrSet != null) {
        modifiers.staticKeyword = staticToken;
      }
    }
    if (covariantToken != null) {
      assert(covariantToken.isModifier);
      modifiers.covariantKeyword = covariantToken;
    }
    if (varFinalOrConst != null) {
      assert(varFinalOrConst.isModifier);
      modifiers.finalConstOrVarKeyword = varFinalOrConst;
    }
    push(modifiers);
  }

  @override
  void beginMixinDeclaration(
    Token beginToken,
    Token? augmentToken,
    Token? baseToken,
    Token mixinKeyword,
    Token name,
  ) {
    assert(_classLikeBuilder == null);
    if (!enableClassModifiers) {
      if (baseToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: baseToken,
        );
        // Pretend that 'base' didn't occur while this feature is incomplete.
        baseToken = null;
      }
    }
    push(augmentToken ?? NullValues.Token);
    push(baseToken ?? NullValues.Token);
  }

  @override
  void beginNamedMixinApplication(
    Token begin,
    Token? abstractToken,
    Token? macroToken,
    Token? sealedToken,
    Token? baseToken,
    Token? interfaceToken,
    Token? finalToken,
    Token? augmentToken,
    Token? mixinToken,
    Token name,
  ) {
    push(_Modifiers()..abstractKeyword = abstractToken);
    if (!enableMacros) {
      if (macroToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.macros,
          startToken: macroToken,
        );
        // Pretend that 'macro' didn't occur while this feature is incomplete.
        macroToken = null;
      }
    }
    if (!enableSealedClass) {
      if (sealedToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.sealed_class,
          startToken: sealedToken,
        );
        // Pretend that 'sealed' didn't occur while this feature is incomplete.
        sealedToken = null;
      }
    }
    if (!enableClassModifiers) {
      if (baseToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: baseToken,
        );
        // Pretend that 'base' didn't occur while this feature is incomplete.
        baseToken = null;
      }
      if (interfaceToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: interfaceToken,
        );
        // Pretend that 'interface' didn't occur while this feature is
        // incomplete.
        interfaceToken = null;
      }
      if (finalToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: finalToken,
        );
        // Pretend that 'final' didn't occur while this feature is incomplete.
        finalToken = null;
      }
      if (mixinToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.class_modifiers,
          startToken: mixinToken,
        );
        // Pretend that 'mixin' didn't occur while this feature is incomplete.
        mixinToken = null;
      }
    }
    push(macroToken ?? NullValues.Token);
    push(sealedToken ?? NullValues.Token);
    push(baseToken ?? NullValues.Token);
    push(interfaceToken ?? NullValues.Token);
    push(finalToken ?? NullValues.Token);
    push(augmentToken ?? NullValues.Token);
    push(mixinToken ?? NullValues.Token);
  }

  @override
  void beginPattern(Token token) {
    debugEvent("Pattern");
  }

  @override
  void beginPatternGuard(Token when) {
    debugEvent("PatternGuard");
  }

  @override
  void beginPrimaryConstructor(Token beginToken) {
    debugEvent("PrimaryConstructor");
  }

  @override
  void beginSwitchCaseWhenClause(Token when) {
    debugEvent("PatternSwitchCaseGuard");
  }

  @override
  void beginTopLevelMethod(
    Token lastConsumed,
    Token? augmentToken,
    Token? externalToken,
  ) {
    push(
      _Modifiers()
        ..augmentKeyword = augmentToken
        ..externalKeyword = externalToken,
    );
  }

  @override
  void beginTypeVariable(Token token) {
    debugEvent("beginTypeVariable");
    var name = pop() as SimpleIdentifierImpl;
    var metadata = pop() as List<AnnotationImpl>?;

    var comment = _findComment(metadata, name.beginToken);
    var typeParameter = TypeParameterImpl(
      comment: comment,
      metadata: metadata,
      varianceKeyword: null,
      name: name.token,
      extendsKeyword: null,
      bound: null,
    );
    push(typeParameter);
  }

  @override
  void beginVariablesDeclaration(
    Token token,
    Token? lateToken,
    Token? varFinalOrConst,
  ) {
    debugEvent("beginVariablesDeclaration");
    if (varFinalOrConst != null || lateToken != null) {
      push(
        _Modifiers()
          ..finalConstOrVarKeyword = varFinalOrConst
          ..lateToken = lateToken,
      );
    } else {
      push(NullValues.Modifiers);
    }
  }

  ConstructorInitializerImpl? buildInitializer(Object initializerObject) {
    if (initializerObject is FunctionExpressionInvocationImpl) {
      var function = initializerObject.function;
      if (function is SuperExpressionImpl) {
        return SuperConstructorInvocationImpl(
          superKeyword: function.superKeyword,
          period: null,
          constructorName: null,
          argumentList: initializerObject.argumentList,
        );
      }
      if (function is ThisExpressionImpl) {
        return RedirectingConstructorInvocationImpl(
          thisKeyword: function.thisKeyword,
          period: null,
          constructorName: null,
          argumentList: initializerObject.argumentList,
        );
      }
      return null;
    }

    if (initializerObject is MethodInvocationImpl) {
      var target = initializerObject.target;
      if (target is SuperExpressionImpl) {
        return SuperConstructorInvocationImpl(
          superKeyword: target.superKeyword,
          period: initializerObject.operator,
          constructorName: initializerObject.methodName,
          argumentList: initializerObject.argumentList,
        );
      }
      if (target is ThisExpressionImpl) {
        return RedirectingConstructorInvocationImpl(
          thisKeyword: target.thisKeyword,
          period: initializerObject.operator,
          constructorName: initializerObject.methodName,
          argumentList: initializerObject.argumentList,
        );
      }
      return buildInitializerTargetExpressionRecovery(
        target,
        initializerObject,
      );
    }

    if (initializerObject is PropertyAccessImpl) {
      return buildInitializerTargetExpressionRecovery(
        initializerObject.target,
        initializerObject,
      );
    }

    if (initializerObject is AssignmentExpressionImpl) {
      Token? thisKeyword;
      Token? period;
      SimpleIdentifierImpl fieldName;
      var left = initializerObject.leftHandSide;
      if (left is PropertyAccessImpl) {
        var target = left.target;
        if (target is ThisExpressionImpl) {
          thisKeyword = target.thisKeyword;
          period = left.operator;
        } else {
          assert(target is SuperExpressionImpl);
          // Recovery:
          // Parser has reported FieldInitializedOutsideDeclaringClass.
        }
        fieldName = left.propertyName;
      } else if (left is SimpleIdentifierImpl) {
        fieldName = left;
      } else {
        return null;
      }
      return ConstructorFieldInitializerImpl(
        thisKeyword: thisKeyword,
        period: period,
        fieldName: fieldName,
        equals: initializerObject.operator,
        expression: initializerObject.rightHandSide,
      );
    }

    if (initializerObject is AssertInitializerImpl) {
      return initializerObject;
    }

    if (initializerObject is IndexExpressionImpl) {
      return buildInitializerTargetExpressionRecovery(
        initializerObject.target,
        initializerObject,
      );
    }

    if (initializerObject is CascadeExpressionImpl) {
      return buildInitializerTargetExpressionRecovery(
        initializerObject.target,
        initializerObject,
      );
    }

    return null;
  }

  ConstructorInitializerImpl? buildInitializerTargetExpressionRecovery(
    ExpressionImpl? target,
    Object initializerObject,
  ) {
    ArgumentListImpl? argumentList;
    while (true) {
      if (target is FunctionExpressionInvocationImpl) {
        argumentList = target.argumentList;
        target = target.function;
      } else if (target is MethodInvocationImpl) {
        argumentList = target.argumentList;
        target = target.target;
      } else if (target is PropertyAccessImpl) {
        argumentList = null;
        target = target.target;
      } else {
        break;
      }
    }
    if (target is SuperExpressionImpl) {
      // TODO(danrubel): Consider generating this error in the parser
      // This error is also reported in the body builder
      handleRecoverableError(
        messageInvalidSuperInInitializer,
        target.superKeyword,
        target.superKeyword,
      );
      return SuperConstructorInvocationImpl(
        superKeyword: target.superKeyword,
        period: null,
        constructorName: null,
        argumentList:
            argumentList ?? _syntheticArgumentList(target.superKeyword),
      );
    } else if (target is ThisExpressionImpl) {
      // TODO(danrubel): Consider generating this error in the parser
      // This error is also reported in the body builder
      handleRecoverableError(
        messageInvalidThisInInitializer,
        target.thisKeyword,
        target.thisKeyword,
      );
      return RedirectingConstructorInvocationImpl(
        thisKeyword: target.thisKeyword,
        period: null,
        constructorName: null,
        argumentList:
            argumentList ?? _syntheticArgumentList(target.thisKeyword),
      );
    }
    return null;
  }

  void checkFieldFormalParameters(FormalParameterListImpl? parameterList) {
    var parameters = parameterList?.parameters;
    if (parameters != null) {
      for (var parameter in parameters) {
        if (parameter is FieldFormalParameterImpl) {
          // This error is reported in the BodyBuilder.endFormalParameter.
          handleRecoverableError(
            messageFieldInitializerOutsideConstructor,
            parameter.thisKeyword,
            parameter.thisKeyword,
          );
        }
      }
    }
  }

  // TODO(scheglov): We should not do this.
  // Ideally, we should not test parsing pieces of class, and instead parse
  // the whole unit, and extract pieces that we need to validate.
  _ClassDeclarationBuilder createFakeClassDeclarationBuilder(String className) {
    return _classLikeBuilder = _ClassDeclarationBuilder(
      comment: null,
      metadata: null,
      abstractKeyword: null,
      macroKeyword: null,
      sealedKeyword: null,
      baseKeyword: null,
      interfaceKeyword: null,
      finalKeyword: null,
      augmentKeyword: null,
      mixinKeyword: null,
      classKeyword: Token(Keyword.CLASS, 0),
      name: StringToken(TokenType.STRING, className, -1),
      typeParameters: null,
      extendsClause: null,
      withClause: null,
      implementsClause: null,
      nativeClause: null,
      leftBracket: Tokens.openCurlyBracket(),
      rightBracket: Tokens.closeCurlyBracket(),
    );
  }

  @override
  void debugEvent(String name) {
    // printEvent('AstBuilder: $name');
  }

  void doDotExpression(Token dot) {
    var identifierOrInvoke = pop() as ExpressionImpl;
    var receiver = pop() as ExpressionImpl?;
    if (identifierOrInvoke is SimpleIdentifierImpl) {
      if (receiver is SimpleIdentifierImpl && identical('.', dot.stringValue)) {
        push(
          PrefixedIdentifierImpl(
            prefix: receiver,
            period: dot,
            identifier: identifierOrInvoke,
          ),
        );
      } else {
        push(
          PropertyAccessImpl(
            target: receiver,
            operator: dot,
            propertyName: identifierOrInvoke,
          ),
        );
      }
    } else if (identifierOrInvoke is MethodInvocationImpl) {
      assert(identifierOrInvoke.target == null);
      identifierOrInvoke
        ..target = receiver
        ..operator = dot;
      push(identifierOrInvoke);
    } else {
      // This same error is reported in BodyBuilder.doDotOrCascadeExpression
      Token token = identifierOrInvoke.beginToken;
      // TODO(danrubel): Consider specializing the error message based
      // upon the type of expression. e.g. "x.this" -> templateThisAsIdentifier
      handleRecoverableError(
        templateExpectedIdentifier.withArguments(token),
        token,
        token,
      );
      SimpleIdentifierImpl identifier = SimpleIdentifierImpl(token: token);
      push(
        PropertyAccessImpl(
          target: receiver,
          operator: dot,
          propertyName: identifier,
        ),
      );
    }
  }

  void doInvocation(
    TypeArgumentListImpl? typeArguments,
    MethodInvocationImpl arguments,
  ) {
    var receiver = pop() as ExpressionImpl;
    switch (receiver) {
      case SimpleIdentifierImpl():
        arguments.methodName = receiver;
        if (typeArguments != null) {
          arguments.typeArguments = typeArguments;
        }
        push(arguments);
      default:
        push(
          FunctionExpressionInvocationImpl(
            function: receiver,
            typeArguments: typeArguments,
            argumentList: arguments.argumentList,
          ),
        );
    }
  }

  void doPropertyGet() {}

  @override
  void endArguments(int count, Token leftParenthesis, Token rightParenthesis) {
    assert(optional('(', leftParenthesis));
    assert(optional(')', rightParenthesis));
    debugEvent("Arguments");

    var expressions = popTypedList2<ExpressionImpl>(count);
    for (var expression in expressions) {
      reportErrorIfSuper(expression);
    }

    var arguments = ArgumentListImpl(
      leftParenthesis: leftParenthesis,
      arguments: expressions,
      rightParenthesis: rightParenthesis,
    );

    if (!enableNamedArgumentsAnywhere) {
      bool hasSeenNamedArgument = false;
      for (var expression in expressions) {
        if (expression is NamedExpressionImpl) {
          hasSeenNamedArgument = true;
        } else if (hasSeenNamedArgument) {
          // Positional argument after named argument.
          handleRecoverableError(
            messagePositionalAfterNamedArgument,
            expression.beginToken,
            expression.endToken,
          );
        }
      }
    }

    push(
      MethodInvocationImpl(
        target: null,
        operator: null,
        methodName: _tmpSimpleIdentifier(),
        typeArguments: null,
        argumentList: arguments,
      ),
    );
  }

  @override
  void endAsOperatorType(Token asOperator) {
    debugEvent("AsOperatorType");
  }

  @override
  void endAssert(
    Token assertKeyword,
    Assert kind,
    Token leftParenthesis,
    Token? comma,
    Token endToken,
  ) {
    assert(optional('assert', assertKeyword));
    assert(optional('(', leftParenthesis));
    assert(optionalOrNull(',', comma));
    assert(kind != Assert.Statement || optionalOrNull(';', endToken.next!));
    debugEvent("Assert");

    var message = popIfNotNull(comma) as ExpressionImpl?;
    var condition = pop() as ExpressionImpl;
    switch (kind) {
      case Assert.Expression:
        // The parser has already reported an error indicating that assert
        // cannot be used in an expression. Insert a placeholder.
        var arguments = <ExpressionImpl>[condition];
        if (message != null) {
          arguments.add(message);
        }
        push(
          FunctionExpressionInvocationImpl(
            function: SimpleIdentifierImpl(token: assertKeyword),
            typeArguments: null,
            argumentList: ArgumentListImpl(
              leftParenthesis: leftParenthesis,
              arguments: arguments,
              rightParenthesis: leftParenthesis.endGroup!,
            ),
          ),
        );
      case Assert.Initializer:
        push(
          AssertInitializerImpl(
            assertKeyword: assertKeyword,
            leftParenthesis: leftParenthesis,
            condition: condition,
            comma: comma,
            message: message,
            rightParenthesis: leftParenthesis.endGroup!,
          ),
        );
      case Assert.Statement:
        push(
          AssertStatementImpl(
            assertKeyword: assertKeyword,
            leftParenthesis: leftParenthesis,
            condition: condition,
            comma: comma,
            message: message,
            rightParenthesis: leftParenthesis.endGroup!,
            semicolon: endToken.next!,
          ),
        );
    }
  }

  @override
  void endAwaitExpression(Token awaitKeyword, Token endToken) {
    assert(optional('await', awaitKeyword));
    debugEvent("AwaitExpression");

    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);

    push(
      AwaitExpressionImpl(awaitKeyword: awaitKeyword, expression: expression),
    );
  }

  @override
  void endBinaryExpression(Token operatorToken, Token endToken) {
    assert(
      operatorToken.isOperator ||
          optional('===', operatorToken) ||
          optional('!==', operatorToken),
    );
    debugEvent("BinaryExpression");

    var right = pop() as ExpressionImpl;
    var left = pop() as ExpressionImpl;
    reportErrorIfSuper(right);
    push(
      BinaryExpressionImpl(
        leftOperand: left,
        operator: operatorToken,
        rightOperand: right,
      ),
    );
    if (!enableTripleShift && operatorToken.type == TokenType.GT_GT_GT) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.triple_shift,
        startToken: operatorToken,
      );
    }
  }

  @override
  void endBinaryPattern(Token operatorToken) {
    assert(operatorToken.isOperator);
    debugEvent("BinaryPattern");

    var right = pop() as DartPatternImpl;
    var left = pop() as DartPatternImpl;
    if (operatorToken.lexeme == '&&') {
      push(
        LogicalAndPatternImpl(
          leftOperand: left,
          operator: operatorToken,
          rightOperand: right,
        ),
      );
    } else if (operatorToken.lexeme == '||') {
      push(
        LogicalOrPatternImpl(
          leftOperand: left,
          operator: operatorToken,
          rightOperand: right,
        ),
      );
    } else {
      throw UnimplementedError('operatorToken: $operatorToken');
    }
  }

  @override
  void endBlock(
    int count,
    Token leftBracket,
    Token rightBracket,
    BlockKind blockKind,
  ) {
    assert(optional('{', leftBracket));
    assert(optional('}', rightBracket));
    debugEvent("Block");

    var statements = popTypedList2<StatementImpl>(count);
    push(
      BlockImpl(
        leftBracket: leftBracket,
        statements: statements,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void endBlockFunctionBody(int count, Token leftBracket, Token rightBracket) {
    assert(optional('{', leftBracket));
    assert(optional('}', rightBracket));
    debugEvent("BlockFunctionBody");

    var statements = popTypedList2<StatementImpl>(count);
    var block = BlockImpl(
      leftBracket: leftBracket,
      statements: statements,
      rightBracket: rightBracket,
    );
    var star = pop() as Token?;
    var asyncKeyword = pop() as Token?;
    if (parseFunctionBodies) {
      push(
        BlockFunctionBodyImpl(keyword: asyncKeyword, star: star, block: block),
      );
    } else {
      // TODO(danrubel): Skip the block rather than parsing it.
      push(
        EmptyFunctionBodyImpl(
          semicolon: SyntheticToken(
            TokenType.SEMICOLON,
            leftBracket.charOffset,
          ),
        ),
      );
    }
  }

  @override
  void endCascade() {
    debugEvent("Cascade");

    var expression = pop() as ExpressionImpl;
    var cascade = pop() as CascadeExpressionImpl;
    pop(); // Token.
    push(
      CascadeExpressionImpl(
        target: cascade.target,
        cascadeSections: <ExpressionImpl>[
          ...cascade.cascadeSections,
          expression,
        ],
      ),
    );
  }

  @override
  void endCaseExpression(Token caseKeyword, Token? when, Token colon) {
    assert(optional('case', caseKeyword));
    assert(optional(':', colon));
    debugEvent("CaseMatch");

    WhenClauseImpl? whenClause;
    if (when != null) {
      var expression = pop() as ExpressionImpl;
      whenClause = WhenClauseImpl(whenKeyword: when, expression: expression);
    }

    if (_featureSet.isEnabled(Feature.patterns)) {
      var pattern = pop() as DartPatternImpl;
      push(
        SwitchPatternCaseImpl(
          labels: <LabelImpl>[],
          keyword: caseKeyword,
          guardedPattern: GuardedPatternImpl(
            pattern: pattern,
            whenClause: whenClause,
          ),
          colon: colon,
          statements: <StatementImpl>[],
        ),
      );
    } else {
      var expression = pop() as ExpressionImpl;
      push(
        SwitchCaseImpl(
          labels: <LabelImpl>[],
          keyword: caseKeyword,
          expression: expression,
          colon: colon,
          statements: <StatementImpl>[],
        ),
      );
    }
  }

  @override
  void endClassConstructor(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    assert(
      getOrSet == null ||
          optional('get', getOrSet) ||
          optional('set', getOrSet),
    );
    debugEvent("ClassConstructor");

    _classLikeBuilder?.members.add(
      _buildConstructorDeclaration(beginToken: beginToken, endToken: endToken),
    );
  }

  @override
  void endClassDeclaration(Token beginToken, Token endToken) {
    debugEvent("ClassDeclaration");

    var builder = _classLikeBuilder as _ClassDeclarationBuilder;
    declarations.add(builder.build());

    _classLikeBuilder = null;
  }

  @override
  void endClassFactoryMethod(
    Token beginToken,
    Token factoryKeyword,
    Token endToken,
  ) {
    assert(optional('factory', factoryKeyword));
    assert(optional(';', endToken) || optional('}', endToken));
    debugEvent("ClassFactoryMethod");

    _classLikeBuilder?.members.add(
      _buildFactoryConstructorDeclaration(
        beginToken: beginToken,
        factoryKeyword: factoryKeyword,
        endToken: endToken,
      ),
    );
  }

  @override
  void endClassFields(
    Token? abstractToken,
    Token? augmentToken,
    Token? externalToken,
    Token? staticToken,
    Token? covariantToken,
    Token? lateToken,
    Token? varFinalOrConst,
    int count,
    Token beginToken,
    Token semicolon,
  ) {
    assert(optional(';', semicolon));
    debugEvent("Fields");

    if (abstractToken != null) {
      if (staticToken != null) {
        handleRecoverableError(
          messageAbstractStaticField,
          abstractToken,
          abstractToken,
        );
      }
      if (lateToken != null) {
        handleRecoverableError(
          messageAbstractLateField,
          abstractToken,
          abstractToken,
        );
      }
    }
    if (externalToken != null) {
      if (lateToken != null) {
        handleRecoverableError(
          messageExternalLateField,
          externalToken,
          externalToken,
        );
      }
    }

    var variables = popTypedList2<VariableDeclarationImpl>(count);
    var type = pop() as TypeAnnotationImpl?;
    var variableList = VariableDeclarationListImpl(
      comment: null,
      metadata: null,
      lateKeyword: lateToken,
      keyword: varFinalOrConst,
      type: type,
      variables: variables,
    );
    var covariantKeyword = covariantToken;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);
    _classLikeBuilder?.members.add(
      FieldDeclarationImpl(
        comment: comment,
        metadata: metadata,
        abstractKeyword: abstractToken,
        augmentKeyword: augmentToken,
        covariantKeyword: covariantKeyword,
        externalKeyword: externalToken,
        staticKeyword: staticToken,
        fields: variableList,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endClassMethod(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    assert(
      getOrSet == null ||
          optional('get', getOrSet) ||
          optional('set', getOrSet),
    );
    debugEvent("ClassMethod");

    var bodyObject = pop();
    pop(); // initializers
    pop(); // separator
    var formalParameters = pop() as FormalParameterListImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop();
    var returnType = pop() as TypeAnnotationImpl?;
    var modifiers = pop() as _Modifiers?;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);

    assert(formalParameters != null || optional('get', getOrSet!));

    Token? operatorKeyword;
    SimpleIdentifierImpl nameId;
    if (name is SimpleIdentifierImpl) {
      nameId = name;
    } else if (name is _OperatorName) {
      operatorKeyword = name.operatorKeyword;
      nameId = name.name;
      if (typeParameters != null) {
        handleRecoverableError(
          messageOperatorWithTypeParameters,
          typeParameters.beginToken,
          typeParameters.endToken,
        );
      }
    } else {
      throw UnimplementedError(
        'name is an instance of ${name.runtimeType} in endClassMethod',
      );
    }

    if (getOrSet?.keyword == Keyword.SET) {
      formalParameters = _ensureSetterFormalParameter(nameId, formalParameters);
    }

    FunctionBodyImpl body;
    if (bodyObject is FunctionBodyImpl) {
      body = bodyObject;
    } else if (bodyObject is _RedirectingFactoryBody) {
      body = EmptyFunctionBodyImpl(semicolon: endToken);
    } else {
      internalProblem(
        templateInternalProblemUnhandled.withArguments(
          "${bodyObject.runtimeType}",
          "bodyObject",
        ),
        beginToken.charOffset,
        uri,
      );
    }

    checkFieldFormalParameters(formalParameters);
    _classLikeBuilder?.members.add(
      MethodDeclarationImpl(
        comment: comment,
        metadata: metadata,
        augmentKeyword: modifiers?.augmentKeyword,
        externalKeyword: modifiers?.externalKeyword,
        modifierKeyword: modifiers?.abstractKeyword ?? modifiers?.staticKeyword,
        returnType: returnType,
        propertyKeyword: getOrSet,
        operatorKeyword: operatorKeyword,
        name: nameId.token,
        typeParameters: typeParameters,
        parameters: formalParameters,
        body: body,
      ),
    );
  }

  @override
  void endClassOrMixinOrExtensionBody(
    DeclarationKind kind,
    int memberCount,
    Token leftBracket,
    Token rightBracket,
  ) {
    // TODO(danrubel): consider renaming endClassOrMixinBody
    // to endClassOrMixinOrExtensionBody
    assert(optional('{', leftBracket));
    assert(optional('}', rightBracket));
    debugEvent("ClassOrMixinBody");

    var builder = _classLikeBuilder;
    if (builder != null) {
      builder
        ..leftBracket = leftBracket
        ..rightBracket = rightBracket;
    }
  }

  @override
  void endCombinators(int count) {
    debugEvent("Combinators");
    push(popTypedList<CombinatorImpl>(count) ?? NullValues.Combinators);
  }

  @override
  void endCompilationUnit(int count, Token endToken) {
    debugEvent("CompilationUnit");

    var beginToken = pop() as Token;
    checkEmpty(endToken.charOffset);

    CompilationUnitImpl unit = CompilationUnitImpl(
      beginToken: beginToken,
      scriptTag: scriptTag,
      directives: directives,
      declarations: declarations,
      endToken: endToken,
      featureSet: _featureSet,
      lineInfo: _lineInfo,
      languageVersion: _languageVersion,
      invalidNodes: invalidNodes,
    );
    push(unit);
  }

  @override
  void endConditionalExpression(Token question, Token colon, Token endToken) {
    assert(optional('?', question));
    assert(optional(':', colon));
    debugEvent("ConditionalExpression");

    var elseExpression = pop() as ExpressionImpl;
    var thenExpression = pop() as ExpressionImpl;
    var condition = pop() as ExpressionImpl;
    reportErrorIfSuper(elseExpression);
    reportErrorIfSuper(thenExpression);
    push(
      ConditionalExpressionImpl(
        condition: condition,
        question: question,
        thenExpression: thenExpression,
        colon: colon,
        elseExpression: elseExpression,
      ),
    );
  }

  @override
  void endConditionalUri(Token ifKeyword, Token leftParen, Token? equalSign) {
    assert(optional('if', ifKeyword));
    assert(optionalOrNull('(', leftParen));
    assert(optionalOrNull('==', equalSign));
    debugEvent("ConditionalUri");

    var libraryUri = pop() as StringLiteralImpl;
    var value = popIfNotNull(equalSign) as StringLiteralImpl?;
    if (value is StringInterpolationImpl) {
      for (var child in value.childEntities) {
        if (child is InterpolationExpressionImpl) {
          // This error is reported in OutlineBuilder.endLiteralString
          handleRecoverableError(
            messageInterpolationInUri,
            child.beginToken,
            child.endToken,
          );
          break;
        }
      }
    }
    var name = pop() as DottedNameImpl;
    push(
      ConfigurationImpl(
        ifKeyword: ifKeyword,
        leftParenthesis: leftParen,
        name: name,
        equalToken: equalSign,
        value: value,
        rightParenthesis: leftParen.endGroup!,
        uri: libraryUri,
      ),
    );
  }

  @override
  void endConditionalUris(int count) {
    debugEvent("ConditionalUris");

    push(popTypedList<ConfigurationImpl>(count) ?? NullValues.ConditionalUris);
  }

  @override
  void endConstantPattern(Token? constKeyword) {
    push(
      ConstantPatternImpl(
        constKeyword: constKeyword,
        expression: pop() as ExpressionImpl,
      ),
    );
  }

  @override
  void endConstDotShorthand(Token token) {
    debugEvent("endConstDotShorthand");
    if (!enabledDotShorthands) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.dot_shorthands,
        startToken: token,
      );
    }

    var dotShorthand = pop() as DotShorthandInvocationImpl;
    push(
      DotShorthandConstructorInvocationImpl(
        constKeyword: token,
        period: dotShorthand.period,
        constructorName: dotShorthand.memberName,
        typeArguments: dotShorthand.typeArguments,
        argumentList: dotShorthand.argumentList,
      )..isDotShorthand = dotShorthand.isDotShorthand,
    );
  }

  @override
  void endConstExpression(Token constKeyword) {
    assert(optional('const', constKeyword));
    debugEvent("ConstExpression");

    _handleInstanceCreation(constKeyword);
  }

  @override
  void endConstLiteral(Token endToken) {
    debugEvent("endConstLiteral");
  }

  @override
  void endConstructorReference(
    Token start,
    Token? periodBeforeName,
    Token endToken,
    ConstructorReferenceContext constructorReferenceContext,
  ) {
    assert(optionalOrNull('.', periodBeforeName));
    debugEvent("ConstructorReference");

    var constructorName = pop() as SimpleIdentifierImpl?;
    var typeArguments = pop() as TypeArgumentListImpl?;
    var typeNameIdentifier = pop() as IdentifierImpl;
    push(
      ConstructorNameImpl(
        type: typeNameIdentifier.toNamedType(
          typeArguments: typeArguments,
          question: null,
        ),
        period: periodBeforeName,
        name: constructorName,
      ),
    );
  }

  @override
  void endDoWhileStatement(
    Token doKeyword,
    Token whileKeyword,
    Token semicolon,
  ) {
    assert(optional('do', doKeyword));
    assert(optional('while', whileKeyword));
    assert(optional(';', semicolon));
    debugEvent("DoWhileStatement");

    var condition = pop() as _ParenthesizedCondition;
    var body = pop() as StatementImpl;
    push(
      DoStatementImpl(
        doKeyword: doKeyword,
        body: body,
        whileKeyword: whileKeyword,
        leftParenthesis: condition.leftParenthesis,
        condition: condition.expression,
        rightParenthesis: condition.rightParenthesis,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endDoWhileStatementBody(Token token) {
    debugEvent("endDoWhileStatementBody");
  }

  @override
  void endElseStatement(Token beginToken, Token endToken) {
    debugEvent("endElseStatement");
  }

  @override
  void endEnum(
    Token beginToken,
    Token enumKeyword,
    Token leftBrace,
    int memberCount,
    Token endToken,
  ) {
    assert(optional('enum', enumKeyword));
    assert(optional('{', leftBrace));
    debugEvent("Enum");

    var builder = _classLikeBuilder as _EnumDeclarationBuilder;
    declarations.add(builder.build());
    _classLikeBuilder = null;
  }

  @override
  void endEnumConstructor(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    debugEvent("endEnumConstructor");
    endClassConstructor(
      getOrSet,
      beginToken,
      beginParam,
      beginInitializers,
      endToken,
    );
  }

  @override
  void endExport(Token exportKeyword, Token semicolon) {
    assert(optional('export', exportKeyword));
    assert(optional(';', semicolon));
    debugEvent("Export");

    var combinators = pop() as List<CombinatorImpl>?;
    var configurations = pop() as List<ConfigurationImpl>?;
    var uri = pop() as StringLiteralImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, exportKeyword);
    directives.add(
      ExportDirectiveImpl(
        comment: comment,
        metadata: metadata,
        exportKeyword: exportKeyword,
        uri: uri,
        configurations: configurations,
        combinators: combinators,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endExtensionConstructor(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    debugEvent("ExtensionConstructor");

    invalidNodes.add(
      _buildConstructorDeclaration(beginToken: beginToken, endToken: endToken),
    );
  }

  @override
  void endExtensionDeclaration(
    Token beginToken,
    Token extensionKeyword,
    Token? onKeyword,
    Token token,
  ) {
    var builder = _classLikeBuilder as _ExtensionDeclarationBuilder;

    ExtensionOnClauseImpl? onClause;
    if (onKeyword != null) {
      var extendedType = pop() as TypeAnnotationImpl;
      onClause = ExtensionOnClauseImpl(
        onKeyword: onKeyword,
        extendedType: extendedType,
      );
    }

    declarations.add(builder.build(typeKeyword: null, onClause: onClause));

    _classLikeBuilder = null;
  }

  @override
  void endExtensionFactoryMethod(
    Token beginToken,
    Token factoryKeyword,
    Token endToken,
  ) {
    assert(optional('factory', factoryKeyword));
    assert(optional(';', endToken) || optional('}', endToken));
    debugEvent("ExtensionFactoryMethod");

    invalidNodes.add(
      _buildFactoryConstructorDeclaration(
        beginToken: beginToken,
        factoryKeyword: factoryKeyword,
        endToken: endToken,
      ),
    );
  }

  @override
  void endExtensionFields(
    Token? abstractToken,
    Token? augmentToken,
    Token? externalToken,
    Token? staticToken,
    Token? covariantToken,
    Token? lateToken,
    Token? varFinalOrConst,
    int count,
    Token beginToken,
    Token endToken,
  ) {
    if (staticToken == null) {
      // TODO(danrubel): Decide how to handle instance field declarations
      // within extensions. They are invalid and the parser has already reported
      // an error at this point, but we include them in order to get navigation,
      // search, etc.
    }
    endClassFields(
      abstractToken,
      augmentToken,
      externalToken,
      staticToken,
      covariantToken,
      lateToken,
      varFinalOrConst,
      count,
      beginToken,
      endToken,
    );
  }

  @override
  void endExtensionMethod(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    debugEvent("ExtensionMethod");
    endClassMethod(
      getOrSet,
      beginToken,
      beginParam,
      beginInitializers,
      endToken,
    );
  }

  @override
  void endExtensionTypeDeclaration(
    Token beginToken,
    Token? augmentToken,
    Token extensionKeyword,
    Token typeKeyword,
    Token endToken,
  ) {
    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var representation =
        pop(const NullValue("RepresentationDeclarationImpl"))
            as RepresentationDeclarationImpl?;
    var constKeyword = pop() as Token?;

    if (enableInlineClass) {
      var builder = _classLikeBuilder as _ExtensionTypeDeclarationBuilder;
      if (representation == null) {
        var leftParenthesis = parser.rewriter.insertParens(builder.name, true);
        var typeName = leftParenthesis.next!;
        var rightParenthesis = leftParenthesis.endGroup!;
        var fieldName = parser.rewriter.insertSyntheticIdentifier(typeName);
        representation = RepresentationDeclarationImpl(
          constructorName: null,
          leftParenthesis: leftParenthesis,
          fieldMetadata: [],
          fieldType: NamedTypeImpl(
            importPrefix: null,
            name: typeName,
            question: null,
            typeArguments: null,
          ),
          fieldName: fieldName,
          rightParenthesis: rightParenthesis,
        );
      }
      // Check for extension type name conflict.
      var representationName = representation.fieldName;
      if (representationName.lexeme == builder.name.lexeme) {
        diagnosticReporter.diagnosticReporter?.atToken(
          representationName,
          ParserErrorCode.MEMBER_WITH_CLASS_NAME,
        );
      }
      declarations.add(
        builder.build(
          typeKeyword: typeKeyword,
          constKeyword: constKeyword,
          representation: representation,
          implementsClause: implementsClause,
        ),
      );
    } else {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.inline_class,
        startToken: typeKeyword,
      );
    }

    _classLikeBuilder = null;
  }

  @override
  void endFieldInitializer(Token equals, Token endToken) {
    assert(optional('=', equals));
    debugEvent("FieldInitializer");

    var initializer = pop() as ExpressionImpl;
    var name = pop() as SimpleIdentifierImpl;
    reportErrorIfSuper(initializer);
    push(
      VariableDeclarationImpl(
        comment: null,
        metadata: [],
        name: name.token,
        equals: equals,
        initializer: initializer,
      ),
    );
  }

  @override
  void endForControlFlow(Token token) {
    debugEvent("endForControlFlow");
    var body = pop() as CollectionElementImpl;
    var forLoopParts = pop() as ForPartsImpl;
    var leftParenthesis = pop() as Token;
    var forToken = pop() as Token;

    push(
      ForElementImpl(
        awaitKeyword: null,
        forKeyword: forToken,
        leftParenthesis: leftParenthesis,
        forLoopParts: forLoopParts,
        rightParenthesis: leftParenthesis.endGroup!,
        body: body,
      ),
    );
  }

  @override
  void endForIn(Token endToken) {
    debugEvent("ForInExpression");

    var body = pop() as StatementImpl;
    var forLoopParts = pop() as ForEachPartsImpl;
    var leftParenthesis = pop() as Token;
    var forToken = pop() as Token;
    var awaitToken = pop(NullValues.AwaitToken) as Token?;

    push(
      ForStatementImpl(
        awaitKeyword: awaitToken,
        forKeyword: forToken,
        leftParenthesis: leftParenthesis,
        forLoopParts: forLoopParts,
        rightParenthesis: leftParenthesis.endGroup!,
        body: body,
      ),
    );
  }

  @override
  void endForInBody(Token endToken) {
    debugEvent("endForInBody");
  }

  @override
  void endForInControlFlow(Token token) {
    debugEvent("endForInControlFlow");

    var body = pop() as CollectionElementImpl;
    var forLoopParts = pop() as ForEachPartsImpl;
    var leftParenthesis = pop() as Token;
    var forToken = pop() as Token;
    var awaitToken = pop(NullValues.AwaitToken) as Token?;

    push(
      ForElementImpl(
        awaitKeyword: awaitToken,
        forKeyword: forToken,
        leftParenthesis: leftParenthesis,
        forLoopParts: forLoopParts,
        rightParenthesis: leftParenthesis.endGroup!,
        body: body,
      ),
    );
  }

  @override
  void endForInExpression(Token token) {
    debugEvent("ForInExpression");
  }

  @override
  void endFormalParameter(
    Token? thisKeyword,
    Token? superKeyword,
    Token? periodAfterThisOrSuper,
    Token nameToken,
    Token? initializerStart,
    Token? initializerEnd,
    FormalParameterKind kind,
    MemberKind memberKind,
  ) {
    assert(optionalOrNull('this', thisKeyword));
    assert(optionalOrNull('super', superKeyword));
    assert(
      thisKeyword == null && superKeyword == null
          ? periodAfterThisOrSuper == null
          : optional('.', periodAfterThisOrSuper!),
    );
    debugEvent("FormalParameter");

    if (superKeyword != null && !enableSuperParameters) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.super_parameters,
        startToken: superKeyword,
      );
    }

    var defaultValue = pop() as _ParameterDefaultValue?;
    var name = pop() as SimpleIdentifierImpl?;
    var typeOrFunctionTypedParameter = pop() as AstNodeImpl?;
    var modifiers = pop() as _Modifiers?;
    var keyword = modifiers?.finalConstOrVarKeyword;
    var covariantKeyword = modifiers?.covariantKeyword;
    var requiredKeyword = modifiers?.requiredToken;

    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(
      metadata,
      thisKeyword ?? typeOrFunctionTypedParameter?.beginToken ?? nameToken,
    );

    NormalFormalParameterImpl node;
    if (typeOrFunctionTypedParameter is FunctionTypedFormalParameterImpl) {
      // This is a temporary AST node that was constructed in
      // [endFunctionTypedFormalParameter]. We now deconstruct it and create
      // the final AST node.
      if (superKeyword != null) {
        assert(
          thisKeyword == null,
          "Can't have both 'this' and 'super' in a parameter.",
        );
        node = SuperFormalParameterImpl(
          name: name!.token,
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          keyword: keyword,
          requiredKeyword: requiredKeyword,
          type: typeOrFunctionTypedParameter.returnType,
          superKeyword: superKeyword,
          period: periodAfterThisOrSuper!,
          typeParameters: typeOrFunctionTypedParameter.typeParameters,
          parameters: typeOrFunctionTypedParameter.parameters,
          question: typeOrFunctionTypedParameter.question,
        );
      } else if (thisKeyword != null) {
        assert(
          superKeyword == null,
          "Can't have both 'this' and 'super' in a parameter.",
        );
        node = FieldFormalParameterImpl(
          name: name!.token,
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          keyword: keyword,
          requiredKeyword: requiredKeyword,
          type: typeOrFunctionTypedParameter.returnType,
          thisKeyword: thisKeyword,
          period: periodAfterThisOrSuper!,
          typeParameters: typeOrFunctionTypedParameter.typeParameters,
          parameters: typeOrFunctionTypedParameter.parameters,
          question: typeOrFunctionTypedParameter.question,
        );
      } else {
        node = FunctionTypedFormalParameterImpl(
          name: name!.token,
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          requiredKeyword: requiredKeyword,
          returnType: typeOrFunctionTypedParameter.returnType,
          typeParameters: typeOrFunctionTypedParameter.typeParameters,
          parameters: typeOrFunctionTypedParameter.parameters,
          question: typeOrFunctionTypedParameter.question,
        );
      }
    } else {
      var type = typeOrFunctionTypedParameter as TypeAnnotationImpl?;
      if (superKeyword != null) {
        assert(
          thisKeyword == null,
          "Can't have both 'this' and 'super' in a parameter.",
        );
        if (keyword is KeywordToken && keyword.keyword == Keyword.VAR) {
          handleRecoverableError(
            templateExtraneousModifier.withArguments(keyword),
            keyword,
            keyword,
          );
        }
        node = SuperFormalParameterImpl(
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          requiredKeyword: requiredKeyword,
          keyword: keyword,
          type: type,
          superKeyword: superKeyword,
          period: periodAfterThisOrSuper!,
          name: name!.token,
          typeParameters: null,
          parameters: null,
          question: null,
        );
      } else if (thisKeyword != null) {
        assert(
          superKeyword == null,
          "Can't have both 'this' and 'super' in a parameter.",
        );
        node = FieldFormalParameterImpl(
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          requiredKeyword: requiredKeyword,
          keyword: keyword,
          type: type,
          thisKeyword: thisKeyword,
          period: thisKeyword.next!,
          name: name!.token,
          typeParameters: null,
          parameters: null,
          question: null,
        );
      } else {
        node = SimpleFormalParameterImpl(
          comment: comment,
          metadata: metadata,
          covariantKeyword: covariantKeyword,
          requiredKeyword: requiredKeyword,
          keyword: keyword,
          type: type,
          name: name?.token,
        );
      }
    }

    ParameterKind analyzerKind = _toAnalyzerParameterKind(kind);
    FormalParameterImpl parameter = node;
    if (analyzerKind != ParameterKind.REQUIRED) {
      parameter = DefaultFormalParameterImpl(
        parameter: node,
        kind: analyzerKind,
        separator: defaultValue?.separator,
        defaultValue: defaultValue?.value,
      );
    } else if (defaultValue != null) {
      // An error is reported if a required parameter has a default value.
      // Record it as named parameter for recovery.
      parameter = DefaultFormalParameterImpl(
        parameter: node,
        kind: ParameterKind.NAMED,
        separator: defaultValue.separator,
        defaultValue: defaultValue.value,
      );
    }
    push(parameter);
  }

  @override
  void endFormalParameterDefaultValueExpression() {
    debugEvent("FormalParameterDefaultValueExpression");
  }

  @override
  void endFormalParameters(
    int count,
    Token leftParenthesis,
    Token rightParenthesis,
    MemberKind kind,
  ) {
    assert(optional('(', leftParenthesis));
    assert(optional(')', rightParenthesis));
    debugEvent("FormalParameters");

    var rawParameters = popTypedList(count) ?? const <Object>[];
    var parameters = <FormalParameterImpl>[];
    Token? leftDelimiter;
    Token? rightDelimiter;
    for (Object raw in rawParameters) {
      if (raw is _OptionalFormalParameters) {
        parameters.addAll(raw.parameters ?? const []);
        leftDelimiter = raw.leftDelimiter;
        rightDelimiter = raw.rightDelimiter;
      } else {
        parameters.add(raw as FormalParameterImpl);
      }
    }
    push(
      FormalParameterListImpl(
        leftParenthesis: leftParenthesis,
        parameters: parameters,
        leftDelimiter: leftDelimiter,
        rightDelimiter: rightDelimiter,
        rightParenthesis: rightParenthesis,
      ),
    );
  }

  @override
  void endForStatement(Token endToken) {
    debugEvent("ForStatement");
    var body = pop() as StatementImpl;
    var forLoopParts = pop() as ForPartsImpl;
    var leftParen = pop() as Token;
    var forToken = pop() as Token;

    push(
      ForStatementImpl(
        awaitKeyword: null,
        forKeyword: forToken,
        leftParenthesis: leftParen,
        forLoopParts: forLoopParts,
        rightParenthesis: leftParen.endGroup!,
        body: body,
      ),
    );
  }

  @override
  void endForStatementBody(Token endToken) {
    debugEvent("endForStatementBody");
  }

  @override
  void endFunctionExpression(Token beginToken, Token endToken) {
    // TODO(paulberry): set up scopes properly to resolve parameters and type
    // variables.  Note that this is tricky due to the handling of initializers
    // in constructors, so the logic should be shared with BodyBuilder as much
    // as possible.
    debugEvent("FunctionExpression");

    var body = pop() as FunctionBodyImpl;
    var parameters = pop() as FormalParameterListImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    push(
      FunctionExpressionImpl(
        typeParameters: typeParameters,
        parameters: parameters,
        body: body,
      ),
    );
  }

  @override
  void endFunctionName(
    Token beginToken,
    Token token,
    bool isFunctionExpression,
  ) {
    debugEvent("FunctionName");
  }

  @override
  void endFunctionType(Token functionToken, Token? questionMark) {
    assert(optional('Function', functionToken));
    debugEvent("FunctionType");

    var parameters = pop() as FormalParameterListImpl;
    var returnType = pop() as TypeAnnotationImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    push(
      GenericFunctionTypeImpl(
        returnType: returnType,
        functionKeyword: functionToken,
        typeParameters: typeParameters,
        parameters: parameters,
        question: questionMark,
      ),
    );
  }

  @override
  void endFunctionTypedFormalParameter(Token nameToken, Token? question) {
    debugEvent("FunctionTypedFormalParameter");

    var formalParameters = pop() as FormalParameterListImpl;
    var returnType = pop() as TypeAnnotationImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;

    // Create a temporary formal parameter that will be dissected later in
    // [endFormalParameter].
    push(
      FunctionTypedFormalParameterImpl(
        comment: null,
        metadata: null,
        covariantKeyword: null,
        requiredKeyword: null,
        name: StringToken(TokenType.IDENTIFIER, '', 0),
        returnType: returnType,
        typeParameters: typeParameters,
        parameters: formalParameters,
        question: question,
      ),
    );
  }

  @override
  void endHide(Token hideKeyword) {
    assert(optional('hide', hideKeyword));
    debugEvent("Hide");

    var hiddenNames = pop() as List<SimpleIdentifierImpl>;
    push(HideCombinatorImpl(keyword: hideKeyword, hiddenNames: hiddenNames));
  }

  @override
  void endIfControlFlow(Token token) {
    var thenElement = pop() as CollectionElementImpl;
    var condition = pop() as _ParenthesizedCondition;
    var ifToken = pop() as Token;
    push(
      IfElementImpl(
        ifKeyword: ifToken,
        leftParenthesis: condition.leftParenthesis,
        expression: condition.expression,
        caseClause: condition.caseClause,
        rightParenthesis: condition.rightParenthesis,
        thenElement: thenElement,
        elseKeyword: null,
        elseElement: null,
      ),
    );
  }

  @override
  void endIfElseControlFlow(Token token) {
    var elseElement = pop() as CollectionElementImpl;
    var elseToken = pop() as Token;
    var thenElement = pop() as CollectionElementImpl;
    var condition = pop() as _ParenthesizedCondition;
    var ifToken = pop() as Token;
    push(
      IfElementImpl(
        ifKeyword: ifToken,
        leftParenthesis: condition.leftParenthesis,
        expression: condition.expression,
        caseClause: condition.caseClause,
        rightParenthesis: condition.rightParenthesis,
        thenElement: thenElement,
        elseKeyword: elseToken,
        elseElement: elseElement,
      ),
    );
  }

  @override
  void endIfStatement(Token ifToken, Token? elseToken, Token endToken) {
    assert(optional('if', ifToken));
    assert(optionalOrNull('else', elseToken));

    var elsePart = popIfNotNull(elseToken) as StatementImpl?;
    var thenPart = pop() as StatementImpl;
    var condition = pop() as _ParenthesizedCondition;
    push(
      IfStatementImpl(
        ifKeyword: ifToken,
        leftParenthesis: condition.leftParenthesis,
        expression: condition.expression,
        caseClause: condition.caseClause,
        rightParenthesis: condition.rightParenthesis,
        thenStatement: thenPart,
        elseKeyword: elseToken,
        elseStatement: elsePart,
      ),
    );
  }

  @override
  void endImplicitCreationExpression(Token token, Token openAngleBracket) {
    debugEvent("ImplicitCreationExpression");

    _handleInstanceCreation(null);
  }

  @override
  void endImport(Token importKeyword, Token? augmentToken, Token? semicolon) {
    assert(optional('import', importKeyword));
    assert(optionalOrNull(';', semicolon));
    debugEvent("Import");

    var combinators = pop() as List<CombinatorImpl>?;
    var deferredKeyword = pop(NullValues.Deferred) as Token?;
    var asKeyword = pop(NullValues.As) as Token?;
    var prefix = pop(NullValues.Prefix) as SimpleIdentifierImpl?;
    var configurations = pop() as List<ConfigurationImpl>?;
    var uri = pop() as StringLiteralImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, importKeyword);

    if (!enableMacros) {
      if (augmentToken != null) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.macros,
          startToken: augmentToken,
        );
        // Pretend that 'augment' didn't occur while this feature is incomplete.
        augmentToken = null;
      }
    }

    directives.add(
      ImportDirectiveImpl(
        comment: comment,
        metadata: metadata,
        importKeyword: importKeyword,
        uri: uri,
        configurations: configurations,
        deferredKeyword: deferredKeyword,
        asKeyword: asKeyword,
        prefix: prefix,
        combinators: combinators,
        semicolon: semicolon ?? Tokens.semicolon(),
      ),
    );
  }

  @override
  void endInitializedIdentifier(Token nameToken) {
    debugEvent("InitializedIdentifier");

    var node = pop() as AstNodeImpl?;
    VariableDeclarationImpl variable;
    // TODO(paulberry): This seems kludgy.  It would be preferable if we
    // could respond to a "handleNoVariableInitializer" event by converting a
    // SimpleIdentifier into a VariableDeclaration, and then when this code was
    // reached, node would always be a VariableDeclaration.
    if (node is VariableDeclarationImpl) {
      variable = node;
    } else if (node is SimpleIdentifierImpl) {
      variable = VariableDeclarationImpl(
        comment: null,
        metadata: [],
        name: node.token,
        equals: null,
        initializer: null,
      );
    } else {
      internalProblem(
        templateInternalProblemUnhandled.withArguments(
          "${node.runtimeType}",
          "identifier",
        ),
        nameToken.charOffset,
        uri,
      );
    }
    push(variable);
  }

  @override
  void endInitializers(int count, Token colon, Token endToken) {
    assert(optional(':', colon));
    debugEvent("Initializers");

    var initializerObjects = popTypedList(count) ?? const [];
    if (!isFullAst) return;

    push(colon);

    var initializers = <ConstructorInitializerImpl>[];
    for (Object initializerObject in initializerObjects) {
      var initializer = buildInitializer(initializerObject);
      if (initializer != null) {
        initializers.add(initializer);
      } else {
        handleRecoverableError(
          messageInvalidInitializer,
          initializerObject is AstNodeImpl
              ? initializerObject.beginToken
              : colon,
          initializerObject is AstNodeImpl ? initializerObject.endToken : colon,
        );
      }
    }

    push(initializers);
  }

  @override
  void endInvalidAwaitExpression(
    Token awaitKeyword,
    Token endToken,
    MessageCode errorCode,
  ) {
    debugEvent("InvalidAwaitExpression");
    endAwaitExpression(awaitKeyword, endToken);
  }

  @override
  void endInvalidYieldStatement(
    Token yieldKeyword,
    Token? starToken,
    Token endToken,
    MessageCode errorCode,
  ) {
    debugEvent("InvalidYieldStatement");
    endYieldStatement(yieldKeyword, starToken, endToken);
  }

  @override
  void endIsOperatorType(Token asOperator) {
    debugEvent("IsOperatorType");
  }

  @override
  void endLabeledStatement(int labelCount) {
    debugEvent("LabeledStatement");

    var statement = pop() as StatementImpl;
    var labels = popTypedList2<LabelImpl>(labelCount);
    push(LabeledStatementImpl(labels: labels, statement: statement));
  }

  @override
  void endLibraryAugmentation(
    Token augmentKeyword,
    Token libraryKeyword,
    Token semicolon,
  ) {
    // TODO(scheglov): remove this method
    pop() as StringLiteralImpl; // uri
    pop() as List<AnnotationImpl>?; // metadata
  }

  @override
  void endLibraryName(Token libraryKeyword, Token semicolon, bool hasName) {
    assert(optional('library', libraryKeyword));
    assert(optional(';', semicolon));
    debugEvent("LibraryName");

    var libraryName = hasName ? pop() as List<SimpleIdentifierImpl>? : null;

    if (!hasName && !enableUnnamedLibraries) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.unnamed_libraries,
        startToken: libraryKeyword,
      );
    }
    var name =
        libraryName == null
            ? null
            : LibraryIdentifierImpl(components: libraryName);
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, libraryKeyword);
    directives.add(
      LibraryDirectiveImpl(
        comment: comment,
        metadata: metadata,
        libraryKeyword: libraryKeyword,
        name2: name,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endLiteralString(int interpolationCount, Token endToken) {
    debugEvent("endLiteralString");

    if (interpolationCount == 0) {
      var token = pop() as Token;
      String value = unescapeString(token.lexeme, token, this);
      push(SimpleStringLiteralImpl(literal: token, value: value));
    } else {
      var parts = popTypedList(1 + interpolationCount * 2)!;
      var first = parts.first as Token;
      var last = parts.last as Token;
      Quote quote = analyzeQuote(first.lexeme);
      var elements = <InterpolationElementImpl>[];
      elements.add(
        InterpolationStringImpl(
          contents: first,
          value: unescapeFirstStringPart(first.lexeme, quote, first, this),
        ),
      );
      for (int i = 1; i < parts.length - 1; i++) {
        var part = parts[i];
        if (part is Token) {
          elements.add(
            InterpolationStringImpl(
              contents: part,
              value: unescape(part.lexeme, quote, part, this),
            ),
          );
        } else if (part is InterpolationExpressionImpl) {
          elements.add(part);
        } else {
          internalProblem(
            templateInternalProblemUnhandled.withArguments(
              "${part.runtimeType}",
              "string interpolation",
            ),
            first.charOffset,
            uri,
          );
        }
      }
      elements.add(
        InterpolationStringImpl(
          contents: last,
          value: unescapeLastStringPart(
            last.lexeme,
            quote,
            last,
            last.isSynthetic,
            this,
          ),
        ),
      );
      push(StringInterpolationImpl(elements: elements));
    }
  }

  @override
  void endLiteralSymbol(Token hashToken, int tokenCount) {
    assert(optional('#', hashToken));
    debugEvent("LiteralSymbol");

    var components = popTypedList2<Token>(tokenCount);
    push(SymbolLiteralImpl(poundSign: hashToken, components: components));
  }

  @override
  void endLocalFunctionDeclaration(Token token) {
    debugEvent("LocalFunctionDeclaration");
    var body = pop() as FunctionBodyImpl;
    if (isFullAst) {
      pop(); // constructor initializers
      pop(); // separator before constructor initializers
    }
    var parameters = pop() as FormalParameterListImpl;
    checkFieldFormalParameters(parameters);
    var name = pop() as SimpleIdentifierImpl;
    var returnType = pop() as TypeAnnotationImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var metadata = pop(NullValues.Metadata) as List<AnnotationImpl>?;
    var functionExpression = FunctionExpressionImpl(
      typeParameters: typeParameters,
      parameters: parameters,
      body: body,
    );
    var functionDeclaration = FunctionDeclarationImpl(
      comment: null,
      metadata: metadata,
      augmentKeyword: null,
      externalKeyword: null,
      returnType: returnType,
      propertyKeyword: null,
      name: name.token,
      functionExpression: functionExpression,
    );
    push(
      FunctionDeclarationStatementImpl(
        functionDeclaration: functionDeclaration,
      ),
    );
  }

  @override
  void endMember() {
    debugEvent("Member");
  }

  @override
  void endMetadata(Token atSign, Token? periodBeforeName, Token endToken) {
    assert(optional('@', atSign));
    assert(optionalOrNull('.', periodBeforeName));
    debugEvent("Metadata");

    var invocation = pop() as MethodInvocationImpl?;
    var constructorName =
        periodBeforeName != null ? pop() as SimpleIdentifierImpl : null;
    var typeArguments = pop() as TypeArgumentListImpl?;
    if (typeArguments != null &&
        !_featureSet.isEnabled(Feature.generic_metadata)) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.generic_metadata,
        startToken: typeArguments.beginToken,
      );
    }
    var name = pop() as IdentifierImpl;
    push(
      AnnotationImpl(
        atSign: atSign,
        name: name,
        typeArguments: typeArguments,
        period: periodBeforeName,
        constructorName: constructorName,
        arguments: invocation?.argumentList,
      ),
    );
  }

  @override
  void endMetadataStar(int count) {
    debugEvent("MetadataStar");

    push(popTypedList<AnnotationImpl>(count) ?? NullValues.Metadata);
  }

  @override
  void endMixinConstructor(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    debugEvent("MixinConstructor");

    invalidNodes.add(
      _buildConstructorDeclaration(beginToken: beginToken, endToken: endToken),
    );
  }

  @override
  void endMixinDeclaration(Token beginToken, Token endToken) {
    debugEvent("MixinDeclaration");

    var builder = _classLikeBuilder as _MixinDeclarationBuilder;
    declarations.add(builder.build());

    _classLikeBuilder = null;
  }

  @override
  void endMixinFactoryMethod(
    Token beginToken,
    Token factoryKeyword,
    Token endToken,
  ) {
    debugEvent("MixinFactoryMethod");

    invalidNodes.add(
      _buildFactoryConstructorDeclaration(
        beginToken: beginToken,
        factoryKeyword: factoryKeyword,
        endToken: endToken,
      ),
    );
  }

  @override
  void endMixinFields(
    Token? abstractToken,
    Token? augmentToken,
    Token? externalToken,
    Token? staticToken,
    Token? covariantToken,
    Token? lateToken,
    Token? varFinalOrConst,
    int count,
    Token beginToken,
    Token endToken,
  ) {
    endClassFields(
      abstractToken,
      augmentToken,
      externalToken,
      staticToken,
      covariantToken,
      lateToken,
      varFinalOrConst,
      count,
      beginToken,
      endToken,
    );
  }

  @override
  void endMixinMethod(
    Token? getOrSet,
    Token beginToken,
    Token beginParam,
    Token? beginInitializers,
    Token endToken,
  ) {
    debugEvent("MixinMethod");
    endClassMethod(
      getOrSet,
      beginToken,
      beginParam,
      beginInitializers,
      endToken,
    );
  }

  @override
  void endNamedFunctionExpression(Token endToken) {
    debugEvent("NamedFunctionExpression");
    var body = pop() as FunctionBodyImpl;
    if (isFullAst) {
      pop(); // constructor initializers
      pop(); // separator before constructor initializers
    }
    var parameters = pop() as FormalParameterListImpl;
    pop(); // name
    pop(); // returnType
    var typeParameters = pop() as TypeParameterListImpl?;
    push(
      FunctionExpressionImpl(
        typeParameters: typeParameters,
        parameters: parameters,
        body: body,
      ),
    );
  }

  @override
  void endNamedMixinApplication(
    Token beginToken,
    Token classKeyword,
    Token equalsToken,
    Token? implementsKeyword,
    Token semicolon,
  ) {
    assert(optional('class', classKeyword));
    assert(optionalOrNull('=', equalsToken));
    assert(optionalOrNull('implements', implementsKeyword));
    assert(optional(';', semicolon));
    debugEvent("NamedMixinApplication");

    ImplementsClauseImpl? implementsClause;
    if (implementsKeyword != null) {
      var interfaces = _popNamedTypeList(
        code: ParserErrorCode.EXPECTED_NAMED_TYPE_IMPLEMENTS,
      );
      implementsClause = ImplementsClauseImpl(
        implementsKeyword: implementsKeyword,
        interfaces: interfaces,
      );
    }
    var withClause = pop(NullValues.WithClause) as WithClauseImpl;
    var superclass = pop() as TypeAnnotationImpl;
    if (superclass is! NamedTypeImpl) {
      diagnosticReporter.diagnosticReporter?.atNode(
        superclass,
        ParserErrorCode.EXPECTED_NAMED_TYPE_EXTENDS,
      );
      var beginToken = superclass.beginToken;
      var endToken = superclass.endToken;
      var currentToken = beginToken;
      var count = 1;
      while (currentToken != endToken) {
        count++;
        currentToken = currentToken.next!;
      }
      var nameToken = parser.rewriter.replaceNextTokensWithSyntheticToken(
        beginToken.previous!,
        count,
        TokenType.IDENTIFIER,
      );
      superclass = NamedTypeImpl(
        importPrefix: null,
        name: nameToken,
        typeArguments: null,
        question: null,
      );
    }
    var mixinKeyword = pop(NullValues.Token) as Token?;
    var augmentKeyword = pop(NullValues.Token) as Token?;
    var finalKeyword = pop(NullValues.Token) as Token?;
    var interfaceKeyword = pop(NullValues.Token) as Token?;
    var baseKeyword = pop(NullValues.Token) as Token?;
    var sealedKeyword = pop(NullValues.Token) as Token?;
    pop(NullValues.Token) as Token?; // macroKeyword
    var modifiers = pop() as _Modifiers?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop() as SimpleIdentifierImpl;
    var abstractKeyword = modifiers?.abstractKeyword;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);
    declarations.add(
      ClassTypeAliasImpl(
        comment: comment,
        metadata: metadata,
        typedefKeyword: classKeyword,
        name: name.token,
        typeParameters: typeParameters,
        equals: equalsToken,
        abstractKeyword: abstractKeyword,
        sealedKeyword: sealedKeyword,
        baseKeyword: baseKeyword,
        interfaceKeyword: interfaceKeyword,
        finalKeyword: finalKeyword,
        augmentKeyword: augmentKeyword,
        mixinKeyword: mixinKeyword,
        superclass: superclass,
        withClause: withClause,
        implementsClause: implementsClause,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endNewExpression(Token newKeyword) {
    assert(optional('new', newKeyword));
    debugEvent("NewExpression");

    _handleInstanceCreation(newKeyword);
  }

  @override
  void endOptionalFormalParameters(
    int count,
    Token leftDelimiter,
    Token rightDelimiter,
    MemberKind kind,
  ) {
    assert(
      (optional('[', leftDelimiter) && optional(']', rightDelimiter)) ||
          (optional('{', leftDelimiter) && optional('}', rightDelimiter)),
    );
    debugEvent("OptionalFormalParameters");

    push(
      _OptionalFormalParameters(
        popTypedList2<FormalParameterImpl>(count),
        leftDelimiter,
        rightDelimiter,
      ),
    );
  }

  @override
  void endParenthesizedExpression(Token leftParenthesis) {
    assert(optional('(', leftParenthesis));
    debugEvent("ParenthesizedExpression");

    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);

    push(
      ParenthesizedExpressionImpl(
        leftParenthesis: leftParenthesis,
        expression: expression,
        rightParenthesis: leftParenthesis.endGroup!,
      ),
    );
  }

  @override
  void endPart(Token partKeyword, Token semicolon) {
    assert(optional('part', partKeyword));
    assert(optional(';', semicolon));
    debugEvent("Part");

    var configurations = pop() as List<ConfigurationImpl>?;
    if (!enableEnhancedParts) {
      var configuration = configurations?.firstOrNull;
      if (configuration != null) {
        _reportFeatureNotEnabled(
          feature: Feature.enhanced_parts,
          startToken: configuration.ifKeyword,
        );
        configurations = [];
      }
    }

    var uri = pop() as StringLiteralImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, partKeyword);
    directives.add(
      PartDirectiveImpl(
        comment: comment,
        metadata: metadata,
        partKeyword: partKeyword,
        uri: uri,
        configurations: configurations ?? [],
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endPartOf(
    Token partKeyword,
    Token ofKeyword,
    Token semicolon,
    bool hasName,
  ) {
    assert(optional('part', partKeyword));
    assert(optional('of', ofKeyword));
    assert(optional(';', semicolon));
    debugEvent("PartOf");
    var libraryNameOrUri = pop();
    LibraryIdentifierImpl? name;
    StringLiteralImpl? uri;
    if (libraryNameOrUri is StringLiteralImpl) {
      uri = libraryNameOrUri;
    } else {
      name = LibraryIdentifierImpl(
        components: libraryNameOrUri as List<SimpleIdentifierImpl>,
      );
      if (_featureSet.isEnabled(Feature.enhanced_parts)) {
        diagnosticReporter.diagnosticReporter?.atNode(
          name,
          ParserErrorCode.PART_OF_NAME,
        );
      }
    }
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, partKeyword);
    directives.add(
      PartOfDirectiveImpl(
        comment: comment,
        metadata: metadata,
        partKeyword: partKeyword,
        ofKeyword: ofKeyword,
        uri: uri,
        libraryName: name,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endPattern(Token token) {
    debugEvent("Pattern");
  }

  @override
  void endPatternGuard(Token when) {
    debugEvent("PatternGuard");
    var expression = pop() as ExpressionImpl;
    push(WhenClauseImpl(whenKeyword: when, expression: expression));
  }

  @override
  void endPrimaryConstructor(
    Token beginToken,
    Token? constKeyword,
    bool hasConstructorName,
  ) {
    var formalParameterList = pop() as FormalParameterListImpl?;
    if (formalParameterList == null) {
      var extensionTypeName = beginToken.previous!;
      formalParameterList = _syntheticFormalParameterList(extensionTypeName);
    }

    var leftParenthesis = formalParameterList.leftParenthesis;

    RepresentationConstructorNameImpl? constructorName;
    if (hasConstructorName) {
      var nameIdentifier = pop() as SimpleIdentifierImpl;
      constructorName = RepresentationConstructorNameImpl(
        period: beginToken,
        name: nameIdentifier.token,
      );
    }

    List<AnnotationImpl> fieldMetadata;
    TypeAnnotationImpl fieldType;
    Token fieldName;
    var firstFormalParameter = formalParameterList.parameters.firstOrNull;
    if (firstFormalParameter is SimpleFormalParameterImpl) {
      fieldMetadata = firstFormalParameter.metadata;
      switch (firstFormalParameter.type) {
        case var formalParameterType?:
          fieldType = formalParameterType;
        case null:
          diagnosticReporter.diagnosticReporter?.atToken(
            leftParenthesis.next!,
            ParserErrorCode.EXPECTED_REPRESENTATION_TYPE,
          );
          var typeNameToken = parser.rewriter.insertSyntheticIdentifier(
            leftParenthesis,
          );
          fieldType = NamedTypeImpl(
            importPrefix: null,
            name: typeNameToken,
            typeArguments: null,
            question: null,
          );
      }
      if (firstFormalParameter.keyword case var keyword?) {
        if (keyword.keyword != Keyword.CONST) {
          diagnosticReporter.diagnosticReporter?.atToken(
            keyword,
            ParserErrorCode.REPRESENTATION_FIELD_MODIFIER,
          );
        }
      }
      fieldName = firstFormalParameter.name!;
      // Check for multiple fields.
      var maybeComma = firstFormalParameter.endToken.next;
      if (maybeComma != null && maybeComma.type == TokenType.COMMA) {
        if (formalParameterList.parameters.length == 1) {
          diagnosticReporter.diagnosticReporter?.atToken(
            maybeComma,
            ParserErrorCode.REPRESENTATION_FIELD_TRAILING_COMMA,
          );
        } else {
          diagnosticReporter.diagnosticReporter?.atToken(
            maybeComma,
            ParserErrorCode.MULTIPLE_REPRESENTATION_FIELDS,
          );
        }
      }
    } else {
      diagnosticReporter.diagnosticReporter?.atToken(
        leftParenthesis.next!,
        ParserErrorCode.EXPECTED_REPRESENTATION_FIELD,
      );
      fieldMetadata = [];
      var typeNameToken = parser.rewriter.insertSyntheticIdentifier(
        leftParenthesis,
      );
      fieldType = NamedTypeImpl(
        importPrefix: null,
        name: typeNameToken,
        typeArguments: null,
        question: null,
      );
      fieldName = parser.rewriter.insertSyntheticIdentifier(typeNameToken);
    }

    push(constKeyword ?? const NullValue("Token"));

    push(
      RepresentationDeclarationImpl(
        constructorName: constructorName,
        leftParenthesis: leftParenthesis,
        fieldMetadata: fieldMetadata,
        fieldType: fieldType,
        fieldName: fieldName,
        rightParenthesis: formalParameterList.rightParenthesis,
      ),
    );
  }

  @override
  void endRecordLiteral(Token leftParenthesis, int count, Token? constKeyword) {
    debugEvent("RecordLiteral");

    var fields = popTypedList<ExpressionImpl>(count) ?? const [];
    var rightParenthesis = leftParenthesis.endGroup!;

    if (enableRecords) {
      push(
        RecordLiteralImpl(
          constKeyword: constKeyword,
          leftParenthesis: leftParenthesis,
          fields: fields,
          rightParenthesis: rightParenthesis,
        ),
      );
    } else {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.records,
        startToken: leftParenthesis,
      );

      var expression = fields.firstOrNull;
      expression ??= SimpleIdentifierImpl(
        token: parser.rewriter.insertSyntheticIdentifier(leftParenthesis),
      );

      push(
        ParenthesizedExpressionImpl(
          leftParenthesis: leftParenthesis,
          expression: expression,
          rightParenthesis: rightParenthesis,
        ),
      );
    }
  }

  @override
  void endRecordType(
    Token leftBracket,
    Token? questionMark,
    int count,
    bool hasNamedFields,
  ) {
    debugEvent("RecordType");

    RecordTypeAnnotationNamedFieldsImpl? namedFields;
    var elements = popTypedList<Object>(count) ?? const [];
    var last = elements.lastOrNull;
    if (last is RecordTypeAnnotationNamedFieldsImpl) {
      elements.removeLast();
      namedFields = last;
    }
    var positionalFields = <RecordTypeAnnotationPositionalFieldImpl>[];
    for (var elem in elements) {
      positionalFields.add(elem as RecordTypeAnnotationPositionalFieldImpl);
    }

    if (enableRecords) {
      push(
        RecordTypeAnnotationImpl(
          leftParenthesis: leftBracket,
          positionalFields: positionalFields,
          namedFields: namedFields,
          rightParenthesis: leftBracket.endGroup!,
          question: questionMark,
        ),
      );
    } else {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.records,
        startToken: leftBracket,
      );

      push(
        NamedTypeImpl(
          importPrefix: null,
          name: parser.rewriter.insertSyntheticIdentifier(leftBracket),
          typeArguments: null,
          question: questionMark,
        ),
      );
    }
  }

  @override
  void endRecordTypeEntry() {
    debugEvent("RecordTypeEntry");

    var name = pop() as SimpleIdentifierImpl?;
    var type = pop() as TypeAnnotationImpl;
    var metadata = pop() as List<AnnotationImpl>?;

    push(
      RecordTypeAnnotationPositionalFieldImpl(
        metadata: metadata,
        type: type,
        name: name?.token,
      ),
    );
  }

  @override
  void endRecordTypeNamedFields(int count, Token leftBracket) {
    debugEvent("RecordTypeNamedFields");

    var elements =
        popTypedList<RecordTypeAnnotationPositionalFieldImpl>(count) ??
        const [];
    var fields = <RecordTypeAnnotationNamedFieldImpl>[];
    for (var elem in elements) {
      fields.add(
        RecordTypeAnnotationNamedFieldImpl(
          metadata: elem.metadata,
          type: elem.type,
          name: elem.name!,
        ),
      );
    }
    push(
      RecordTypeAnnotationNamedFieldsImpl(
        leftBracket: leftBracket,
        fields: fields,
        rightBracket: leftBracket.endGroup!,
      ),
    );
  }

  @override
  void endRedirectingFactoryBody(Token equalToken, Token endToken) {
    assert(optional('=', equalToken));
    debugEvent("RedirectingFactoryBody");

    var constructorName = pop() as ConstructorNameImpl;
    var starToken = pop() as Token?;
    var asyncToken = pop() as Token?;
    push(
      _RedirectingFactoryBody(
        asyncToken,
        starToken,
        equalToken,
        constructorName,
      ),
    );
  }

  @override
  void endRethrowStatement(Token rethrowToken, Token semicolon) {
    assert(optional('rethrow', rethrowToken));
    assert(optional(';', semicolon));
    debugEvent("RethrowStatement");

    var expression = RethrowExpressionImpl(rethrowKeyword: rethrowToken);
    // TODO(scheglov): According to the specification, 'rethrow' is a statement.
    push(ExpressionStatementImpl(expression: expression, semicolon: semicolon));
  }

  @override
  void endReturnStatement(
    bool hasExpression,
    Token returnKeyword,
    Token semicolon,
  ) {
    assert(optional('return', returnKeyword));
    assert(optional(';', semicolon));
    debugEvent("ReturnStatement");

    var expression = hasExpression ? pop() as ExpressionImpl : null;
    push(
      ReturnStatementImpl(
        returnKeyword: returnKeyword,
        expression: expression,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endShow(Token showKeyword) {
    assert(optional('show', showKeyword));
    debugEvent("Show");

    var shownNames = pop() as List<SimpleIdentifierImpl>;
    push(ShowCombinatorImpl(keyword: showKeyword, shownNames: shownNames));
  }

  @override
  void endSwitchBlock(int caseCount, Token leftBracket, Token rightBracket) {
    assert(optional('{', leftBracket));
    assert(optional('}', rightBracket));
    debugEvent("SwitchBlock");

    var membersList = popTypedList2<List<SwitchMemberImpl>>(caseCount);
    var members = membersList.flattenedToList;

    Set<String> labels = <String>{};
    for (var member in members) {
      for (var label in member.labels) {
        if (!labels.add(label.label.name)) {
          handleRecoverableError(
            templateDuplicateLabelInSwitchStatement.withArguments(
              label.label.name,
            ),
            label.beginToken,
            label.beginToken,
          );
        }
      }
    }

    push(leftBracket);
    push(members);
    push(rightBracket);
  }

  @override
  void endSwitchCase(
    int labelCount,
    int expressionCount,
    Token? defaultKeyword,
    Token? colonAfterDefault,
    int statementCount,
    Token beginToken,
    Token endToken,
  ) {
    assert(optionalOrNull('default', defaultKeyword));
    assert(
      defaultKeyword == null
          ? colonAfterDefault == null
          : optional(':', colonAfterDefault!),
    );
    debugEvent("SwitchCase");

    var statements = popTypedList2<StatementImpl>(statementCount);
    List<SwitchMemberImpl?> members;

    List<LabelImpl> popLabels() {
      var labels = <LabelImpl>[];
      while (peek() is LabelImpl) {
        labels.insert(0, pop() as LabelImpl);
        --labelCount;
      }
      return labels;
    }

    SwitchMemberImpl updateSwitchMember({
      required SwitchMemberImpl member,
      List<LabelImpl>? labels,
      List<StatementImpl>? statements,
    }) {
      if (member is SwitchCaseImpl) {
        return SwitchCaseImpl(
          labels: labels ?? member.labels,
          keyword: member.keyword,
          expression: member.expression,
          colon: member.colon,
          statements: statements ?? member.statements,
        );
      } else if (member is SwitchDefaultImpl) {
        return SwitchDefaultImpl(
          labels: labels ?? member.labels,
          keyword: member.keyword,
          colon: member.colon,
          statements: statements ?? member.statements,
        );
      } else if (member is SwitchPatternCaseImpl) {
        return SwitchPatternCaseImpl(
          labels: labels ?? member.labels,
          keyword: member.keyword,
          guardedPattern: member.guardedPattern,
          colon: member.colon,
          statements: statements ?? member.statements,
        );
      } else {
        throw UnimplementedError('(${member.runtimeType}) $member');
      }
    }

    if (labelCount == 0 && defaultKeyword == null) {
      // Common situation: case with no default and no labels.
      members = popTypedList2<SwitchMemberImpl>(expressionCount);
    } else {
      // Labels and case statements may be intertwined
      if (defaultKeyword != null) {
        var labels = popLabels();
        var member = SwitchDefaultImpl(
          labels: labels,
          keyword: defaultKeyword,
          colon: colonAfterDefault!,
          statements: <StatementImpl>[],
        );
        members = List.filled(expressionCount + 1, null);
        members[expressionCount] = member;
      } else {
        members = List.filled(expressionCount, null);
      }
      for (int index = expressionCount - 1; index >= 0; --index) {
        var member = pop() as SwitchMemberImpl;
        var labels = popLabels();
        members[index] = updateSwitchMember(member: member, labels: labels);
      }
      assert(labelCount == 0);
    }

    var members2 = members.nonNulls.toList();
    if (members2.isNotEmpty) {
      members2.last = updateSwitchMember(
        member: members2.last,
        statements: statements,
      );
    }
    push(members2);
  }

  @override
  void endSwitchCaseWhenClause(Token token) {
    debugEvent("SwitchCaseWhenClause");
  }

  @override
  void endSwitchExpression(Token switchKeyword, Token endToken) {
    assert(optional('switch', switchKeyword));
    debugEvent("SwitchExpression");

    var rightBracket = pop() as Token;
    var cases = pop() as List<SwitchExpressionCaseImpl>;
    var leftBracket = pop() as Token;
    var condition = pop() as _ParenthesizedCondition;
    push(
      SwitchExpressionImpl(
        switchKeyword: switchKeyword,
        leftParenthesis: condition.leftParenthesis,
        expression: condition.expression,
        rightParenthesis: condition.rightParenthesis,
        leftBracket: leftBracket,
        cases: cases,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void endSwitchExpressionBlock(
    int caseCount,
    Token leftBracket,
    Token rightBracket,
  ) {
    assert(optional('{', leftBracket));
    assert(optional('}', rightBracket));
    debugEvent("SwitchExpressionBlock");

    var cases = popTypedList2<SwitchExpressionCaseImpl>(caseCount);

    push(leftBracket);
    push(cases);
    push(rightBracket);
  }

  @override
  void endSwitchExpressionCase(
    Token beginToken,
    Token? when,
    Token arrow,
    Token endToken,
  ) {
    debugEvent("SwitchExpressionCase");
    var expression = pop() as ExpressionImpl;
    WhenClauseImpl? whenClause;
    if (when != null) {
      var expression = pop() as ExpressionImpl;
      whenClause = WhenClauseImpl(whenKeyword: when, expression: expression);
    }
    var pattern = pop() as DartPatternImpl;
    push(
      SwitchExpressionCaseImpl(
        guardedPattern: GuardedPatternImpl(
          pattern: pattern,
          whenClause: whenClause,
        ),
        arrow: arrow,
        expression: expression,
      ),
    );
  }

  @override
  void endSwitchStatement(Token switchKeyword, Token endToken) {
    assert(optional('switch', switchKeyword));
    debugEvent("SwitchStatement");

    var rightBracket = pop() as Token;
    var members = pop() as List<SwitchMemberImpl>;
    var leftBracket = pop() as Token;
    var condition = pop() as _ParenthesizedCondition;
    push(
      SwitchStatementImpl(
        switchKeyword: switchKeyword,
        leftParenthesis: condition.leftParenthesis,
        expression: condition.expression,
        rightParenthesis: condition.rightParenthesis,
        leftBracket: leftBracket,
        members: members,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void endThenStatement(Token beginToken, Token endToken) {
    debugEvent("endThenStatement");
  }

  @override
  void endTopLevelDeclaration(Token endToken) {
    debugEvent("TopLevelDeclaration");
  }

  @override
  void endTopLevelFields(
    Token? augmentToken,
    Token? externalToken,
    Token? staticToken,
    Token? covariantToken,
    Token? lateToken,
    Token? varFinalOrConst,
    int count,
    Token beginToken,
    Token semicolon,
  ) {
    assert(optional(';', semicolon));
    debugEvent("TopLevelFields");

    if (externalToken != null) {
      if (lateToken != null) {
        handleRecoverableError(
          messageExternalLateField,
          externalToken,
          externalToken,
        );
      }
    }

    var variables = popTypedList2<VariableDeclarationImpl>(count);
    var type = pop() as TypeAnnotationImpl?;
    var variableList = VariableDeclarationListImpl(
      comment: null,
      metadata: null,
      lateKeyword: lateToken,
      keyword: varFinalOrConst,
      type: type,
      variables: variables,
    );
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);
    declarations.add(
      TopLevelVariableDeclarationImpl(
        comment: comment,
        metadata: metadata,
        augmentKeyword: augmentToken,
        externalKeyword: externalToken,
        variables: variableList,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void endTopLevelMethod(Token beginToken, Token? getOrSet, Token endToken) {
    // TODO(paulberry): set up scopes properly to resolve parameters and type
    // variables.
    assert(
      getOrSet == null ||
          optional('get', getOrSet) ||
          optional('set', getOrSet),
    );
    debugEvent("TopLevelMethod");

    var body = pop() as FunctionBodyImpl;
    var formalParameters = pop() as FormalParameterListImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop() as SimpleIdentifierImpl;
    var returnType = pop() as TypeAnnotationImpl?;
    var modifiers = pop() as _Modifiers?;
    var augmentKeyword = modifiers?.augmentKeyword;
    var externalKeyword = modifiers?.externalKeyword;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);

    if (getOrSet?.keyword == Keyword.SET) {
      formalParameters = _ensureSetterFormalParameter(name, formalParameters);
    }

    declarations.add(
      FunctionDeclarationImpl(
        comment: comment,
        metadata: metadata,
        augmentKeyword: augmentKeyword,
        externalKeyword: externalKeyword,
        returnType: returnType,
        propertyKeyword: getOrSet,
        name: name.token,
        functionExpression: FunctionExpressionImpl(
          typeParameters: typeParameters,
          parameters: formalParameters,
          body: body,
        ),
      ),
    );
  }

  @override
  void endTryStatement(
    int catchCount,
    Token tryKeyword,
    Token? finallyKeyword,
    Token endToken,
  ) {
    assert(optional('try', tryKeyword));
    assert(optionalOrNull('finally', finallyKeyword));
    debugEvent("TryStatement");

    var finallyBlock = popIfNotNull(finallyKeyword) as BlockImpl?;
    var catchClauses = popTypedList2<CatchClauseImpl>(catchCount);
    var body = pop() as BlockImpl;
    push(
      TryStatementImpl(
        tryKeyword: tryKeyword,
        body: body,
        catchClauses: catchClauses,
        finallyKeyword: finallyKeyword,
        finallyBlock: finallyBlock,
      ),
    );
  }

  @override
  void endTypeArguments(int count, Token leftBracket, Token rightBracket) {
    assert(optional('<', leftBracket));
    assert(optional('>', rightBracket));
    debugEvent("TypeArguments");

    var arguments = popTypedList2<TypeAnnotationImpl>(count);
    push(
      TypeArgumentListImpl(
        leftBracket: leftBracket,
        arguments: arguments,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void endTypedef(
    Token? augmentToken,
    Token typedefKeyword,
    Token? equals,
    Token semicolon,
  ) {
    assert(optional('typedef', typedefKeyword));
    assert(optionalOrNull('=', equals));
    assert(optional(';', semicolon));
    debugEvent("FunctionTypeAlias");

    if (equals == null) {
      var parameters = pop() as FormalParameterListImpl;
      var typeParameters = pop() as TypeParameterListImpl?;
      var name = pop() as SimpleIdentifierImpl;
      var returnType = pop() as TypeAnnotationImpl?;
      var metadata = pop() as List<AnnotationImpl>?;
      var comment = _findComment(metadata, typedefKeyword);
      declarations.add(
        FunctionTypeAliasImpl(
          comment: comment,
          metadata: metadata,
          augmentKeyword: augmentToken,
          typedefKeyword: typedefKeyword,
          returnType: returnType,
          name: name.token,
          typeParameters: typeParameters,
          parameters: parameters,
          semicolon: semicolon,
        ),
      );
    } else {
      var type = pop() as TypeAnnotationImpl;
      var templateParameters = pop() as TypeParameterListImpl?;
      var name = pop() as SimpleIdentifierImpl;
      var metadata = pop() as List<AnnotationImpl>?;
      var comment = _findComment(metadata, typedefKeyword);
      if (type is! GenericFunctionTypeImpl && !enableNonFunctionTypeAliases) {
        _reportFeatureNotEnabled(
          feature: ExperimentalFeatures.nonfunction_type_aliases,
          startToken: equals,
        );
      }
      declarations.add(
        GenericTypeAliasImpl(
          comment: comment,
          metadata: metadata,
          augmentKeyword: augmentToken,
          typedefKeyword: typedefKeyword,
          name: name.token,
          typeParameters: templateParameters,
          equals: equals,
          type: type,
          semicolon: semicolon,
        ),
      );
    }
  }

  @override
  void endTypeList(int count) {
    debugEvent("TypeList");
    push(popTypedList<TypeAnnotationImpl>(count) ?? NullValues.TypeList);
  }

  @override
  void endTypeVariable(
    Token token,
    int index,
    Token? extendsOrSuper,
    Token? variance,
  ) {
    debugEvent("TypeVariable");
    assert(
      extendsOrSuper == null ||
          optional('extends', extendsOrSuper) ||
          optional('super', extendsOrSuper),
    );

    // TODO(kallentu): Implement variance behaviour for the analyzer.
    assert(
      variance == null ||
          optional('in', variance) ||
          optional('out', variance) ||
          optional('inout', variance),
    );
    if (!enableVariance) {
      reportVarianceModifierNotEnabled(variance);
    }

    var bound = pop() as TypeAnnotationImpl?;

    // Peek to leave type parameters on top of stack.
    var typeParameters = peek() as List<TypeParameterImpl>;

    typeParameters[index]
      ..extendsKeyword = extendsOrSuper
      ..bound = bound
      ..varianceKeyword = variance;
  }

  @override
  void endTypeVariables(Token beginToken, Token endToken) {
    assert(optional('<', beginToken));
    assert(optional('>', endToken));
    debugEvent("TypeVariables");

    var typeParameters = pop() as List<TypeParameterImpl>;
    push(
      TypeParameterListImpl(
        leftBracket: beginToken,
        typeParameters: typeParameters,
        rightBracket: endToken,
      ),
    );
  }

  @override
  void endVariableInitializer(Token equals) {
    assert(optionalOrNull('=', equals));
    debugEvent("VariableInitializer");

    var initializer = pop() as ExpressionImpl;
    var identifier = pop() as SimpleIdentifierImpl;
    reportErrorIfSuper(initializer);
    // TODO(ahe): Don't push initializers, instead install them.
    push(
      VariableDeclarationImpl(
        comment: null,
        metadata: [],
        name: identifier.token,
        equals: equals,
        initializer: initializer,
      ),
    );
  }

  @override
  void endVariablesDeclaration(int count, Token? semicolon) {
    assert(optionalOrNull(';', semicolon));
    debugEvent("VariablesDeclaration");

    var variables = popTypedList2<VariableDeclarationImpl>(count);
    var modifiers = pop(NullValues.Modifiers) as _Modifiers?;
    var type = pop() as TypeAnnotationImpl?;
    var keyword = modifiers?.finalConstOrVarKeyword;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, variables[0].beginToken);
    // var comment = _findComment(metadata,
    //     variables[0].beginToken ?? type?.beginToken ?? modifiers.beginToken);

    // https://github.com/dart-lang/sdk/issues/53964
    if (semicolon != null && semicolon.isSynthetic) {
      if (variables.singleOrNull case var variable?) {
        if (type is NamedTypeImpl) {
          var importPrefix = type.importPrefix;
          if (importPrefix != null) {
            // x.^
            // await y.foo();
            {
              var awaitToken = type.name;
              if (awaitToken.type == Keyword.AWAIT) {
                push(
                  ExpressionStatementImpl(
                    expression: PrefixedIdentifierImpl(
                      prefix: SimpleIdentifierImpl(token: importPrefix.name),
                      period: importPrefix.period,
                      identifier: SimpleIdentifierImpl(
                        token: parser.rewriter.insertSyntheticIdentifier(
                          importPrefix.period,
                        ),
                      ),
                    ),
                    semicolon: semicolon,
                  ),
                );
                parser.rewriter.insertToken(semicolon, awaitToken);
                parser.rewriter.insertToken(awaitToken, variable.name);
                return;
              }
            }
            // x.foo^
            // await y.bar();
            {
              var awaitToken = variable.name;
              if (awaitToken.type == Keyword.AWAIT ||
                  awaitToken.type == TokenType.IDENTIFIER) {
                // We see `x.foo await;`, where `;` is synthetic.
                // It is followed by `y.bar()`.
                // Insert a new `;`, and (unfortunately) drop `await;`.
                type.name.setNext(semicolon.next!);
                var semicolon2 = parser.rewriter.insertSyntheticToken(
                  type.name,
                  TokenType.SEMICOLON,
                );
                push(
                  ExpressionStatementImpl(
                    expression: PrefixedIdentifierImpl(
                      prefix: SimpleIdentifierImpl(token: importPrefix.name),
                      period: importPrefix.period,
                      identifier: SimpleIdentifierImpl(token: type.name),
                    ),
                    semicolon: semicolon2,
                  ),
                );
                return;
              }
            }
          }
        }
      }
    }

    push(
      VariableDeclarationStatementImpl(
        variables: VariableDeclarationListImpl(
          comment: comment,
          metadata: metadata,
          lateKeyword: modifiers?.lateToken,
          keyword: keyword,
          type: type,
          variables: variables,
        ),
        semicolon: semicolon ?? Tokens.semicolon(),
      ),
    );
  }

  @override
  void endWhileStatement(Token whileKeyword, Token endToken) {
    assert(optional('while', whileKeyword));
    debugEvent("WhileStatement");

    var body = pop() as StatementImpl;
    var condition = pop() as _ParenthesizedCondition;
    push(
      WhileStatementImpl(
        whileKeyword: whileKeyword,
        leftParenthesis: condition.leftParenthesis,
        condition: condition.expression,
        rightParenthesis: condition.rightParenthesis,
        body: body,
      ),
    );
  }

  @override
  void endWhileStatementBody(Token endToken) {
    debugEvent("endWhileStatementBody");
  }

  @override
  void endYieldStatement(Token yieldToken, Token? starToken, Token semicolon) {
    assert(optional('yield', yieldToken));
    assert(optionalOrNull('*', starToken));
    assert(optional(';', semicolon));
    debugEvent("YieldStatement");

    var expression = pop() as ExpressionImpl;
    push(
      YieldStatementImpl(
        yieldKeyword: yieldToken,
        star: starToken,
        expression: expression,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void handleAdjacentStringLiterals(Token startToken, int literalCount) {
    debugEvent("AdjacentStringLiterals");

    var strings = popTypedList2<StringLiteralImpl>(literalCount);
    push(AdjacentStringsImpl(strings: strings));
  }

  @override
  void handleAsOperator(Token asOperator) {
    assert(optional('as', asOperator));
    debugEvent("AsOperator");

    var type = pop() as TypeAnnotationImpl;
    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);

    push(
      AsExpressionImpl(
        expression: expression,
        asOperator: asOperator,
        type: type,
      ),
    );
  }

  @override
  void handleAssignedVariablePattern(Token variable) {
    debugEvent('AssignedVariablePattern');
    assert(_featureSet.isEnabled(Feature.patterns));
    assert(variable.lexeme != '_');
    push(AssignedVariablePatternImpl(name: variable));
  }

  @override
  void handleAssignmentExpression(Token token, Token endToken) {
    assert(token.type.isAssignmentOperator);
    debugEvent("AssignmentExpression");

    var rhs = pop() as ExpressionImpl;
    var lhs = pop() as ExpressionImpl;
    if (!lhs.isAssignable) {
      // TODO(danrubel): Update the BodyBuilder to report this error.
      handleRecoverableError(
        messageMissingAssignableSelector,
        lhs.beginToken,
        lhs.endToken,
      );
    }
    reportErrorIfSuper(rhs);
    push(
      AssignmentExpressionImpl(
        leftHandSide: lhs,
        operator: token,
        rightHandSide: rhs,
      ),
    );
    if (!enableTripleShift && token.type == TokenType.GT_GT_GT_EQ) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.triple_shift,
        startToken: token,
      );
    }
  }

  @override
  void handleAsyncModifier(Token? asyncToken, Token? starToken) {
    assert(
      asyncToken == null ||
          optional('async', asyncToken) ||
          optional('sync', asyncToken),
    );
    assert(optionalOrNull('*', starToken));
    debugEvent("AsyncModifier");

    push(asyncToken ?? NullValues.FunctionBodyAsyncToken);
    push(starToken ?? NullValues.FunctionBodyStarToken);
  }

  @override
  void handleAugmentSuperExpression(
    Token augmentKeyword,
    Token superKeyword,
    IdentifierContext context,
  ) {
    assert(optional('augment', augmentKeyword));
    assert(optional('super', superKeyword));
    debugEvent("AugmentSuperExpression");
    throw UnimplementedError('AstBuilder.handleAugmentSuperExpression');
  }

  @override
  void handleBreakStatement(
    bool hasTarget,
    Token breakKeyword,
    Token semicolon,
  ) {
    assert(optional('break', breakKeyword));
    assert(optional(';', semicolon));
    debugEvent("BreakStatement");

    var label = hasTarget ? pop() as SimpleIdentifierImpl : null;
    push(
      BreakStatementImpl(
        breakKeyword: breakKeyword,
        label: label,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void handleCascadeAccess(
    Token operatorToken,
    Token endToken,
    bool isNullAware,
  ) {
    assert(optional('..', operatorToken) || optional('?..', operatorToken));
    debugEvent("CascadeAccess");

    doDotExpression(operatorToken);
  }

  @override
  void handleCastPattern(Token asOperator) {
    assert(optional('as', asOperator));
    debugEvent("CastPattern");

    var type = pop() as TypeAnnotationImpl;
    var pattern = pop() as DartPatternImpl;
    push(CastPatternImpl(pattern: pattern, asToken: asOperator, type: type));
  }

  @override
  void handleCatchBlock(Token? onKeyword, Token? catchKeyword, Token? comma) {
    assert(optionalOrNull('on', onKeyword));
    assert(optionalOrNull('catch', catchKeyword));
    assert(optionalOrNull(',', comma));
    debugEvent("CatchBlock");

    var body = pop() as BlockImpl;
    var catchParameterList =
        popIfNotNull(catchKeyword) as FormalParameterListImpl?;
    var type = popIfNotNull(onKeyword) as TypeAnnotationImpl?;
    Token? exception;
    Token? stackTrace;
    if (catchParameterList != null) {
      var catchParameters = catchParameterList.parameters;
      if (catchParameters.isNotEmpty) {
        exception = catchParameters[0].name;
      }
      if (catchParameters.length > 1) {
        stackTrace = catchParameters[1].name;
      }
    }
    push(
      CatchClauseImpl(
        onKeyword: onKeyword,
        exceptionType: type,
        catchKeyword: catchKeyword,
        leftParenthesis: catchParameterList?.leftParenthesis,
        exceptionParameter:
            exception != null
                ? CatchClauseParameterImpl(name: exception)
                : null,
        comma: comma,
        stackTraceParameter:
            stackTrace != null
                ? CatchClauseParameterImpl(name: stackTrace)
                : null,
        rightParenthesis: catchParameterList?.rightParenthesis,
        body: body,
      ),
    );
  }

  @override
  void handleClassExtends(Token? extendsKeyword, int typeCount) {
    assert(extendsKeyword == null || extendsKeyword.isKeywordOrIdentifier);
    debugEvent("ClassExtends");

    // If more extends clauses was specified (parser has already issued an
    // error) throw them away for now and pick the first one.
    while (typeCount > 1) {
      pop();
      typeCount--;
    }
    var supertype = pop() as TypeAnnotationImpl?;
    if (supertype is NamedTypeImpl) {
      push(
        ExtendsClauseImpl(
          extendsKeyword: extendsKeyword!,
          superclass: supertype,
        ),
      );
    } else {
      push(NullValues.ExtendsClause);
      // TODO(brianwilkerson): Consider (a) extending `ExtendsClause` to accept
      //  any type annotation for recovery purposes, and (b) extending the
      //  parser to parse a generic function type at this location.
      if (supertype != null) {
        diagnosticReporter.diagnosticReporter?.atNode(
          supertype,
          ParserErrorCode.EXPECTED_NAMED_TYPE_EXTENDS,
        );
      }
    }
  }

  @override
  void handleClassHeader(Token begin, Token classKeyword, Token? nativeToken) {
    assert(optional('class', classKeyword));
    assert(optionalOrNull('native', nativeToken));
    assert(_classLikeBuilder == null);
    debugEvent("ClassHeader");

    NativeClauseImpl? nativeClause;
    if (nativeToken != null) {
      nativeClause = NativeClauseImpl(
        nativeKeyword: nativeToken,
        name: nativeName,
      );
    }
    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var withClause = pop(NullValues.WithClause) as WithClauseImpl?;
    var extendsClause = pop(NullValues.ExtendsClause) as ExtendsClauseImpl?;
    var mixinKeyword = pop(NullValues.Token) as Token?;
    var augmentKeyword = pop(NullValues.Token) as Token?;
    var finalKeyword = pop(NullValues.Token) as Token?;
    var interfaceKeyword = pop(NullValues.Token) as Token?;
    var baseKeyword = pop(NullValues.Token) as Token?;
    var sealedKeyword = pop(NullValues.Token) as Token?;
    var macroKeyword = pop(NullValues.Token) as Token?;
    var modifiers = pop() as _Modifiers?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop() as SimpleIdentifierImpl;
    var abstractKeyword = modifiers?.abstractKeyword;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, begin);
    // leftBracket, members, and rightBracket
    // are set in [endClassOrMixinBody].
    _classLikeBuilder = _ClassDeclarationBuilder(
      comment: comment,
      metadata: metadata,
      abstractKeyword: abstractKeyword,
      macroKeyword: macroKeyword,
      sealedKeyword: sealedKeyword,
      baseKeyword: baseKeyword,
      interfaceKeyword: interfaceKeyword,
      finalKeyword: finalKeyword,
      augmentKeyword: augmentKeyword,
      mixinKeyword: mixinKeyword,
      classKeyword: classKeyword,
      name: name.token,
      typeParameters: typeParameters,
      extendsClause: extendsClause,
      withClause: withClause,
      implementsClause: implementsClause,
      nativeClause: nativeClause,
      leftBracket: Tokens.openCurlyBracket(),
      rightBracket: Tokens.closeCurlyBracket(),
    );
  }

  @override
  void handleClassNoWithClause() {
    push(NullValues.WithClause);
  }

  @override
  void handleClassWithClause(Token withKeyword) {
    assert(optional('with', withKeyword));
    var mixinTypes = _popNamedTypeList(
      code: ParserErrorCode.EXPECTED_NAMED_TYPE_WITH,
    );
    push(WithClauseImpl(withKeyword: withKeyword, mixinTypes: mixinTypes));
  }

  @override
  void handleConstFactory(Token constKeyword) {
    debugEvent("ConstFactory");
    // TODO(kallentu): Removal of const factory error for const function feature
    handleRecoverableError(messageConstFactory, constKeyword, constKeyword);
  }

  @override
  void handleContinueStatement(
    bool hasTarget,
    Token continueKeyword,
    Token semicolon,
  ) {
    assert(optional('continue', continueKeyword));
    assert(optional(';', semicolon));
    debugEvent("ContinueStatement");

    var label = hasTarget ? pop() as SimpleIdentifierImpl : null;
    push(
      ContinueStatementImpl(
        continueKeyword: continueKeyword,
        label: label,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void handleDeclaredVariablePattern(
    Token? keyword,
    Token variable, {
    required bool inAssignmentPattern,
  }) {
    debugEvent('DeclaredVariablePattern');
    assert(_featureSet.isEnabled(Feature.patterns));
    assert(variable.lexeme != '_');
    var type = pop() as TypeAnnotationImpl?;

    push(
      DeclaredVariablePatternImpl(keyword: keyword, type: type, name: variable),
    );
  }

  @override
  void handleDotAccess(Token operatorToken, Token endToken, bool isNullAware) {
    assert(optional('.', operatorToken) || optional('?.', operatorToken));
    debugEvent("DotAccess");

    doDotExpression(operatorToken);
  }

  @override
  void handleDotShorthandContext(Token token) {
    debugEvent("DotShorthandContext");
    if (!enabledDotShorthands) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.dot_shorthands,
        startToken: token,
      );
    }

    var dotShorthand = pop() as ExpressionImpl;
    if (dotShorthand is DotShorthandMixin) {
      dotShorthand.isDotShorthand = true;
    }
    // TODO(kallentu): Add this assert once we've applied the DotShorthandMixin
    // on all possible expressions that can be a dot shorthand.
    // } else {
    //   assert(
    //       false,
    //       "'$dotShorthand' must be a 'DotShorthandMixin' because we "
    //       "should only call 'handleDotShorthandContext' after parsing "
    //       "expressions that have a context type we can cache.");
    // }
    push(dotShorthand);
  }

  @override
  void handleDotShorthandHead(Token periodToken) {
    debugEvent("DotShorthandHead");
    if (!enabledDotShorthands) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.dot_shorthands,
        startToken: periodToken,
      );
    }

    var operand = pop() as ExpressionImpl;
    if (operand is SimpleIdentifierImpl) {
      push(
        DotShorthandPropertyAccessImpl(
          period: periodToken,
          propertyName: operand,
        ),
      );
    } else if (operand is MethodInvocationImpl) {
      push(
        DotShorthandInvocationImpl(
          period: periodToken,
          memberName: operand.methodName,
          typeArguments: operand.typeArguments,
          argumentList: operand.argumentList,
        ),
      );
    } else {
      push(operand);
    }
  }

  @override
  void handleDottedName(int count, Token firstIdentifier) {
    assert(firstIdentifier.isIdentifier);
    debugEvent("DottedName");

    var components = popTypedList2<SimpleIdentifierImpl>(count);
    push(DottedNameImpl(components: components));
  }

  @override
  void handleElseControlFlow(Token elseToken) {
    push(elseToken);
  }

  @override
  void handleEmptyFunctionBody(Token semicolon) {
    assert(optional(';', semicolon));
    debugEvent("EmptyFunctionBody");

    // TODO(scheglov): Change the parser to not produce these modifiers.
    pop(); // star
    pop(); // async
    push(EmptyFunctionBodyImpl(semicolon: semicolon));
  }

  @override
  void handleEmptyStatement(Token semicolon) {
    assert(optional(';', semicolon));
    debugEvent("EmptyStatement");

    push(EmptyStatementImpl(semicolon: semicolon));
  }

  @override
  void handleEnumElement(Token beginToken, Token? augmentToken) {
    debugEvent("EnumElement");
    var tmpArguments = pop() as MethodInvocationImpl?;
    var tmpConstructor = pop() as ConstructorNameImpl?;
    var constant = pop() as EnumConstantDeclarationImpl;

    if (!enableEnhancedEnums &&
        (tmpArguments != null ||
            tmpConstructor != null &&
                (tmpConstructor.type.typeArguments != null ||
                    tmpConstructor.name != null))) {
      Token token =
          tmpArguments != null
              ? tmpArguments.argumentList.beginToken
              : tmpConstructor!.beginToken;
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.enhanced_enums,
        startToken: token,
      );
    }

    var argumentList = tmpArguments?.argumentList;

    TypeArgumentListImpl? typeArguments;
    ConstructorSelectorImpl? constructorSelector;
    if (tmpConstructor != null) {
      typeArguments = tmpConstructor.type.typeArguments;
      var constructorNamePeriod = tmpConstructor.period;
      var constructorNameId = tmpConstructor.name;
      if (constructorNamePeriod != null && constructorNameId != null) {
        constructorSelector = ConstructorSelectorImpl(
          period: constructorNamePeriod,
          name: constructorNameId,
        );
      }
    }

    // Replace the constant to include arguments.
    if (argumentList != null) {
      constant = EnumConstantDeclarationImpl(
        comment: constant.documentationComment,
        metadata: constant.metadata,
        augmentKeyword: augmentToken,
        name: constant.name,
        arguments: EnumConstantArgumentsImpl(
          typeArguments: typeArguments,
          constructorSelector: constructorSelector,
          argumentList: argumentList,
        ),
      );
    }

    push(constant);
  }

  @override
  void handleEnumElements(Token elementsEndToken, int elementsCount) {
    debugEvent("EnumElements");
    var builder = _classLikeBuilder as _EnumDeclarationBuilder;

    var constants = popTypedList2<EnumConstantDeclarationImpl>(elementsCount);
    builder.constants.addAll(constants);

    if (optional(';', elementsEndToken)) {
      builder.semicolon = elementsEndToken;
    }

    if (!enableEnhancedEnums && optional(';', elementsEndToken)) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.enhanced_enums,
        startToken: elementsEndToken,
      );
    }
  }

  @override
  void handleEnumHeader(
    Token? augmentToken,
    Token enumKeyword,
    Token leftBrace,
  ) {
    assert(optional('enum', enumKeyword));
    assert(optional('{', leftBrace));
    debugEvent("EnumHeader");

    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var withClause = pop(NullValues.WithClause) as WithClauseImpl?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop() as SimpleIdentifierImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, enumKeyword);

    if (!enableEnhancedEnums &&
        (withClause != null ||
            implementsClause != null ||
            typeParameters != null)) {
      var token =
          withClause != null
              ? withClause.withKeyword
              : implementsClause != null
              ? implementsClause.implementsKeyword
              : typeParameters!.beginToken;
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.enhanced_enums,
        startToken: token,
      );
    }

    _classLikeBuilder = _EnumDeclarationBuilder(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentToken,
      enumKeyword: enumKeyword,
      name: name.token,
      typeParameters: typeParameters,
      withClause: withClause,
      implementsClause: implementsClause,
      leftBracket: leftBrace,
      semicolon: null,
      rightBracket: leftBrace.endGroup!,
    );
  }

  @override
  void handleEnumNoWithClause() {
    push(NullValues.WithClause);
  }

  @override
  void handleEnumWithClause(Token withKeyword) {
    assert(optional('with', withKeyword));
    var mixinTypes = _popNamedTypeList(
      code: ParserErrorCode.EXPECTED_NAMED_TYPE_WITH,
    );
    push(WithClauseImpl(withKeyword: withKeyword, mixinTypes: mixinTypes));
  }

  @override
  void handleErrorToken(ErrorToken token) {
    translateErrorToken(token, diagnosticReporter.reportScannerError);
  }

  @override
  void handleExpressionFunctionBody(Token arrowToken, Token? semicolon) {
    assert(optional('=>', arrowToken) || optional('=', arrowToken));
    assert(optionalOrNull(';', semicolon));
    debugEvent("ExpressionFunctionBody");

    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);
    var star = pop() as Token?;
    var asyncKeyword = pop() as Token?;
    if (parseFunctionBodies) {
      push(
        ExpressionFunctionBodyImpl(
          keyword: asyncKeyword,
          star: star,
          functionDefinition: arrowToken,
          expression: expression,
          semicolon: semicolon,
        ),
      );
    } else {
      push(EmptyFunctionBodyImpl(semicolon: semicolon!));
    }
  }

  @override
  void handleExpressionStatement(Token beginToken, Token semicolon) {
    assert(optional(';', semicolon));
    debugEvent("ExpressionStatement");
    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);
    if (expression is SimpleIdentifierImpl &&
        expression.token.keyword?.isBuiltInOrPseudo == false) {
      // This error is also reported by the body builder.
      handleRecoverableError(
        messageExpectedStatement,
        expression.beginToken,
        expression.endToken,
      );
    }
    if (expression is AssignmentExpressionImpl) {
      if (!expression.leftHandSide.isAssignable) {
        // This error is also reported by the body builder.
        handleRecoverableError(
          messageIllegalAssignmentToNonAssignable,
          expression.leftHandSide.beginToken,
          expression.leftHandSide.endToken,
        );
      }
    }
    push(ExpressionStatementImpl(expression: expression, semicolon: semicolon));
  }

  @override
  void handleFinallyBlock(Token finallyKeyword) {
    debugEvent("FinallyBlock");
    // The finally block is popped in "endTryStatement".
  }

  @override
  void handleForInitializerEmptyStatement(Token token) {
    debugEvent("ForInitializerEmptyStatement");
    push(NullValues.Expression);
  }

  @override
  void handleForInitializerExpressionStatement(Token token, bool forIn) {
    debugEvent("ForInitializerExpressionStatement");
  }

  @override
  void handleForInitializerLocalVariableDeclaration(Token token, bool forIn) {
    debugEvent("ForInitializerLocalVariableDeclaration");
  }

  @override
  void handleForInitializerPatternVariableAssignment(
    Token keyword,
    Token equals,
  ) {
    var expression = pop() as ExpressionImpl;
    var pattern = pop() as DartPatternImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    push(
      PatternVariableDeclarationImpl(
        keyword: keyword,
        pattern: pattern,
        equals: equals,
        expression: expression,
        comment: null,
        metadata: metadata,
      ),
    );
  }

  @override
  void handleForInLoopParts(
    Token? awaitToken,
    Token forToken,
    Token leftParenthesis,
    Token? patternKeyword,
    Token inKeyword,
  ) {
    assert(optionalOrNull('await', awaitToken));
    assert(optional('for', forToken));
    assert(optional('(', leftParenthesis));
    assert(optional('in', inKeyword) || optional(':', inKeyword));

    var iterable = pop() as ExpressionImpl;
    var variableOrDeclaration = pop()!;
    reportErrorIfSuper(iterable);

    ForEachPartsImpl forLoopParts;
    if (patternKeyword != null) {
      var metadata = pop() as List<AnnotationImpl>?;
      forLoopParts = ForEachPartsWithPatternImpl(
        metadata: metadata ?? [],
        keyword: patternKeyword,
        pattern: variableOrDeclaration as DartPatternImpl,
        inKeyword: inKeyword,
        iterable: iterable,
      );
    } else if (variableOrDeclaration is VariableDeclarationStatementImpl) {
      var variableList = variableOrDeclaration.variables;
      forLoopParts = ForEachPartsWithDeclarationImpl(
        loopVariable: DeclaredIdentifierImpl(
          comment: variableList.documentationComment,
          metadata: variableList.metadata,
          keyword: variableList.keyword,
          type: variableList.type,
          name: variableList.variables.first.name,
        ),
        inKeyword: inKeyword,
        iterable: iterable,
      );
    } else {
      if (variableOrDeclaration is! SimpleIdentifierImpl) {
        // Parser has already reported the error.
        if (!leftParenthesis.next!.isIdentifier) {
          parser.rewriter.insertSyntheticIdentifier(leftParenthesis);
        }
        variableOrDeclaration = SimpleIdentifierImpl(
          token: leftParenthesis.next!,
        );
      }
      forLoopParts = ForEachPartsWithIdentifierImpl(
        identifier: variableOrDeclaration,
        inKeyword: inKeyword,
        iterable: iterable,
      );
    }

    push(awaitToken ?? NullValues.AwaitToken);
    push(forToken);
    push(leftParenthesis);
    push(forLoopParts);
  }

  @override
  void handleForLoopParts(
    Token forKeyword,
    Token leftParen,
    Token leftSeparator,
    Token rightSeparator,
    int updateExpressionCount,
  ) {
    assert(optional('for', forKeyword));
    assert(optional('(', leftParen));
    assert(optional(';', leftSeparator));
    assert(updateExpressionCount >= 0);

    var updates = popTypedList2<ExpressionImpl>(updateExpressionCount);
    var conditionStatement = pop() as StatementImpl;
    var initializerPart = pop();

    for (var update in updates) {
      reportErrorIfSuper(update);
    }

    ExpressionImpl? condition;
    Token rightSeparator;
    if (conditionStatement is ExpressionStatementImpl) {
      condition = conditionStatement.expression;
      rightSeparator = conditionStatement.semicolon!;
    } else {
      rightSeparator = (conditionStatement as EmptyStatementImpl).semicolon;
    }

    ForPartsImpl forLoopParts;
    if (initializerPart is VariableDeclarationStatementImpl) {
      forLoopParts = ForPartsWithDeclarationsImpl(
        variables: initializerPart.variables,
        leftSeparator: leftSeparator,
        condition: condition,
        rightSeparator: rightSeparator,
        updaters: updates,
      );
    } else if (initializerPart is PatternVariableDeclarationImpl) {
      forLoopParts = ForPartsWithPatternImpl(
        variables: initializerPart,
        leftSeparator: leftSeparator,
        condition: condition,
        rightSeparator: rightSeparator,
        updaters: updates,
      );
    } else {
      forLoopParts = ForPartsWithExpressionImpl(
        initialization: initializerPart as ExpressionImpl?,
        leftSeparator: leftSeparator,
        condition: condition,
        rightSeparator: rightSeparator,
        updaters: updates,
      );
    }

    push(forKeyword);
    push(leftParen);
    push(forLoopParts);
  }

  @override
  void handleFormalParameterWithoutValue(Token token) {
    debugEvent("FormalParameterWithoutValue");

    push(NullValues.ParameterDefaultValue);
  }

  @override
  void handleIdentifier(Token token, IdentifierContext context) {
    assert(token.isKeywordOrIdentifier);
    debugEvent("handleIdentifier");

    if (context.inSymbol) {
      push(token);
      return;
    }

    var identifier = SimpleIdentifierImpl(token: token);
    if (context.inLibraryOrPartOfDeclaration) {
      if (!context.isContinuation) {
        push([identifier]);
      } else {
        push(identifier);
      }
    } else if (context == IdentifierContext.enumValueDeclaration) {
      var metadata = pop() as List<AnnotationImpl>?;
      var comment = _findComment(metadata, token);

      Token? augmentKeyword;
      if (token.previous case var previous?) {
        if (optional('augment', previous)) {
          augmentKeyword = previous;
        }
      }

      push(
        EnumConstantDeclarationImpl(
          comment: comment,
          metadata: metadata,
          augmentKeyword: augmentKeyword,
          name: token,
          arguments: null,
        ),
      );
    } else {
      push(identifier);
    }
  }

  @override
  void handleIdentifierList(int count) {
    debugEvent("IdentifierList");

    push(
      popTypedList<SimpleIdentifierImpl>(count) ?? NullValues.IdentifierList,
    );
  }

  @override
  void handleImplements(Token? implementsKeyword, int interfacesCount) {
    assert(optionalOrNull('implements', implementsKeyword));
    debugEvent("Implements");

    if (implementsKeyword != null) {
      endTypeList(interfacesCount);
      var interfaces = _popNamedTypeList(
        code: ParserErrorCode.EXPECTED_NAMED_TYPE_IMPLEMENTS,
      );
      push(
        ImplementsClauseImpl(
          implementsKeyword: implementsKeyword,
          interfaces: interfaces,
        ),
      );
    } else {
      push(NullValues.IdentifierList);
    }
  }

  @override
  void handleImportPrefix(Token? deferredKeyword, Token? asKeyword) {
    assert(optionalOrNull('deferred', deferredKeyword));
    assert(optionalOrNull('as', asKeyword));
    debugEvent("ImportPrefix");

    if (asKeyword == null) {
      // If asKeyword is null, then no prefix has been pushed on the stack.
      // Push a placeholder indicating that there is no prefix.
      push(NullValues.Prefix);
      push(NullValues.As);
    } else {
      push(asKeyword);
    }
    push(deferredKeyword ?? NullValues.Deferred);
  }

  @override
  void handleIndexedExpression(
    Token? question,
    Token leftBracket,
    Token rightBracket,
  ) {
    assert(optional('[', leftBracket) || optional('?.[', leftBracket));
    assert(optional(']', rightBracket));
    debugEvent("IndexedExpression");

    var index = pop() as ExpressionImpl;
    var target = pop() as ExpressionImpl?;
    reportErrorIfSuper(index);
    if (target == null) {
      var receiver = pop() as CascadeExpressionImpl;
      var token = peek() as Token;
      push(receiver);
      var expression = IndexExpressionImpl(
        target: null,
        period: token,
        question: question,
        leftBracket: leftBracket,
        index: index,
        rightBracket: rightBracket,
      );
      assert(expression.isCascaded);
      push(expression);
    } else {
      push(
        IndexExpressionImpl(
          target: target,
          period: null,
          question: question,
          leftBracket: leftBracket,
          index: index,
          rightBracket: rightBracket,
        ),
      );
    }
  }

  @override
  void handleInterpolationExpression(Token leftBracket, Token? rightBracket) {
    var expression = pop() as ExpressionImpl;
    push(
      InterpolationExpressionImpl(
        leftBracket: leftBracket,
        expression: expression,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void handleInvalidExpression(Token token) {
    debugEvent("InvalidExpression");
  }

  @override
  void handleInvalidFunctionBody(Token leftBracket) {
    assert(optional('{', leftBracket));
    assert(optional('}', leftBracket.endGroup!));
    debugEvent("InvalidFunctionBody");
    var block = BlockImpl(
      leftBracket: leftBracket,
      statements: [],
      rightBracket: leftBracket.endGroup!,
    );
    var star = pop() as Token?;
    var asyncKeyword = pop() as Token?;
    push(
      BlockFunctionBodyImpl(keyword: asyncKeyword, star: star, block: block),
    );
  }

  @override
  void handleInvalidMember(Token endToken) {
    debugEvent("InvalidMember");
    pop(); // metadata star
  }

  @override
  void handleInvalidOperatorName(Token operatorKeyword, Token token) {
    assert(optional('operator', operatorKeyword));
    debugEvent("InvalidOperatorName");

    push(_OperatorName(operatorKeyword, SimpleIdentifierImpl(token: token)));
  }

  @override
  void handleInvalidTopLevelBlock(Token token) {
    // TODO(danrubel): Consider improved recovery by adding this block
    // as part of a synthetic top level function.
    pop(); // block
  }

  @override
  void handleInvalidTopLevelDeclaration(Token endToken) {
    debugEvent("InvalidTopLevelDeclaration");

    pop(); // metadata star
    // TODO(danrubel): consider creating a AST node
    // representing the invalid declaration to better support code completion,
    // quick fixes, etc, rather than discarding the metadata and token
  }

  @override
  void handleInvalidTypeArguments(Token token) {
    var invalidTypeArgs = pop() as TypeArgumentListImpl;
    var node = pop();
    if (node is ConstructorNameImpl) {
      push(_ConstructorNameWithInvalidTypeArgs(node, invalidTypeArgs));
    } else {
      throw UnimplementedError(
        'node is an instance of ${node.runtimeType} in handleInvalidTypeArguments',
      );
    }
  }

  @override
  void handleIsOperator(Token isOperator, Token? not) {
    assert(optional('is', isOperator));
    assert(optionalOrNull('!', not));
    debugEvent("IsOperator");

    var type = pop() as TypeAnnotationImpl;
    var expression = pop() as ExpressionImpl;
    reportErrorIfSuper(expression);

    push(
      IsExpressionImpl(
        expression: expression,
        isOperator: isOperator,
        notOperator: not,
        type: type,
      ),
    );
  }

  @override
  void handleLabel(Token colon) {
    assert(optionalOrNull(':', colon));
    debugEvent("Label");

    var name = pop() as SimpleIdentifierImpl;
    push(LabelImpl(label: name, colon: colon));
  }

  @override
  void handleListPattern(int count, Token leftBracket, Token rightBracket) {
    assert(optional('[', leftBracket));
    assert(optional(']', rightBracket));
    debugEvent("ListPattern");

    var elements = popTypedList2<ListPatternElementImpl>(count);
    var typeArguments = pop() as TypeArgumentListImpl?;
    push(
      ListPatternImpl(
        typeArguments: typeArguments,
        leftBracket: leftBracket,
        elements: elements,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void handleLiteralBool(Token token) {
    bool value = boolFromToken(token);
    debugEvent("LiteralBool");

    push(BooleanLiteralImpl(literal: token, value: value));
  }

  @override
  void handleLiteralDouble(Token token) {
    assert(token.type == TokenType.DOUBLE);
    debugEvent("LiteralDouble");

    push(DoubleLiteralImpl(literal: token, value: double.parse(token.lexeme)));
  }

  @override
  void handleLiteralDoubleWithSeparators(Token token) {
    assert(token.type == TokenType.DOUBLE_WITH_SEPARATORS);
    debugEvent("LiteralDouble");

    if (!_enableDigitSeparators) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.digit_separators,
        startToken: token,
      );
    }

    push(
      DoubleLiteralImpl(
        literal: token,
        value: doubleFromToken(token, hasSeparators: true),
      ),
    );
  }

  @override
  void handleLiteralInt(Token token) {
    assert(
      identical(token.kind, INT_TOKEN) ||
          identical(token.kind, HEXADECIMAL_TOKEN),
    );
    debugEvent("LiteralInt");

    push(
      IntegerLiteralImpl(
        literal: token,
        value: intFromToken(token, hasSeparators: false),
      ),
    );
  }

  @override
  void handleLiteralIntWithSeparators(Token token) {
    assert(
      identical(token.kind, INT_TOKEN) ||
          identical(token.kind, HEXADECIMAL_TOKEN),
    );
    debugEvent("LiteralInt");

    if (!_enableDigitSeparators) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.digit_separators,
        startToken: token,
      );
    }

    push(
      IntegerLiteralImpl(
        literal: token,
        value: intFromToken(token, hasSeparators: true),
      ),
    );
  }

  @override
  void handleLiteralList(
    int count,
    Token leftBracket,
    Token? constKeyword,
    Token rightBracket,
  ) {
    assert(optional('[', leftBracket));
    assert(optionalOrNull('const', constKeyword));
    assert(optional(']', rightBracket));
    debugEvent("LiteralList");

    var elements = popCollectionElements(count);
    var typeArguments = pop() as TypeArgumentListImpl?;

    push(
      ListLiteralImpl(
        constKeyword: constKeyword,
        typeArguments: typeArguments,
        leftBracket: leftBracket,
        elements: elements,
        rightBracket: rightBracket,
      ),
    );
  }

  @override
  void handleLiteralMapEntry(
    Token colon,
    Token endToken, {
    Token? nullAwareKeyToken,
    Token? nullAwareValueToken,
  }) {
    assert(optional(':', colon));
    debugEvent("LiteralMapEntry");

    if (!enableNullAwareElements &&
        (nullAwareKeyToken != null || nullAwareValueToken != null)) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.null_aware_elements,
        startToken: nullAwareKeyToken ?? nullAwareValueToken!,
      );
      nullAwareKeyToken = null;
      nullAwareValueToken = null;
    }

    var value = pop() as ExpressionImpl;
    var key = pop() as ExpressionImpl;
    push(
      MapLiteralEntryImpl(
        keyQuestion: nullAwareKeyToken,
        key: key,
        separator: colon,
        valueQuestion: nullAwareValueToken,
        value: value,
      ),
    );
  }

  @override
  void handleLiteralNull(Token token) {
    assert(optional('null', token));
    debugEvent("LiteralNull");

    push(NullLiteralImpl(literal: token));
  }

  @override
  void handleLiteralSetOrMap(
    int count,
    Token leftBrace,
    Token? constKeyword,
    Token rightBrace,
    // TODO(danrubel): hasSetEntry parameter exists for replicating existing
    // behavior and will be removed once unified collection has been enabled
    bool hasSetEntry,
  ) {
    var elements = popCollectionElements(count);

    var typeArguments = pop() as TypeArgumentListImpl?;
    push(
      SetOrMapLiteralImpl(
        constKeyword: constKeyword,
        typeArguments: typeArguments,
        leftBracket: leftBrace,
        elements: elements,
        rightBracket: rightBrace,
      ),
    );
  }

  @override
  void handleMapPattern(int count, Token leftBrace, Token rightBrace) {
    debugEvent('MapPattern');

    var elements = popTypedList2<MapPatternElementImpl>(count);
    var typeArguments = pop() as TypeArgumentListImpl?;
    push(
      MapPatternImpl(
        typeArguments: typeArguments,
        leftBracket: leftBrace,
        elements: elements,
        rightBracket: rightBrace,
      ),
    );
  }

  @override
  void handleMapPatternEntry(Token colon, Token endToken) {
    assert(optional(':', colon));
    debugEvent("MapPatternEntry");

    var value = pop() as DartPatternImpl;
    var key = pop() as ExpressionImpl;
    push(MapPatternEntryImpl(key: key, separator: colon, value: value));
  }

  @override
  void handleMixinHeader(Token mixinKeyword) {
    assert(optional('mixin', mixinKeyword));
    assert(_classLikeBuilder == null);
    debugEvent("MixinHeader");

    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var onClause = pop(NullValues.IdentifierList) as MixinOnClauseImpl?;
    var baseKeyword = pop(NullValues.Token) as Token?;
    var augmentKeyword = pop(NullValues.Token) as Token?;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop() as SimpleIdentifierImpl;
    var metadata = pop() as List<AnnotationImpl>?;

    var begin = baseKeyword ?? mixinKeyword;
    var comment = _findComment(metadata, begin);

    _classLikeBuilder = _MixinDeclarationBuilder(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      baseKeyword: baseKeyword,
      mixinKeyword: mixinKeyword,
      name: name.token,
      typeParameters: typeParameters,
      onClause: onClause,
      implementsClause: implementsClause,
      leftBracket: Tokens.openCurlyBracket(),
      rightBracket: Tokens.closeCurlyBracket(),
    );
  }

  @override
  void handleMixinOn(Token? onKeyword, int typeCount) {
    assert(onKeyword == null || onKeyword.isKeywordOrIdentifier);
    debugEvent("MixinOn");

    if (onKeyword != null) {
      endTypeList(typeCount);
      var onTypes = _popNamedTypeList(
        code: ParserErrorCode.EXPECTED_NAMED_TYPE_ON,
      );
      push(
        MixinOnClauseImpl(onKeyword: onKeyword, superclassConstraints: onTypes),
      );
    } else {
      push(NullValues.IdentifierList);
    }
  }

  @override
  void handleMixinWithClause(Token withKeyword) {
    assert(optional('with', withKeyword));
    // This is an error case. An error has been issued already.
    // Possibly the data could be used for help though.
    _popNamedTypeList(code: ParserErrorCode.EXPECTED_NAMED_TYPE_WITH);
  }

  @override
  void handleNamedArgument(Token colon) {
    assert(optional(':', colon));
    debugEvent("NamedArgument");

    var expression = pop() as ExpressionImpl;
    var name = pop() as SimpleIdentifierImpl;

    push(
      NamedExpressionImpl(
        name: LabelImpl(label: name, colon: colon),
        expression: expression,
      ),
    );
  }

  @override
  void handleNamedMixinApplicationWithClause(Token withKeyword) {
    assert(optionalOrNull('with', withKeyword));
    var mixinTypes = _popNamedTypeList(
      code: ParserErrorCode.EXPECTED_NAMED_TYPE_WITH,
    );
    push(WithClauseImpl(withKeyword: withKeyword, mixinTypes: mixinTypes));
  }

  @override
  void handleNamedRecordField(Token colon) => handleNamedArgument(colon);

  @override
  void handleNativeClause(Token nativeToken, bool hasName) {
    debugEvent("NativeClause");

    if (hasName) {
      nativeName = pop() as StringLiteralImpl;
    } else {
      nativeName = null;
    }
  }

  @override
  void handleNativeFunctionBody(Token nativeToken, Token semicolon) {
    assert(optional('native', nativeToken));
    assert(optional(';', semicolon));
    debugEvent("NativeFunctionBody");

    // TODO(danrubel): Change the parser to not produce these modifiers.
    pop(); // star
    pop(); // async
    push(
      NativeFunctionBodyImpl(
        nativeKeyword: nativeToken,
        stringLiteral: nativeName,
        semicolon: semicolon,
      ),
    );
  }

  @override
  void handleNewAsIdentifier(Token token) {
    if (!enableConstructorTearoffs) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.constructor_tearoffs,
        startToken: token,
      );
    }
  }

  @override
  void handleNoConstructorReferenceContinuationAfterTypeArguments(Token token) {
    debugEvent("NoConstructorReferenceContinuationAfterTypeArguments");

    push(NullValues.ConstructorReferenceContinuationAfterTypeArguments);
  }

  @override
  void handleNoFieldInitializer(Token token) {
    debugEvent("NoFieldInitializer");

    var name = pop() as SimpleIdentifierImpl;
    push(
      VariableDeclarationImpl(
        comment: null,
        metadata: [],
        name: name.token,
        equals: null,
        initializer: null,
      ),
    );
  }

  @override
  void handleNoInitializers() {
    debugEvent("NoInitializers");

    if (!isFullAst) return;
    push(NullValues.ConstructorInitializerSeparator);
    push(NullValues.ConstructorInitializers);
  }

  @override
  void handleNonNullAssertExpression(Token bang) {
    debugEvent('NonNullAssertExpression');

    push(
      PostfixExpressionImpl(operand: pop() as ExpressionImpl, operator: bang),
    );
  }

  @override
  void handleNoPrimaryConstructor(Token token, Token? constKeyword) {
    push(constKeyword ?? const NullValue("Token"));

    push(const NullValue("RepresentationDeclarationImpl"));
  }

  @override
  void handleNoTypeNameInConstructorReference(Token token) {
    debugEvent("NoTypeNameInConstructorReference");
    var builder = _classLikeBuilder as _EnumDeclarationBuilder;

    push(SimpleIdentifierImpl(token: builder.name));
  }

  @override
  void handleNoVariableInitializer(Token token) {
    debugEvent("NoVariableInitializer");
  }

  @override
  void handleNullAssertPattern(Token bang) {
    debugEvent("NullAssertPattern");
    push(
      NullAssertPatternImpl(pattern: pop() as DartPatternImpl, operator: bang),
    );
  }

  @override
  void handleNullAwareElement(Token nullAwareElement) {
    debugEvent('NullAwareElement');
    if (!enableNullAwareElements) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.null_aware_elements,
        startToken: nullAwareElement,
      );
    } else {
      var expression = pop() as ExpressionImpl;
      push(NullAwareElementImpl(question: nullAwareElement, value: expression));
    }
  }

  @override
  void handleNullCheckPattern(Token question) {
    debugEvent('NullCheckPattern');
    if (!_featureSet.isEnabled(Feature.patterns)) {
      // TODO(paulberry): report the appropriate error
      throw UnimplementedError('Patterns not enabled');
    }
    push(
      NullCheckPatternImpl(
        pattern: pop() as DartPatternImpl,
        operator: question,
      ),
    );
  }

  @override
  void handleObjectPattern(
    Token firstIdentifierToken,
    Token? dot,
    Token? secondIdentifierToken,
  ) {
    debugEvent("ExtractorPattern");

    var arguments = pop() as _ObjectPatternFields;
    var typeArguments = pop() as TypeArgumentListImpl?;

    NamedTypeImpl namedType;
    if (dot != null && secondIdentifierToken != null) {
      namedType = NamedTypeImpl(
        importPrefix: ImportPrefixReferenceImpl(
          name: firstIdentifierToken,
          period: dot,
        ),
        name: secondIdentifierToken,
        typeArguments: typeArguments,
        question: null,
      );
    } else {
      namedType = NamedTypeImpl(
        importPrefix: null,
        name: firstIdentifierToken,
        typeArguments: typeArguments,
        question: null,
      );
    }

    push(
      ObjectPatternImpl(
        type: namedType,
        leftParenthesis: arguments.leftParenthesis,
        fields: arguments.fields,
        rightParenthesis: arguments.rightParenthesis,
      ),
    );
  }

  @override
  void handleObjectPatternFields(int count, Token beginToken, Token endToken) {
    debugEvent("ExtractorPatternFields");
    var fields = popTypedList2<PatternFieldImpl>(count);
    push(_ObjectPatternFields(beginToken, endToken, fields));
  }

  @override
  void handleOperator(Token operatorToken) {
    assert(operatorToken.isUserDefinableOperator);
    debugEvent("Operator");

    push(operatorToken);
  }

  @override
  void handleOperatorName(Token operatorKeyword, Token token) {
    assert(optional('operator', operatorKeyword));
    assert(token.type.isUserDefinableOperator);
    debugEvent("OperatorName");

    push(_OperatorName(operatorKeyword, SimpleIdentifierImpl(token: token)));
  }

  @override
  void handleParenthesizedCondition(
    Token leftParenthesis,
    Token? case_,
    Token? when,
  ) {
    ExpressionImpl condition;
    CaseClauseImpl? caseClause;
    if (case_ != null) {
      var whenClause = when != null ? pop() as WhenClauseImpl : null;
      var pattern = pop() as DartPatternImpl;
      caseClause = CaseClauseImpl(
        caseKeyword: case_,
        guardedPattern: GuardedPatternImpl(
          pattern: pattern,
          whenClause: whenClause,
        ),
      );
    }
    condition = pop() as ExpressionImpl;
    reportErrorIfSuper(condition);
    push(_ParenthesizedCondition(leftParenthesis, condition, caseClause));
  }

  @override
  void handleParenthesizedPattern(Token leftParenthesis) {
    assert(optional('(', leftParenthesis));
    debugEvent("ParenthesizedPattern");

    var pattern = pop() as DartPatternImpl;
    push(
      ParenthesizedPatternImpl(
        leftParenthesis: leftParenthesis,
        pattern: pattern,
        rightParenthesis: leftParenthesis.endGroup!,
      ),
    );
  }

  @override
  void handlePatternAssignment(Token equals) {
    var expression = pop() as ExpressionImpl;
    var pattern = pop() as DartPatternImpl;
    push(
      PatternAssignmentImpl(
        pattern: pattern,
        equals: equals,
        expression: expression,
      ),
    );
  }

  @override
  void handlePatternField(Token? colon) {
    debugEvent("PatternField");

    var pattern = pop() as DartPatternImpl;
    PatternFieldNameImpl? fieldName;
    if (colon != null) {
      var name = (pop() as SimpleIdentifierImpl?)?.token;
      fieldName = PatternFieldNameImpl(name: name, colon: colon);
    }
    push(PatternFieldImpl(name: fieldName, pattern: pattern));
  }

  @override
  void handlePatternVariableDeclarationStatement(
    Token keyword,
    Token equals,
    Token semicolon,
  ) {
    var expression = pop() as ExpressionImpl;
    var pattern = pop() as DartPatternImpl;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, keyword);
    push(
      PatternVariableDeclarationStatementImpl(
        declaration: PatternVariableDeclarationImpl(
          keyword: keyword,
          pattern: pattern,
          equals: equals,
          expression: expression,
          comment: comment,
          metadata: metadata,
        ),
        semicolon: semicolon,
      ),
    );
  }

  @override
  void handleQualified(Token period) {
    assert(optional('.', period));

    var identifier = pop() as SimpleIdentifierImpl;
    var prefix = pop();
    if (prefix is List) {
      // We're just accumulating components into a list.
      prefix.add(identifier);
      push(prefix);
    } else if (prefix is SimpleIdentifierImpl) {
      // TODO(paulberry): resolve [identifier].  Note that BodyBuilder handles
      // this situation using SendAccessGenerator.
      push(
        PrefixedIdentifierImpl(
          prefix: prefix,
          period: period,
          identifier: identifier,
        ),
      );
    } else {
      // TODO(paulberry): implement.
      logEvent('Qualified with >1 dot');
    }
  }

  @override
  void handleRecordPattern(Token token, int count) {
    debugEvent("RecordPattern");

    var fields = popTypedList2<PatternFieldImpl>(count);
    push(
      RecordPatternImpl(
        leftParenthesis: token,
        fields: fields,
        rightParenthesis: token.endGroup!,
      ),
    );
  }

  @override
  void handleRecoverableError(
    Message message,
    Token startToken,
    Token endToken,
  ) {
    // TODO(danrubel): Ignore this error until we deprecate `native` support.
    if (message == messageNativeClauseShouldBeAnnotation && allowNativeClause) {
      return;
    } else if (message.code == codeBuiltInIdentifierInDeclaration) {
      // Allow e.g. 'class Function' in sdk.
      if (isDartLibrary) return;
    }
    debugEvent("Error: ${message.problemMessage}");
    if (message.code.analyzerCodes == null && startToken is ErrorToken) {
      translateErrorToken(startToken, diagnosticReporter.reportScannerError);
    } else {
      int offset = startToken.offset;
      int length = endToken.end - offset;
      addProblem(message, offset, length);
    }
  }

  @override
  void handleRecoverDeclarationHeader(DeclarationHeaderKind kind) {
    debugEvent("RecoverClassHeader");

    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var withClause = pop(NullValues.WithClause) as WithClauseImpl?;
    var extendsClause = pop(NullValues.ExtendsClause) as ExtendsClauseImpl?;
    switch (kind) {
      case DeclarationHeaderKind.Class:
        var declaration = _classLikeBuilder as _ClassDeclarationBuilder;
        if (extendsClause != null) {
          if (declaration.extendsClause?.superclass == null) {
            declaration.extendsClause = extendsClause;
          }
        }
        if (withClause != null) {
          var existingClause = declaration.withClause;
          if (existingClause == null) {
            declaration.withClause = withClause;
          } else {
            declaration.withClause = WithClauseImpl(
              withKeyword: existingClause.withKeyword,
              mixinTypes: [
                ...existingClause.mixinTypes,
                ...withClause.mixinTypes,
              ],
            );
          }
        }
        if (implementsClause != null) {
          var existingClause = declaration.implementsClause;
          if (existingClause == null) {
            declaration.implementsClause = implementsClause;
          } else {
            declaration.implementsClause = ImplementsClauseImpl(
              implementsKeyword: existingClause.implementsKeyword,
              interfaces: [
                ...existingClause.interfaces,
                ...implementsClause.interfaces,
              ],
            );
          }
        }
      case DeclarationHeaderKind.ExtensionType:
      // TODO(scheglov): Support header recovery on extension type
      //  declaration.
    }
  }

  @override
  void handleRecoverImport(Token? semicolon) {
    assert(optionalOrNull(';', semicolon));
    debugEvent("RecoverImport");

    var combinators = pop() as List<CombinatorImpl>?;
    var deferredKeyword = pop(NullValues.Deferred) as Token?;
    var asKeyword = pop(NullValues.As) as Token?;
    var prefix = pop(NullValues.Prefix) as SimpleIdentifierImpl?;
    var configurations = pop() as List<ConfigurationImpl>?;

    var directive = directives.last;
    switch (directive) {
      case ImportDirectiveImpl():
        // TODO(scheglov): This code would be easier if we used one object.
        var mergedAsKeyword = directive.asKeyword;
        var mergedPrefix = directive.prefix;
        if (directive.asKeyword == null && asKeyword != null) {
          mergedAsKeyword = asKeyword;
          mergedPrefix = prefix;
        }

        directives.last = ImportDirectiveImpl(
          comment: directive.documentationComment,
          metadata: directive.metadata,
          importKeyword: directive.importKeyword,
          uri: directive.uri,
          configurations: [...directive.configurations, ...?configurations],
          deferredKeyword: directive.deferredKeyword ?? deferredKeyword,
          asKeyword: mergedAsKeyword,
          prefix: mergedPrefix,
          combinators: [...directive.combinators, ...?combinators],
          semicolon: semicolon ?? directive.semicolon,
        );
      default:
        throw UnimplementedError('${directive.runtimeType}');
    }
  }

  @override
  void handleRecoverMixinHeader() {
    var builder = _classLikeBuilder as _MixinDeclarationBuilder;
    var implementsClause =
        pop(NullValues.IdentifierList) as ImplementsClauseImpl?;
    var onClause = pop(NullValues.IdentifierList) as MixinOnClauseImpl?;

    if (onClause != null) {
      var existingClause = builder.onClause;
      if (existingClause == null) {
        builder.onClause = onClause;
      } else {
        builder.onClause = MixinOnClauseImpl(
          onKeyword: existingClause.onKeyword,
          superclassConstraints: [
            ...existingClause.superclassConstraints,
            ...onClause.superclassConstraints,
          ],
        );
      }
    }
    if (implementsClause != null) {
      var existingClause = builder.implementsClause;
      if (existingClause == null) {
        builder.implementsClause = implementsClause;
      } else {
        builder.implementsClause = ImplementsClauseImpl(
          implementsKeyword: implementsClause.implementsKeyword,
          interfaces: [
            ...existingClause.interfaces,
            ...implementsClause.interfaces,
          ],
        );
      }
    }
  }

  @override
  void handleRelationalPattern(Token token) {
    debugEvent("RelationalPattern");
    push(
      RelationalPatternImpl(operator: token, operand: pop() as ExpressionImpl),
    );
  }

  @override
  void handleRestPattern(Token dots, {required bool hasSubPattern}) {
    var subPattern = hasSubPattern ? pop() as DartPatternImpl : null;
    push(RestPatternElementImpl(operator: dots, pattern: subPattern));
  }

  @override
  void handleScript(Token token) {
    assert(identical(token.type, TokenType.SCRIPT_TAG));
    debugEvent("Script");

    scriptTag = ScriptTagImpl(scriptTag: token);
  }

  @override
  void handleSend(Token beginToken, Token endToken) {
    debugEvent("Send");

    var arguments = pop() as MethodInvocationImpl?;
    var typeArguments = pop() as TypeArgumentListImpl?;
    if (arguments != null) {
      doInvocation(typeArguments, arguments);
    } else {
      doPropertyGet();
    }
  }

  @override
  void handleSpreadExpression(Token spreadToken) {
    var expression = pop() as ExpressionImpl;
    push(
      SpreadElementImpl(spreadOperator: spreadToken, expression: expression),
    );
  }

  @override
  void handleStringPart(Token literalString) {
    assert(identical(literalString.kind, STRING_TOKEN));
    debugEvent("StringPart");

    push(literalString);
  }

  @override
  void handleSuperExpression(Token superKeyword, IdentifierContext context) {
    assert(optional('super', superKeyword));
    debugEvent("SuperExpression");
    push(SuperExpressionImpl(superKeyword: superKeyword));
  }

  @override
  void handleSwitchCaseNoWhenClause(Token token) {
    debugEvent("SwitchCaseNoWhenClause");
  }

  @override
  void handleSwitchExpressionCasePattern(Token token) {
    debugEvent("SwitchExpressionCasePattern");
  }

  @override
  void handleSymbolVoid(Token voidKeyword) {
    assert(optional('void', voidKeyword));
    debugEvent("SymbolVoid");

    push(voidKeyword);
  }

  @override
  void handleThisExpression(Token thisKeyword, IdentifierContext context) {
    assert(optional('this', thisKeyword));
    debugEvent("ThisExpression");

    push(ThisExpressionImpl(thisKeyword: thisKeyword));
  }

  @override
  void handleThrowExpression(Token throwToken, Token endToken) {
    assert(optional('throw', throwToken));
    debugEvent("ThrowExpression");

    push(
      ThrowExpressionImpl(
        throwKeyword: throwToken,
        expression: pop() as ExpressionImpl,
      ),
    );
  }

  @override
  void handleType(Token beginToken, Token? question) {
    debugEvent("Type");

    var arguments = pop() as TypeArgumentListImpl?;
    var name = pop() as IdentifierImpl;

    push(name.toNamedType(typeArguments: arguments, question: question));
  }

  @override
  void handleTypeArgumentApplication(Token openAngleBracket) {
    var typeArguments = pop() as TypeArgumentListImpl;
    var receiver = pop() as ExpressionImpl;
    if (!enableConstructorTearoffs) {
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.constructor_tearoffs,
        startToken: typeArguments.leftBracket,
        endToken: typeArguments.rightBracket,
      );
    }
    reportErrorIfSuper(receiver);
    push(
      FunctionReferenceImpl(function: receiver, typeArguments: typeArguments),
    );
  }

  @override
  void handleTypeVariablesDefined(Token token, int count) {
    debugEvent("handleTypeVariablesDefined");
    assert(count > 0);
    push(popTypedList<TypeParameterImpl>(count));
  }

  @override
  void handleUnaryPostfixAssignmentExpression(Token operator) {
    assert(operator.type.isUnaryPostfixOperator);
    debugEvent("UnaryPostfixAssignmentExpression");

    var expression = pop() as ExpressionImpl;
    if (!expression.isAssignable) {
      // This error is also reported by the body builder.
      handleRecoverableError(
        messageIllegalAssignmentToNonAssignable,
        operator,
        operator,
      );
    }
    push(PostfixExpressionImpl(operand: expression, operator: operator));
  }

  @override
  void handleUnaryPrefixAssignmentExpression(Token operator) {
    assert(operator.type.isUnaryPrefixOperator);
    debugEvent("UnaryPrefixAssignmentExpression");

    var expression = pop() as ExpressionImpl;
    if (!expression.isAssignable) {
      // This error is also reported by the body builder.
      handleRecoverableError(
        messageMissingAssignableSelector,
        expression.endToken,
        expression.endToken,
      );
    }
    push(PrefixExpressionImpl(operator: operator, operand: expression));
  }

  @override
  void handleUnaryPrefixExpression(Token operator) {
    assert(operator.type.isUnaryPrefixOperator);
    debugEvent("UnaryPrefixExpression");

    var operand = pop() as ExpressionImpl;
    if (!(operator.type == TokenType.MINUS ||
        operator.type == TokenType.TILDE)) {
      reportErrorIfSuper(operand);
    }

    push(PrefixExpressionImpl(operator: operator, operand: operand));
  }

  @override
  void handleValuedFormalParameter(
    Token equals,
    Token token,
    FormalParameterKind kind,
  ) {
    assert(optional('=', equals) || optional(':', equals));
    debugEvent("ValuedFormalParameter");

    var value = pop() as ExpressionImpl;
    push(_ParameterDefaultValue(equals, value));
  }

  @override
  void handleVoidKeyword(Token voidKeyword) {
    assert(optional('void', voidKeyword));
    debugEvent("VoidKeyword");

    // TODO(paulberry): is this sufficient, or do we need to hook the "void"
    // keyword up to an element?
    handleIdentifier(voidKeyword, IdentifierContext.typeReference);
    handleNoTypeArguments(voidKeyword);
    handleType(voidKeyword, null);
  }

  @override
  void handleVoidKeywordWithTypeArguments(Token voidKeyword) {
    assert(optional('void', voidKeyword));
    debugEvent("VoidKeywordWithTypeArguments");
    var arguments = pop() as TypeArgumentListImpl;

    // TODO(paulberry): is this sufficient, or do we need to hook the "void"
    // keyword up to an element?
    handleIdentifier(voidKeyword, IdentifierContext.typeReference);
    push(arguments);
    handleType(voidKeyword, null);
  }

  @override
  void handleWildcardPattern(Token? keyword, Token wildcard) {
    debugEvent('WildcardPattern');
    assert(_featureSet.isEnabled(Feature.patterns));
    // Note: if `default` appears in a switch expression, parser error recovery
    // treats it as a wildcard pattern.
    assert(wildcard.lexeme == '_' || wildcard.lexeme == 'default');
    var type = pop() as TypeAnnotationImpl?;
    push(WildcardPatternImpl(keyword: keyword, type: type, name: wildcard));
  }

  @override
  Never internalProblem(Message message, int charOffset, Uri uri) {
    throw UnsupportedError(message.problemMessage);
  }

  /// Return `true` if [token] is either `null` or is the symbol or keyword
  /// [value].
  bool optionalOrNull(String value, Token? token) {
    return token == null || identical(value, token.stringValue);
  }

  /// Parses the comment references in a sequence of comment tokens where
  /// [dartdoc] is the first token in the sequence.
  @visibleForTesting
  CommentImpl parseDocComment(Token dartdoc) {
    // Build and return the comment.
    return DocCommentBuilder(
      parser,
      diagnosticReporter.diagnosticReporter,
      uri,
      _featureSet,
      _languageVersion,
      _lineInfo,
      dartdoc,
    ).build();
  }

  List<CollectionElementImpl> popCollectionElements(int count) {
    // TODO(scheglov): Not efficient.
    var elements = <CollectionElementImpl>[];
    for (int index = count - 1; index >= 0; --index) {
      var element = pop();
      elements.add(element as CollectionElementImpl);
    }
    return elements.reversed.toList();
  }

  List? popList(int n, List list) {
    if (n == 0) return null;
    return stack.popList(n, list, null);
  }

  List<T>? popTypedList<T extends Object>(int count) {
    if (count == 0) return null;
    assert(stack.length >= count);

    var tailList = List<T?>.filled(count, null, growable: true);
    stack.popList(count, tailList, null);
    return tailList.nonNulls.toList();
  }

  // TODO(scheglov): This is probably not optimal.
  List<T> popTypedList2<T>(int count) {
    var result = <T>[];
    for (var i = 0; i < count; i++) {
      var element = stack.pop(null) as T;
      result.add(element);
    }
    return result.reversed.toList();
  }

  void reportErrorIfNullableType(Token? questionMark) {
    if (questionMark != null) {
      assert(optional('?', questionMark));
      _reportFeatureNotEnabled(
        feature: ExperimentalFeatures.non_nullable,
        startToken: questionMark,
      );
    }
  }

  void reportErrorIfSuper(ExpressionImpl expression) {
    if (expression is SuperExpressionImpl) {
      // This error is also reported by the body builder.
      handleRecoverableError(
        messageMissingAssignableSelector,
        expression.beginToken,
        expression.endToken,
      );
    }
  }

  ConstructorDeclarationImpl _buildConstructorDeclaration({
    required Token beginToken,
    required Token endToken,
  }) {
    var bodyObject = pop();
    var initializers = (pop() as List<ConstructorInitializerImpl>?) ?? const [];
    var separator = pop() as Token?;
    var parameters = pop() as FormalParameterListImpl;
    var typeParameters = pop() as TypeParameterListImpl?;
    var name = pop();
    pop(); // return type
    var modifiers = pop() as _Modifiers?;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);

    ConstructorNameImpl? redirectedConstructor;
    FunctionBodyImpl body;
    if (bodyObject is FunctionBodyImpl) {
      body = bodyObject;
    } else if (bodyObject is _RedirectingFactoryBody) {
      separator = bodyObject.equalToken;
      redirectedConstructor = bodyObject.constructorName;
      body = EmptyFunctionBodyImpl(semicolon: endToken);
    } else {
      internalProblem(
        templateInternalProblemUnhandled.withArguments(
          "${bodyObject.runtimeType}",
          "bodyObject",
        ),
        beginToken.charOffset,
        uri,
      );
    }

    SimpleIdentifierImpl prefixOrName;
    Token? period;
    SimpleIdentifierImpl? nameOrNull;
    if (name is SimpleIdentifierImpl) {
      prefixOrName = name;
    } else if (name is PrefixedIdentifierImpl) {
      prefixOrName = name.prefix;
      period = name.period;
      nameOrNull = name.identifier;
    } else if (name is _OperatorName) {
      prefixOrName = name.name;
    } else {
      throw UnimplementedError(
        'name is an instance of ${name.runtimeType} in endClassConstructor',
      );
    }

    if (typeParameters != null) {
      // Outline builder also reports this error message.
      handleRecoverableError(
        messageConstructorWithTypeParameters,
        typeParameters.beginToken,
        typeParameters.endToken,
      );
    }
    if (modifiers?.constKeyword != null &&
        (body.length > 1 || body.beginToken.lexeme != ';')) {
      // This error is also reported in BodyBuilder.finishFunction
      Token bodyToken = body.beginToken;
      // Token bodyToken = body.beginToken ?? modifiers.constKeyword;
      handleRecoverableError(
        messageConstConstructorWithBody,
        bodyToken,
        bodyToken,
      );
    }

    if (modifiers?.externalKeyword != null) {
      for (var formalParameter in parameters.parameters) {
        var notDefault = formalParameter.notDefault;
        if (notDefault is FieldFormalParameterImpl) {
          diagnosticReporter.diagnosticReporter?.atToken(
            notDefault.thisKeyword,
            ParserErrorCode.EXTERNAL_CONSTRUCTOR_WITH_FIELD_INITIALIZERS,
          );
        }
      }
    }

    var constructor = ConstructorDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: modifiers?.augmentKeyword,
      externalKeyword: modifiers?.externalKeyword,
      constKeyword: modifiers?.finalConstOrVarKeyword,
      factoryKeyword: null,
      returnType: SimpleIdentifierImpl(token: prefixOrName.token),
      period: period,
      name: nameOrNull?.token,
      parameters: parameters,
      separator: separator,
      initializers: initializers,
      redirectedConstructor: redirectedConstructor,
      body: body,
    );
    return constructor;
  }

  ConstructorDeclarationImpl _buildFactoryConstructorDeclaration({
    required Token beginToken,
    required Token factoryKeyword,
    required Token endToken,
  }) {
    FunctionBodyImpl body;
    Token? separator;
    ConstructorNameImpl? redirectedConstructor;
    var bodyObject = pop();
    if (bodyObject is FunctionBodyImpl) {
      body = bodyObject;
    } else if (bodyObject is _RedirectingFactoryBody) {
      separator = bodyObject.equalToken;
      redirectedConstructor = bodyObject.constructorName;
      body = EmptyFunctionBodyImpl(semicolon: endToken);
    } else {
      internalProblem(
        templateInternalProblemUnhandled.withArguments(
          "${bodyObject.runtimeType}",
          "bodyObject",
        ),
        beginToken.charOffset,
        uri,
      );
    }

    var parameters = pop() as FormalParameterListImpl;
    var typeParameters = pop() as TypeParameterListImpl?;
    var constructorName = pop() as IdentifierImpl;
    var modifiers = pop() as _Modifiers?;
    var metadata = pop() as List<AnnotationImpl>?;
    var comment = _findComment(metadata, beginToken);

    if (typeParameters != null) {
      // TODO(danrubel): Update OutlineBuilder to report this error message.
      handleRecoverableError(
        messageConstructorWithTypeParameters,
        typeParameters.beginToken,
        typeParameters.endToken,
      );
    }

    // Decompose the preliminary ConstructorName into the type name and
    // the actual constructor name.
    SimpleIdentifierImpl returnType;
    Token? period;
    Token? nameToken;
    IdentifierImpl typeName = constructorName;
    if (typeName is SimpleIdentifierImpl) {
      returnType = typeName;
    } else if (typeName is PrefixedIdentifierImpl) {
      returnType = typeName.prefix;
      period = typeName.period;
      nameToken = typeName.identifier.token;
    } else {
      throw UnimplementedError();
    }

    var constructor = ConstructorDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: modifiers?.augmentKeyword,
      externalKeyword: modifiers?.externalKeyword,
      constKeyword: modifiers?.finalConstOrVarKeyword,
      factoryKeyword: factoryKeyword,
      returnType: SimpleIdentifierImpl(token: returnType.token),
      period: period,
      name: nameToken,
      parameters: parameters,
      separator: separator,
      initializers: [],
      redirectedConstructor: redirectedConstructor,
      body: body,
    );
    return constructor;
  }

  FormalParameterListImpl? _ensureSetterFormalParameter(
    SimpleIdentifierImpl setterName,
    FormalParameterListImpl? formalParameters,
  ) {
    formalParameters ??=
        throw StateError('Parser has recovery, this never happens.');

    var valueFormalParameter = formalParameters.parameters.firstOrNull;
    if (valueFormalParameter == null) {
      if (!formalParameters.leftParenthesis.isSynthetic) {
        diagnosticReporter.diagnosticReporter?.atToken(
          setterName.token,
          ParserErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER,
        );
      }
      var valueNameToken = parser.rewriter.insertSyntheticIdentifier(
        formalParameters.leftParenthesis,
      );
      return FormalParameterListImpl(
        leftParenthesis: formalParameters.leftParenthesis,
        parameters: [
          SimpleFormalParameterImpl(
            comment: null,
            metadata: null,
            covariantKeyword: null,
            requiredKeyword: null,
            keyword: null,
            type: null,
            name: valueNameToken,
          ),
        ],
        leftDelimiter: null,
        rightDelimiter: null,
        rightParenthesis: formalParameters.rightParenthesis,
      );
    }

    if (valueFormalParameter.isRequiredPositional &&
        formalParameters.parameters.length == 1) {
      return formalParameters;
    }

    diagnosticReporter.diagnosticReporter?.atToken(
      setterName.token,
      ParserErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER,
    );
    return FormalParameterListImpl(
      leftParenthesis: formalParameters.leftParenthesis,
      parameters: [valueFormalParameter.notDefault],
      leftDelimiter: null,
      rightDelimiter: null,
      rightParenthesis: formalParameters.rightParenthesis,
    );
  }

  CommentImpl? _findComment(
    List<AnnotationImpl>? metadata,
    Token tokenAfterMetadata,
  ) {
    // Find the dartdoc tokens.
    var dartdoc = parser.findDartDoc(tokenAfterMetadata);
    if (dartdoc == null) {
      if (metadata == null) {
        return null;
      }
      int index = metadata.length;
      while (true) {
        if (index == 0) {
          return null;
        }
        --index;
        dartdoc = parser.findDartDoc(metadata[index].beginToken);
        if (dartdoc != null) {
          break;
        }
      }
    }

    return parseDocComment(dartdoc);
  }

  void _handleInstanceCreation(Token? token) {
    var arguments = pop() as MethodInvocationImpl;
    ConstructorNameImpl constructorName;
    TypeArgumentListImpl? typeArguments;
    var object = pop();
    if (object is _ConstructorNameWithInvalidTypeArgs) {
      constructorName = object.name;
      typeArguments = object.invalidTypeArgs;
    } else {
      constructorName = object as ConstructorNameImpl;
    }
    push(
      InstanceCreationExpressionImpl(
        keyword: token,
        constructorName: constructorName,
        argumentList: arguments.argumentList,
        typeArguments: typeArguments,
      ),
    );
  }

  List<NamedTypeImpl> _popNamedTypeList({required DiagnosticCode code}) {
    var types = pop() as List<TypeAnnotationImpl>;
    var namedTypes = <NamedTypeImpl>[];
    for (var type in types) {
      if (type is NamedTypeImpl) {
        namedTypes.add(type);
      } else {
        diagnosticReporter.diagnosticReporter?.atNode(type, code);
      }
    }
    return namedTypes;
  }

  void _reportFeatureNotEnabled({
    required ExperimentalFeature feature,
    required Token startToken,
    Token? endToken,
  }) {
    var requiredVersion =
        feature.releaseVersion ?? ExperimentStatus.currentVersion;
    handleRecoverableError(
      templateExperimentNotEnabled.withArguments(
        feature.enableString,
        _versionAsString(requiredVersion),
      ),
      startToken,
      endToken ?? startToken,
    );
  }

  ArgumentListImpl _syntheticArgumentList(Token precedingToken) {
    var left = parser.rewriter.insertParens(precedingToken, false);
    var right = left.endGroup!;
    return ArgumentListImpl(
      leftParenthesis: left,
      arguments: [],
      rightParenthesis: right,
    );
  }

  FormalParameterListImpl _syntheticFormalParameterList(Token precedingToken) {
    var left = parser.rewriter.insertParens(precedingToken, false);
    var right = left.endGroup!;
    return FormalParameterListImpl(
      leftParenthesis: left,
      parameters: [],
      leftDelimiter: null,
      rightDelimiter: null,
      rightParenthesis: right,
    );
  }

  SimpleIdentifierImpl _tmpSimpleIdentifier() {
    return SimpleIdentifierImpl(
      token: StringToken(TokenType.STRING, '__tmp', -1),
    );
  }

  ParameterKind _toAnalyzerParameterKind(FormalParameterKind type) {
    switch (type) {
      case FormalParameterKind.requiredPositional:
        return ParameterKind.REQUIRED;
      case FormalParameterKind.requiredNamed:
        return ParameterKind.NAMED_REQUIRED;
      case FormalParameterKind.optionalNamed:
        return ParameterKind.NAMED;
      case FormalParameterKind.optionalPositional:
        return ParameterKind.POSITIONAL;
    }
  }

  static String _versionAsString(Version version) {
    return '${version.major}.${version.minor}.${version.patch}';
  }
}

class _ClassDeclarationBuilder extends _ClassLikeDeclarationBuilder {
  final Token? augmentKeyword;
  final Token? abstractKeyword;
  final Token? macroKeyword;
  final Token? sealedKeyword;
  final Token? baseKeyword;
  final Token? interfaceKeyword;
  final Token? finalKeyword;
  final Token? mixinKeyword;
  final Token classKeyword;
  final Token name;
  ExtendsClauseImpl? extendsClause;
  WithClauseImpl? withClause;
  ImplementsClauseImpl? implementsClause;
  final NativeClauseImpl? nativeClause;

  _ClassDeclarationBuilder({
    required super.comment,
    required super.metadata,
    required super.typeParameters,
    required super.leftBracket,
    required super.rightBracket,
    required this.augmentKeyword,
    required this.abstractKeyword,
    required this.macroKeyword,
    required this.sealedKeyword,
    required this.baseKeyword,
    required this.interfaceKeyword,
    required this.finalKeyword,
    required this.mixinKeyword,
    required this.classKeyword,
    required this.name,
    required this.extendsClause,
    required this.withClause,
    required this.implementsClause,
    required this.nativeClause,
  });

  ClassDeclarationImpl build() {
    return ClassDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      abstractKeyword: abstractKeyword,
      macroKeyword: macroKeyword,
      sealedKeyword: sealedKeyword,
      baseKeyword: baseKeyword,
      interfaceKeyword: interfaceKeyword,
      finalKeyword: finalKeyword,
      mixinKeyword: mixinKeyword,
      classKeyword: classKeyword,
      name: name,
      typeParameters: typeParameters,
      extendsClause: extendsClause,
      withClause: withClause,
      implementsClause: implementsClause,
      nativeClause: nativeClause,
      leftBracket: leftBracket,
      members: members,
      rightBracket: rightBracket,
    );
  }
}

class _ClassLikeDeclarationBuilder {
  final CommentImpl? comment;
  final List<AnnotationImpl>? metadata;
  final TypeParameterListImpl? typeParameters;

  Token leftBracket;
  final List<ClassMemberImpl> members = [];
  Token rightBracket;

  _ClassLikeDeclarationBuilder({
    required this.comment,
    required this.metadata,
    required this.typeParameters,
    required this.leftBracket,
    required this.rightBracket,
  });
}

class _ConstructorNameWithInvalidTypeArgs {
  final ConstructorNameImpl name;
  final TypeArgumentListImpl invalidTypeArgs;

  _ConstructorNameWithInvalidTypeArgs(this.name, this.invalidTypeArgs);
}

class _EnumDeclarationBuilder extends _ClassLikeDeclarationBuilder {
  final Token? augmentKeyword;
  final Token enumKeyword;
  final Token name;
  final WithClauseImpl? withClause;
  final ImplementsClauseImpl? implementsClause;
  final List<EnumConstantDeclarationImpl> constants = [];
  Token? semicolon;

  _EnumDeclarationBuilder({
    required super.comment,
    required super.metadata,
    required super.typeParameters,
    required super.leftBracket,
    required super.rightBracket,
    required this.augmentKeyword,
    required this.enumKeyword,
    required this.name,
    required this.withClause,
    required this.implementsClause,
    required this.semicolon,
  });

  EnumDeclarationImpl build() {
    return EnumDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      enumKeyword: enumKeyword,
      name: name,
      typeParameters: typeParameters,
      withClause: withClause,
      implementsClause: implementsClause,
      leftBracket: leftBracket,
      constants: constants,
      semicolon: semicolon,
      members: members,
      rightBracket: rightBracket,
    );
  }
}

class _ExtensionDeclarationBuilder extends _ClassLikeDeclarationBuilder {
  final Token? augmentKeyword;
  final Token extensionKeyword;
  final Token? name;

  _ExtensionDeclarationBuilder({
    required super.comment,
    required super.metadata,
    required super.typeParameters,
    required super.leftBracket,
    required super.rightBracket,
    required this.augmentKeyword,
    required this.extensionKeyword,
    required this.name,
  });

  ExtensionDeclarationImpl build({
    required Token? typeKeyword,
    required ExtensionOnClauseImpl? onClause,
  }) {
    return ExtensionDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      extensionKeyword: extensionKeyword,
      typeKeyword: typeKeyword,
      name: name,
      typeParameters: typeParameters,
      onClause: onClause,
      leftBracket: leftBracket,
      members: members,
      rightBracket: rightBracket,
    );
  }
}

class _ExtensionTypeDeclarationBuilder extends _ClassLikeDeclarationBuilder {
  final Token? augmentKeyword;
  final Token extensionKeyword;
  final Token name;

  _ExtensionTypeDeclarationBuilder({
    required super.comment,
    required super.metadata,
    required super.typeParameters,
    required super.leftBracket,
    required super.rightBracket,
    required this.augmentKeyword,
    required this.extensionKeyword,
    required this.name,
  });

  ExtensionTypeDeclarationImpl build({
    required Token typeKeyword,
    required Token? constKeyword,
    required RepresentationDeclarationImpl representation,
    required ImplementsClauseImpl? implementsClause,
  }) {
    return ExtensionTypeDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      extensionKeyword: extensionKeyword,
      typeKeyword: typeKeyword,
      constKeyword: constKeyword,
      name: name,
      typeParameters: typeParameters,
      representation: representation,
      implementsClause: implementsClause,
      leftBracket: leftBracket,
      members: members,
      rightBracket: rightBracket,
    );
  }
}

class _MixinDeclarationBuilder extends _ClassLikeDeclarationBuilder {
  final Token? augmentKeyword;
  final Token? baseKeyword;
  final Token mixinKeyword;
  final Token name;
  MixinOnClauseImpl? onClause;
  ImplementsClauseImpl? implementsClause;

  _MixinDeclarationBuilder({
    required super.comment,
    required super.metadata,
    required super.typeParameters,
    required super.leftBracket,
    required super.rightBracket,
    required this.augmentKeyword,
    required this.baseKeyword,
    required this.mixinKeyword,
    required this.name,
    required this.onClause,
    required this.implementsClause,
  });

  MixinDeclarationImpl build() {
    return MixinDeclarationImpl(
      comment: comment,
      metadata: metadata,
      augmentKeyword: augmentKeyword,
      baseKeyword: baseKeyword,
      mixinKeyword: mixinKeyword,
      name: name,
      typeParameters: typeParameters,
      onClause: onClause,
      implementsClause: implementsClause,
      leftBracket: leftBracket,
      members: members,
      rightBracket: rightBracket,
    );
  }
}

/// Data structure placed on the stack to represent a non-empty sequence
/// of modifiers.
class _Modifiers {
  Token? abstractKeyword;
  Token? augmentKeyword;
  Token? externalKeyword;
  Token? finalConstOrVarKeyword;
  Token? staticKeyword;
  Token? covariantKeyword;
  Token? requiredToken;
  Token? lateToken;

  /// Return the token that is lexically first.
  Token? get beginToken {
    Token? firstToken;
    for (Token? token in [
      abstractKeyword,
      externalKeyword,
      finalConstOrVarKeyword,
      staticKeyword,
      covariantKeyword,
      requiredToken,
      lateToken,
    ]) {
      if (firstToken == null) {
        firstToken = token;
      } else if (token != null) {
        if (token.offset < firstToken.offset) {
          firstToken = token;
        }
      }
    }
    return firstToken;
  }

  /// Return the `const` keyword or `null`.
  Token? get constKeyword {
    return identical('const', finalConstOrVarKeyword?.lexeme)
        ? finalConstOrVarKeyword
        : null;
  }
}

/// Temporary representation of the fields of an extractor used internally by
/// the [AstBuilder].
class _ObjectPatternFields {
  final Token leftParenthesis;
  final Token rightParenthesis;
  final List<PatternFieldImpl> fields;

  _ObjectPatternFields(
    this.leftParenthesis,
    this.rightParenthesis,
    this.fields,
  );
}

/// Data structure placed on the stack to represent the keyword "operator"
/// followed by a token.
class _OperatorName {
  final Token operatorKeyword;
  final SimpleIdentifierImpl name;

  _OperatorName(this.operatorKeyword, this.name);
}

/// Data structure placed on the stack as a container for optional parameters.
class _OptionalFormalParameters {
  final List<FormalParameterImpl>? parameters;
  final Token leftDelimiter;
  final Token rightDelimiter;

  _OptionalFormalParameters(
    this.parameters,
    this.leftDelimiter,
    this.rightDelimiter,
  );
}

/// Data structure placed on the stack to represent the default parameter
/// value with the separator token.
class _ParameterDefaultValue {
  final Token separator;
  final ExpressionImpl value;

  _ParameterDefaultValue(this.separator, this.value);
}

/// Data structure placed on the stack to represent the parenthesized condition
/// part of an if-statement, if-control-flow, switch-statement, while-statement,
/// or do-while-statement.
class _ParenthesizedCondition {
  final Token leftParenthesis;
  final ExpressionImpl expression;
  final CaseClauseImpl? caseClause;

  _ParenthesizedCondition(
    this.leftParenthesis,
    this.expression,
    this.caseClause,
  );

  Token get rightParenthesis => leftParenthesis.endGroup!;
}

/// Data structure placed on stack to represent the redirected constructor.
class _RedirectingFactoryBody {
  final Token? asyncKeyword;
  final Token? starKeyword;
  final Token equalToken;
  final ConstructorNameImpl constructorName;

  _RedirectingFactoryBody(
    this.asyncKeyword,
    this.starKeyword,
    this.equalToken,
    this.constructorName,
  );
}
