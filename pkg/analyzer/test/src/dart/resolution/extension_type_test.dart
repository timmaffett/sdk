// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ExtensionTypeResolutionTest);
  });
}

@reflectiveTest
class ExtensionTypeResolutionTest extends PubPackageResolutionTest {
  test_constructor_named() async {
    await assertNoErrorsInCode(r'''
extension type A.named(int it) {}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  representation: RepresentationDeclaration
    constructorName: RepresentationConstructorName
      period: .
      name: named
    leftParenthesis: (
    fieldType: NamedType
      name: int
      element2: dart:core::@class::int
      type: int
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::named
  leftBracket: {
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_constructor_secondary_fieldFormalParameter() async {
    await assertNoErrorsInCode(r'''
extension type A(int it) {
  A.named(this.it);
}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: int
      element2: dart:core::@class::int
      type: int
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::new
  leftBracket: {
  members
    ConstructorDeclaration
      returnType: SimpleIdentifier
        token: A
        element: <testLibrary>::@extensionType::A
        staticType: null
      period: .
      name: named
      parameters: FormalParameterList
        leftParenthesis: (
        parameter: FieldFormalParameter
          thisKeyword: this
          period: .
          name: it
          declaredElement: <testLibraryFragment>::@extensionType::A::@constructor::named::@formalParameter::it
            type: int
        rightParenthesis: )
      body: EmptyFunctionBody
        semicolon: ;
      declaredElement: <testLibraryFragment>::@extensionType::A::@constructor::named
        type: A Function(int)
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_constructor_secondary_fieldInitializer() async {
    await assertNoErrorsInCode(r'''
extension type A(num it) {
  const A.named(int a) : it = a;
}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: num
      element2: dart:core::@class::num
      type: num
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::new
  leftBracket: {
  members
    ConstructorDeclaration
      constKeyword: const
      returnType: SimpleIdentifier
        token: A
        element: <testLibrary>::@extensionType::A
        staticType: null
      period: .
      name: named
      parameters: FormalParameterList
        leftParenthesis: (
        parameter: SimpleFormalParameter
          type: NamedType
            name: int
            element2: dart:core::@class::int
            type: int
          name: a
          declaredElement: <testLibraryFragment>::@extensionType::A::@constructor::named::@formalParameter::a
            type: int
        rightParenthesis: )
      separator: :
      initializers
        ConstructorFieldInitializer
          fieldName: SimpleIdentifier
            token: it
            element: <testLibrary>::@extensionType::A::@field::it
            staticType: null
          equals: =
          expression: SimpleIdentifier
            token: a
            element: <testLibraryFragment>::@extensionType::A::@constructor::named::@parameter::a#element
            staticType: int
      body: EmptyFunctionBody
        semicolon: ;
      declaredElement: <testLibraryFragment>::@extensionType::A::@constructor::named
        type: A Function(int)
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_constructor_unnamed() async {
    await assertNoErrorsInCode(r'''
extension type A(int it) {}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: int
      element2: dart:core::@class::int
      type: int
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::new
  leftBracket: {
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_implementsClause() async {
    await assertNoErrorsInCode(r'''
extension type A(int it) implements num {}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: int
      element2: dart:core::@class::int
      type: int
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::new
  implementsClause: ImplementsClause
    implementsKeyword: implements
    interfaces
      NamedType
        name: num
        element2: dart:core::@class::num
        type: num
  leftBracket: {
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_method_generic() async {
    await assertNoErrorsInCode(r'''
extension type A<T>(int it) {
  void foo<U>(T t, U u) {
    T;
    U;
  }
}
''');

    var node = findNode.singleMethodDeclaration;
    assertResolvedNodeText(node, r'''
MethodDeclaration
  returnType: NamedType
    name: void
    element2: <null>
    type: void
  name: foo
  typeParameters: TypeParameterList
    leftBracket: <
    typeParameters
      TypeParameter
        name: U
        declaredElement: U@41
          defaultType: dynamic
    rightBracket: >
  parameters: FormalParameterList
    leftParenthesis: (
    parameter: SimpleFormalParameter
      type: NamedType
        name: T
        element2: T@17
        type: T
      name: t
      declaredElement: <testLibraryFragment>::@extensionType::A::@method::foo::@formalParameter::t
        type: T
    parameter: SimpleFormalParameter
      type: NamedType
        name: U
        element2: U@41
        type: U
      name: u
      declaredElement: <testLibraryFragment>::@extensionType::A::@method::foo::@formalParameter::u
        type: U
    rightParenthesis: )
  body: BlockFunctionBody
    block: Block
      leftBracket: {
      statements
        ExpressionStatement
          expression: SimpleIdentifier
            token: T
            element: T@17
            staticType: Type
          semicolon: ;
        ExpressionStatement
          expression: SimpleIdentifier
            token: U
            element: U@41
            staticType: Type
          semicolon: ;
      rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A::@method::foo
    type: void Function<U>(T, U)
''');
  }

  test_typeParameters() async {
    await assertNoErrorsInCode(r'''
extension type A<T, U>(Map<T, U> it) {}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: A
  typeParameters: TypeParameterList
    leftBracket: <
    typeParameters
      TypeParameter
        name: T
        declaredElement: T@17
          defaultType: dynamic
      TypeParameter
        name: U
        declaredElement: U@20
          defaultType: dynamic
    rightBracket: >
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: Map
      typeArguments: TypeArgumentList
        leftBracket: <
        arguments
          NamedType
            name: T
            element2: T@17
            type: T
          NamedType
            name: U
            element2: U@20
            type: U
        rightBracket: >
      element2: dart:core::@class::Map
      type: Map<T, U>
    fieldName: it
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::A::@field::it
    constructorFragment: <testLibraryFragment>::@extensionType::A::@constructor::new
  leftBracket: {
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::A
''');
  }

  test_typeParameters_wildcards() async {
    await assertNoErrorsInCode(r'''
extension type ET<_, _, _ extends num>(int _) {}
''');

    var node = findNode.singleExtensionTypeDeclaration;
    assertResolvedNodeText(node, r'''
ExtensionTypeDeclaration
  extensionKeyword: extension
  typeKeyword: type
  name: ET
  typeParameters: TypeParameterList
    leftBracket: <
    typeParameters
      TypeParameter
        name: _
        declaredElement: _@18
          defaultType: dynamic
      TypeParameter
        name: _
        declaredElement: _@21
          defaultType: dynamic
      TypeParameter
        name: _
        extendsKeyword: extends
        bound: NamedType
          name: num
          element2: dart:core::@class::num
          type: num
        declaredElement: _@24
          defaultType: num
    rightBracket: >
  representation: RepresentationDeclaration
    leftParenthesis: (
    fieldType: NamedType
      name: int
      element2: dart:core::@class::int
      type: int
    fieldName: _
    rightParenthesis: )
    fieldFragment: <testLibraryFragment>::@extensionType::ET::@field::_
    constructorFragment: <testLibraryFragment>::@extensionType::ET::@constructor::new
  leftBracket: {
  rightBracket: }
  declaredElement: <testLibraryFragment>::@extensionType::ET
''');
  }
}
