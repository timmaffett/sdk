// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/lint/registry.dart' // ignore: implementation_imports
    show Registry;

import 'rules/always_declare_return_types.dart';
import 'rules/always_put_control_body_on_new_line.dart';
import 'rules/always_put_required_named_parameters_first.dart';
import 'rules/always_require_non_null_named_parameters.dart';
import 'rules/always_specify_types.dart';
import 'rules/always_use_package_imports.dart';
import 'rules/analyzer_public_api.dart';
import 'rules/annotate_overrides.dart';
import 'rules/annotate_redeclares.dart';
import 'rules/avoid_annotating_with_dynamic.dart';
import 'rules/avoid_as.dart';
import 'rules/avoid_bool_literals_in_conditional_expressions.dart';
import 'rules/avoid_catches_without_on_clauses.dart';
import 'rules/avoid_catching_errors.dart';
import 'rules/avoid_classes_with_only_static_members.dart';
import 'rules/avoid_double_and_int_checks.dart';
import 'rules/avoid_dynamic_calls.dart';
import 'rules/avoid_empty_else.dart';
import 'rules/avoid_equals_and_hash_code_on_mutable_classes.dart';
import 'rules/avoid_escaping_inner_quotes.dart';
import 'rules/avoid_field_initializers_in_const_classes.dart';
import 'rules/avoid_final_parameters.dart';
import 'rules/avoid_function_literals_in_foreach_calls.dart';
import 'rules/avoid_futureor_void.dart';
import 'rules/avoid_implementing_value_types.dart';
import 'rules/avoid_init_to_null.dart';
import 'rules/avoid_js_rounded_ints.dart';
import 'rules/avoid_multiple_declarations_per_line.dart';
import 'rules/avoid_null_checks_in_equality_operators.dart';
import 'rules/avoid_positional_boolean_parameters.dart';
import 'rules/avoid_print.dart';
import 'rules/avoid_private_typedef_functions.dart';
import 'rules/avoid_redundant_argument_values.dart';
import 'rules/avoid_relative_lib_imports.dart';
import 'rules/avoid_renaming_method_parameters.dart';
import 'rules/avoid_return_types_on_setters.dart';
import 'rules/avoid_returning_null.dart';
import 'rules/avoid_returning_null_for_future.dart';
import 'rules/avoid_returning_null_for_void.dart';
import 'rules/avoid_returning_this.dart';
import 'rules/avoid_setters_without_getters.dart';
import 'rules/avoid_shadowing_type_parameters.dart';
import 'rules/avoid_single_cascade_in_expression_statements.dart';
import 'rules/avoid_slow_async_io.dart';
import 'rules/avoid_type_to_string.dart';
import 'rules/avoid_types_as_parameter_names.dart';
import 'rules/avoid_types_on_closure_parameters.dart';
import 'rules/avoid_unnecessary_containers.dart';
import 'rules/avoid_unstable_final_fields.dart';
import 'rules/avoid_unused_constructor_parameters.dart';
import 'rules/avoid_void_async.dart';
import 'rules/avoid_web_libraries_in_flutter.dart';
import 'rules/await_only_futures.dart';
import 'rules/camel_case_extensions.dart';
import 'rules/camel_case_types.dart';
import 'rules/cancel_subscriptions.dart';
import 'rules/cascade_invocations.dart';
import 'rules/cast_nullable_to_non_nullable.dart';
import 'rules/close_sinks.dart';
import 'rules/collection_methods_unrelated_type.dart';
import 'rules/combinators_ordering.dart';
import 'rules/comment_references.dart';
import 'rules/conditional_uri_does_not_exist.dart';
import 'rules/constant_identifier_names.dart';
import 'rules/control_flow_in_finally.dart';
import 'rules/curly_braces_in_flow_control_structures.dart';
import 'rules/dangling_library_doc_comments.dart';
import 'rules/deprecated_consistency.dart';
import 'rules/deprecated_member_use_from_same_package.dart';
import 'rules/diagnostic_describe_all_properties.dart';
import 'rules/directives_ordering.dart';
import 'rules/discarded_futures.dart';
import 'rules/do_not_use_environment.dart';
import 'rules/document_ignores.dart';
import 'rules/empty_catches.dart';
import 'rules/empty_constructor_bodies.dart';
import 'rules/empty_statements.dart';
import 'rules/enable_null_safety.dart';
import 'rules/eol_at_end_of_file.dart';
import 'rules/erase_dart_type_extension_types.dart';
import 'rules/exhaustive_cases.dart';
import 'rules/file_names.dart';
import 'rules/flutter_style_todos.dart';
import 'rules/hash_and_equals.dart';
import 'rules/implementation_imports.dart';
import 'rules/implicit_call_tearoffs.dart';
import 'rules/implicit_reopen.dart';
import 'rules/invalid_case_patterns.dart';
import 'rules/invalid_runtime_check_with_js_interop_types.dart';
import 'rules/invariant_booleans.dart';
import 'rules/iterable_contains_unrelated_type.dart';
import 'rules/join_return_with_assignment.dart';
import 'rules/leading_newlines_in_multiline_strings.dart';
import 'rules/library_annotations.dart';
import 'rules/library_names.dart';
import 'rules/library_prefixes.dart';
import 'rules/library_private_types_in_public_api.dart';
import 'rules/lines_longer_than_80_chars.dart';
import 'rules/list_remove_unrelated_type.dart';
import 'rules/literal_only_boolean_expressions.dart';
import 'rules/matching_super_parameters.dart';
import 'rules/missing_code_block_language_in_doc_comment.dart';
import 'rules/missing_whitespace_between_adjacent_strings.dart';
import 'rules/no_adjacent_strings_in_list.dart';
import 'rules/no_default_cases.dart';
import 'rules/no_duplicate_case_values.dart';
import 'rules/no_leading_underscores_for_library_prefixes.dart';
import 'rules/no_leading_underscores_for_local_identifiers.dart';
import 'rules/no_literal_bool_comparisons.dart';
import 'rules/no_logic_in_create_state.dart';
import 'rules/no_runtimeType_toString.dart';
import 'rules/no_self_assignments.dart';
import 'rules/no_wildcard_variable_uses.dart';
import 'rules/non_constant_identifier_names.dart';
import 'rules/noop_primitive_operations.dart';
import 'rules/null_check_on_nullable_type_parameter.dart';
import 'rules/null_closures.dart';
import 'rules/omit_local_variable_types.dart';
import 'rules/omit_obvious_local_variable_types.dart';
import 'rules/omit_obvious_property_types.dart';
import 'rules/one_member_abstracts.dart';
import 'rules/only_throw_errors.dart';
import 'rules/overridden_fields.dart';
import 'rules/package_api_docs.dart';
import 'rules/package_prefixed_library_names.dart';
import 'rules/parameter_assignments.dart';
import 'rules/prefer_adjacent_string_concatenation.dart';
import 'rules/prefer_asserts_in_initializer_lists.dart';
import 'rules/prefer_asserts_with_message.dart';
import 'rules/prefer_bool_in_asserts.dart';
import 'rules/prefer_collection_literals.dart';
import 'rules/prefer_conditional_assignment.dart';
import 'rules/prefer_const_constructors.dart';
import 'rules/prefer_const_constructors_in_immutables.dart';
import 'rules/prefer_const_declarations.dart';
import 'rules/prefer_const_literals_to_create_immutables.dart';
import 'rules/prefer_constructors_over_static_methods.dart';
import 'rules/prefer_contains.dart';
import 'rules/prefer_double_quotes.dart';
import 'rules/prefer_equal_for_default_values.dart';
import 'rules/prefer_expression_function_bodies.dart';
import 'rules/prefer_final_fields.dart';
import 'rules/prefer_final_in_for_each.dart';
import 'rules/prefer_final_locals.dart';
import 'rules/prefer_final_parameters.dart';
import 'rules/prefer_for_elements_to_map_fromIterable.dart';
import 'rules/prefer_foreach.dart';
import 'rules/prefer_function_declarations_over_variables.dart';
import 'rules/prefer_generic_function_type_aliases.dart';
import 'rules/prefer_if_elements_to_conditional_expressions.dart';
import 'rules/prefer_if_null_operators.dart';
import 'rules/prefer_initializing_formals.dart';
import 'rules/prefer_inlined_adds.dart';
import 'rules/prefer_int_literals.dart';
import 'rules/prefer_interpolation_to_compose_strings.dart';
import 'rules/prefer_is_empty.dart';
import 'rules/prefer_is_not_empty.dart';
import 'rules/prefer_is_not_operator.dart';
import 'rules/prefer_iterable_whereType.dart';
import 'rules/prefer_mixin.dart';
import 'rules/prefer_null_aware_method_calls.dart';
import 'rules/prefer_null_aware_operators.dart';
import 'rules/prefer_relative_imports.dart';
import 'rules/prefer_single_quotes.dart';
import 'rules/prefer_spread_collections.dart';
import 'rules/prefer_typing_uninitialized_variables.dart';
import 'rules/prefer_void_to_null.dart';
import 'rules/provide_deprecation_message.dart';
import 'rules/pub/depend_on_referenced_packages.dart';
import 'rules/pub/package_names.dart';
import 'rules/pub/secure_pubspec_urls.dart';
import 'rules/pub/sort_pub_dependencies.dart';
import 'rules/public_member_api_docs.dart';
import 'rules/recursive_getters.dart';
import 'rules/require_trailing_commas.dart';
import 'rules/sized_box_for_whitespace.dart';
import 'rules/sized_box_shrink_expand.dart';
import 'rules/slash_for_doc_comments.dart';
import 'rules/sort_child_properties_last.dart';
import 'rules/sort_constructors_first.dart';
import 'rules/sort_unnamed_constructors_first.dart';
import 'rules/specify_nonobvious_local_variable_types.dart';
import 'rules/specify_nonobvious_property_types.dart';
import 'rules/strict_top_level_inference.dart';
import 'rules/super_goes_last.dart';
import 'rules/switch_on_type.dart';
import 'rules/test_types_in_equals.dart';
import 'rules/throw_in_finally.dart';
import 'rules/tighten_type_of_initializing_formals.dart';
import 'rules/type_annotate_public_apis.dart';
import 'rules/type_init_formals.dart';
import 'rules/type_literal_in_constant_pattern.dart';
import 'rules/unawaited_futures.dart';
import 'rules/unintended_html_in_doc_comment.dart';
import 'rules/unnecessary_async.dart';
import 'rules/unnecessary_await_in_return.dart';
import 'rules/unnecessary_brace_in_string_interps.dart';
import 'rules/unnecessary_breaks.dart';
import 'rules/unnecessary_const.dart';
import 'rules/unnecessary_constructor_name.dart';
import 'rules/unnecessary_final.dart';
import 'rules/unnecessary_getters_setters.dart';
import 'rules/unnecessary_ignore.dart';
import 'rules/unnecessary_lambdas.dart';
import 'rules/unnecessary_late.dart';
import 'rules/unnecessary_library_directive.dart';
import 'rules/unnecessary_library_name.dart';
import 'rules/unnecessary_new.dart';
import 'rules/unnecessary_null_aware_assignments.dart';
import 'rules/unnecessary_null_aware_operator_on_extension_on_nullable.dart';
import 'rules/unnecessary_null_checks.dart';
import 'rules/unnecessary_null_in_if_null_operators.dart';
import 'rules/unnecessary_nullable_for_final_variable_declarations.dart';
import 'rules/unnecessary_overrides.dart';
import 'rules/unnecessary_parenthesis.dart';
import 'rules/unnecessary_raw_strings.dart';
import 'rules/unnecessary_statements.dart';
import 'rules/unnecessary_string_escapes.dart';
import 'rules/unnecessary_string_interpolations.dart';
import 'rules/unnecessary_this.dart';
import 'rules/unnecessary_to_list_in_spreads.dart';
import 'rules/unnecessary_unawaited.dart';
import 'rules/unnecessary_underscores.dart';
import 'rules/unreachable_from_main.dart';
import 'rules/unrelated_type_equality_checks.dart';
import 'rules/unsafe_html.dart';
import 'rules/unsafe_variance.dart';
import 'rules/use_build_context_synchronously.dart';
import 'rules/use_colored_box.dart';
import 'rules/use_decorated_box.dart';
import 'rules/use_enums.dart';
import 'rules/use_full_hex_values_for_flutter_colors.dart';
import 'rules/use_function_type_syntax_for_parameters.dart';
import 'rules/use_if_null_to_convert_nulls_to_bools.dart';
import 'rules/use_is_even_rather_than_modulo.dart';
import 'rules/use_key_in_widget_constructors.dart';
import 'rules/use_late_for_private_fields_and_variables.dart';
import 'rules/use_named_constants.dart';
import 'rules/use_null_aware_elements.dart';
import 'rules/use_raw_strings.dart';
import 'rules/use_rethrow_when_possible.dart';
import 'rules/use_setters_to_change_properties.dart';
import 'rules/use_string_buffers.dart';
import 'rules/use_string_in_part_of_directives.dart';
import 'rules/use_super_parameters.dart';
import 'rules/use_test_throws_matchers.dart';
import 'rules/use_to_and_as_if_applicable.dart';
import 'rules/use_truncating_division.dart';
import 'rules/valid_regexps.dart';
import 'rules/void_checks.dart';

void registerLintRules() {
  Registry.ruleRegistry
    ..registerLintRule(AlwaysDeclareReturnTypes())
    ..registerLintRule(AlwaysPutControlBodyOnNewLine())
    ..registerLintRule(AlwaysPutRequiredNamedParametersFirst())
    ..registerLintRule(AlwaysRequireNonNullNamedParameters())
    ..registerLintRule(AlwaysSpecifyTypes())
    ..registerLintRule(AlwaysUsePackageImports())
    ..registerLintRule(AnalyzerPublicApi())
    ..registerLintRule(AnnotateOverrides())
    ..registerLintRule(AnnotateRedeclares())
    ..registerLintRule(AvoidAnnotatingWithDynamic())
    ..registerLintRule(AvoidAs())
    ..registerLintRule(AvoidBoolLiteralsInConditionalExpressions())
    ..registerLintRule(AvoidCatchesWithoutOnClauses())
    ..registerLintRule(AvoidCatchingErrors())
    ..registerLintRule(AvoidClassesWithOnlyStaticMembers())
    ..registerLintRule(AvoidDoubleAndIntChecks())
    ..registerLintRule(AvoidDynamicCalls())
    ..registerLintRule(AvoidEmptyElse())
    ..registerLintRule(AvoidEqualsAndHashCodeOnMutableClasses())
    ..registerLintRule(AvoidEscapingInnerQuotes())
    ..registerLintRule(AvoidFieldInitializersInConstClasses())
    ..registerLintRule(AvoidFinalParameters())
    ..registerLintRule(AvoidFunctionLiteralsInForeachCalls())
    ..registerLintRule(AvoidFutureOrVoid())
    ..registerLintRule(AvoidImplementingValueTypes())
    ..registerLintRule(AvoidInitToNull())
    ..registerLintRule(AvoidJsRoundedInts())
    ..registerLintRule(AvoidMultipleDeclarationsPerLine())
    ..registerLintRule(AvoidNullChecksInEqualityOperators())
    ..registerLintRule(AvoidPositionalBooleanParameters())
    ..registerLintRule(AvoidPrint())
    ..registerLintRule(AvoidPrivateTypedefFunctions())
    ..registerLintRule(AvoidRedundantArgumentValues())
    ..registerLintRule(AvoidRelativeLibImports())
    ..registerLintRule(AvoidRenamingMethodParameters())
    ..registerLintRule(AvoidReturnTypesOnSetters())
    ..registerLintRule(AvoidReturningNull())
    ..registerLintRule(AvoidReturningNullForFuture())
    ..registerLintRule(AvoidReturningNullForVoid())
    ..registerLintRule(AvoidReturningThis())
    ..registerLintRule(AvoidSettersWithoutGetters())
    ..registerLintRule(AvoidShadowingTypeParameters())
    ..registerLintRule(AvoidSingleCascadeInExpressionStatements())
    ..registerLintRule(AvoidSlowAsyncIo())
    ..registerLintRule(AvoidTypeToString())
    ..registerLintRule(AvoidTypesAsParameterNames())
    ..registerLintRule(AvoidTypesOnClosureParameters())
    ..registerLintRule(AvoidUnnecessaryContainers())
    ..registerLintRule(AvoidUnstableFinalFields())
    ..registerLintRule(AvoidUnusedConstructorParameters())
    ..registerLintRule(AvoidVoidAsync())
    ..registerLintRule(AvoidWebLibrariesInFlutter())
    ..registerLintRule(AwaitOnlyFutures())
    ..registerLintRule(CamelCaseExtensions())
    ..registerLintRule(CamelCaseTypes())
    ..registerLintRule(CancelSubscriptions())
    ..registerLintRule(CascadeInvocations())
    ..registerLintRule(CastNullableToNonNullable())
    ..registerLintRule(CloseSinks())
    ..registerLintRule(CollectionMethodsUnrelatedType())
    ..registerLintRule(CombinatorsOrdering())
    ..registerLintRule(CommentReferences())
    ..registerLintRule(ConditionalUriDoesNotExist())
    ..registerLintRule(ConstantIdentifierNames())
    ..registerLintRule(ControlFlowInFinally())
    ..registerLintRule(CurlyBracesInFlowControlStructures())
    ..registerLintRule(DanglingLibraryDocComments())
    ..registerLintRule(DependOnReferencedPackages())
    ..registerLintRule(DeprecatedConsistency())
    ..registerLintRule(DeprecatedMemberUseFromSamePackage())
    ..registerLintRule(DiagnosticDescribeAllProperties())
    ..registerLintRule(DirectivesOrdering())
    ..registerLintRule(DiscardedFutures())
    ..registerLintRule(DocumentIgnores())
    ..registerLintRule(DoNotUseEnvironment())
    ..registerLintRule(EmptyCatches())
    ..registerLintRule(EmptyConstructorBodies())
    ..registerLintRule(EmptyStatements())
    ..registerLintRule(EnableNullSafety())
    ..registerLintRule(EolAtEndOfFile())
    ..registerLintRule(EraseDartTypeExtensionTypes())
    ..registerLintRule(ExhaustiveCases())
    ..registerLintRule(FileNames())
    ..registerLintRule(FlutterStyleTodos())
    ..registerLintRule(HashAndEquals())
    ..registerLintRule(ImplementationImports())
    ..registerLintRule(ImplicitCallTearoffs())
    ..registerLintRule(ImplicitReopen())
    ..registerLintRule(InvalidCasePatterns())
    ..registerLintRule(InvariantBooleans())
    ..registerLintRule(IterableContainsUnrelatedType())
    ..registerLintRule(InvalidRuntimeCheckWithJSInteropTypes())
    ..registerLintRule(JoinReturnWithAssignment())
    ..registerLintRule(LeadingNewlinesInMultilineStrings())
    ..registerLintRule(LibraryAnnotations())
    ..registerLintRule(LibraryNames())
    ..registerLintRule(LibraryPrefixes())
    ..registerLintRule(LibraryPrivateTypesInPublicApi())
    ..registerLintRule(LinesLongerThan80Chars())
    ..registerLintRule(ListRemoveUnrelatedType())
    ..registerLintRule(LiteralOnlyBooleanExpressions())
    ..registerLintRule(MatchingSuperParameters())
    ..registerLintRule(MissingCodeBlockLanguageInDocComment())
    ..registerLintRule(MissingWhitespaceBetweenAdjacentStrings())
    ..registerLintRule(NoAdjacentStringsInList())
    ..registerLintRule(NoDefaultCases())
    ..registerLintRule(NoDuplicateCaseValues())
    ..registerLintRule(NoLeadingUnderscoresForLibraryPrefixes())
    ..registerLintRule(NoLeadingUnderscoresForLocalIdentifiers())
    ..registerLintRule(NoLiteralBoolComparisons())
    ..registerLintRule(NoLogicInCreateState())
    ..registerLintRule(NoRuntimeTypeToString())
    ..registerLintRule(NoSelfAssignments())
    ..registerLintRule(NoWildcardVariableUses())
    ..registerLintRule(NonConstantIdentifierNames())
    ..registerLintRule(NoopPrimitiveOperations())
    ..registerLintRule(NullCheckOnNullableTypeParameter())
    ..registerLintRule(NullClosures())
    ..registerLintRule(OmitLocalVariableTypes())
    ..registerLintRule(OmitObviousLocalVariableTypes())
    ..registerLintRule(OmitObviousPropertyTypes())
    ..registerLintRule(OneMemberAbstracts())
    ..registerLintRule(OnlyThrowErrors())
    ..registerLintRule(OverriddenFields())
    ..registerLintRule(PackageApiDocs())
    ..registerLintRule(PackageNames())
    ..registerLintRule(PackagePrefixedLibraryNames())
    ..registerLintRule(ParameterAssignments())
    ..registerLintRule(PreferAdjacentStringConcatenation())
    ..registerLintRule(PreferAssertsInInitializerLists())
    ..registerLintRule(PreferAssertsWithMessage())
    ..registerLintRule(PreferBoolInAsserts())
    ..registerLintRule(PreferCollectionLiterals())
    ..registerLintRule(PreferConditionalAssignment())
    ..registerLintRule(PreferConstConstructors())
    ..registerLintRule(PreferConstConstructorsInImmutables())
    ..registerLintRule(PreferConstDeclarations())
    ..registerLintRule(PreferConstLiteralsToCreateImmutables())
    ..registerLintRule(PreferConstructorsOverStaticMethods())
    ..registerLintRule(PreferContains())
    ..registerLintRule(PreferDoubleQuotes())
    ..registerLintRule(PreferEqualForDefaultValues())
    ..registerLintRule(PreferExpressionFunctionBodies())
    ..registerLintRule(PreferFinalFields())
    ..registerLintRule(PreferFinalInForEach())
    ..registerLintRule(PreferFinalLocals())
    ..registerLintRule(PreferFinalParameters())
    ..registerLintRule(PreferForElementsToMapFromIterable())
    ..registerLintRule(PreferForeach())
    ..registerLintRule(PreferFunctionDeclarationsOverVariables())
    ..registerLintRule(PreferGenericFunctionTypeAliases())
    ..registerLintRule(PreferIfElementsToConditionalExpressions())
    ..registerLintRule(PreferIfNullOperators())
    ..registerLintRule(PreferInitializingFormals())
    ..registerLintRule(PreferInlinedAdds())
    ..registerLintRule(PreferIntLiterals())
    ..registerLintRule(PreferInterpolationToComposeStrings())
    ..registerLintRule(PreferIsEmpty())
    ..registerLintRule(PreferIsNotEmpty())
    ..registerLintRule(PreferIsNotOperator())
    ..registerLintRule(PreferIterableWhereType())
    ..registerLintRule(PreferMixin())
    ..registerLintRule(PreferNullAwareMethodCalls())
    ..registerLintRule(PreferNullAwareOperators())
    ..registerLintRule(PreferRelativeImports())
    ..registerLintRule(PreferSingleQuotes())
    ..registerLintRule(PreferSpreadCollections())
    ..registerLintRule(PreferTypingUninitializedVariables())
    ..registerLintRule(PreferVoidToNull())
    ..registerLintRule(ProvideDeprecationMessage())
    ..registerLintRule(PublicMemberApiDocs())
    ..registerLintRule(RecursiveGetters())
    ..registerLintRule(RequireTrailingCommas())
    ..registerLintRule(SecurePubspecUrls())
    ..registerLintRule(SizedBoxForWhitespace())
    ..registerLintRule(SizedBoxShrinkExpand())
    ..registerLintRule(SlashForDocComments())
    ..registerLintRule(SortChildPropertiesLast())
    ..registerLintRule(SortConstructorsFirst())
    ..registerLintRule(SortPubDependencies())
    ..registerLintRule(SortUnnamedConstructorsFirst())
    ..registerLintRule(SuperGoesLast())
    ..registerLintRule(SpecifyNonObviousLocalVariableTypes())
    ..registerLintRule(SpecifyNonObviousPropertyTypes())
    ..registerLintRule(StrictTopLevelInference())
    ..registerLintRule(SwitchOnType())
    ..registerLintRule(TestTypesInEquals())
    ..registerLintRule(ThrowInFinally())
    ..registerLintRule(TightenTypeOfInitializingFormals())
    ..registerLintRule(TypeAnnotatePublicApis())
    ..registerLintRule(TypeInitFormals())
    ..registerLintRule(TypeLiteralInConstantPattern())
    ..registerLintRule(UnawaitedFutures())
    ..registerLintRule(UnintendedHtmlInDocComment())
    ..registerLintRule(UnnecessaryAsync())
    ..registerLintRule(UnnecessaryAwaitInReturn())
    ..registerLintRule(UnnecessaryBraceInStringInterps())
    ..registerLintRule(UnnecessaryBreaks())
    ..registerLintRule(UnnecessaryConst())
    ..registerLintRule(UnnecessaryConstructorName())
    ..registerLintRule(UnnecessaryFinal())
    ..registerLintRule(UnnecessaryGettersSetters())
    ..registerLintRule(UnnecessaryIgnore())
    ..registerLintRule(UnnecessaryLambdas())
    ..registerLintRule(UnnecessaryLate())
    ..registerLintRule(UnnecessaryLibraryDirective())
    ..registerLintRule(UnnecessaryLibraryName())
    ..registerLintRule(UnnecessaryNew())
    ..registerLintRule(UnnecessaryNullAwareAssignments())
    ..registerLintRule(UnnecessaryNullAwareOperatorOnExtensionOnNullable())
    ..registerLintRule(UnnecessaryNullChecks())
    ..registerLintRule(UnnecessaryNullInIfNullOperators())
    ..registerLintRule(UnnecessaryNullableForFinalVariableDeclarations())
    ..registerLintRule(UnnecessaryOverrides())
    ..registerLintRule(UnnecessaryParenthesis())
    ..registerLintRule(UnnecessaryRawStrings())
    ..registerLintRule(UnnecessaryStatements())
    ..registerLintRule(UnnecessaryStringEscapes())
    ..registerLintRule(UnnecessaryStringInterpolations())
    ..registerLintRule(UnnecessaryThis())
    ..registerLintRule(UnnecessaryToListInSpreads())
    ..registerLintRule(UnnecessaryUnawaited())
    ..registerLintRule(UnnecessaryUnderscores())
    ..registerLintRule(UnreachableFromMain())
    ..registerLintRule(UnrelatedTypeEqualityChecks())
    ..registerLintRule(UnsafeHtml())
    ..registerLintRule(UnsafeVariance())
    ..registerLintRule(UseBuildContextSynchronously())
    ..registerLintRule(UseColoredBox())
    ..registerLintRule(UseDecoratedBox())
    ..registerLintRule(UseEnums())
    ..registerLintRule(UseFullHexValuesForFlutterColors())
    ..registerLintRule(UseFunctionTypeSyntaxForParameters())
    ..registerLintRule(UseIfNullToConvertNullsToBools())
    ..registerLintRule(UseIsEvenRatherThanModulo())
    ..registerLintRule(UseKeyInWidgetConstructors())
    ..registerLintRule(UseLateForPrivateFieldsAndVariables())
    ..registerLintRule(UseNamedConstants())
    ..registerLintRule(UseNullAwareElements())
    ..registerLintRule(UseRawStrings())
    ..registerLintRule(UseRethrowWhenPossible())
    ..registerLintRule(UseSettersToChangeProperties())
    ..registerLintRule(UseStringBuffers())
    ..registerLintRule(UseStringInPartOfDirectives())
    ..registerLintRule(UseSuperParameters())
    ..registerLintRule(UseTestThrowsMatchers())
    ..registerLintRule(UseToAndAsIfApplicable())
    ..registerLintRule(UseTruncatingDivision())
    ..registerLintRule(ValidRegexps())
    ..registerLintRule(VoidChecks());
}
