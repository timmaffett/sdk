// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../dart/resolution/node_text_expectations.dart';
import '../elements_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(TypeAliasElementTest_keepLinking);
    defineReflectiveTests(TypeAliasElementTest_fromBytes);
    // TODO(scheglov): implement augmentation
    // defineReflectiveTests(TypeAliasElementTest_augmentation_keepLinking);
    // defineReflectiveTests(TypeAliasElementTest_augmentation_fromBytes);
    defineReflectiveTests(UpdateNodeTextExpectations);
  });
}

abstract class TypeAliasElementTest extends ElementsBaseTest {
  test_codeRange_functionTypeAlias() async {
    var library = await buildLibrary('''
typedef Raw();

/// Comment 1.
/// Comment 2.
typedef HasDocComment();

@Object()
typedef HasAnnotation();

@Object()
/// Comment 1.
/// Comment 2.
typedef AnnotationThenComment();

/// Comment 1.
/// Comment 2.
@Object()
typedef CommentThenAnnotation();

/// Comment 1.
@Object()
/// Comment 2.
typedef CommentAroundAnnotation();
''');
    configuration.withCodeRanges = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        Raw @8
          reference: <testLibraryFragment>::@typeAlias::Raw
          element: <testLibrary>::@typeAlias::Raw
        HasDocComment @54
          reference: <testLibraryFragment>::@typeAlias::HasDocComment
          element: <testLibrary>::@typeAlias::HasDocComment
          documentationComment: /// Comment 1.\n/// Comment 2.
        HasAnnotation @90
          reference: <testLibraryFragment>::@typeAlias::HasAnnotation
          element: <testLibrary>::@typeAlias::HasAnnotation
          metadata
            Annotation
              atSign: @ @72
              name: SimpleIdentifier
                token: Object @73
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @79
                rightParenthesis: ) @80
              element2: dart:core::@class::Object::@constructor::new
        AnnotationThenComment @156
          reference: <testLibraryFragment>::@typeAlias::AnnotationThenComment
          element: <testLibrary>::@typeAlias::AnnotationThenComment
          documentationComment: /// Comment 1.\n/// Comment 2.
          metadata
            Annotation
              atSign: @ @108
              name: SimpleIdentifier
                token: Object @109
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @115
                rightParenthesis: ) @116
              element2: dart:core::@class::Object::@constructor::new
        CommentThenAnnotation @230
          reference: <testLibraryFragment>::@typeAlias::CommentThenAnnotation
          element: <testLibrary>::@typeAlias::CommentThenAnnotation
          documentationComment: /// Comment 1.\n/// Comment 2.
          metadata
            Annotation
              atSign: @ @212
              name: SimpleIdentifier
                token: Object @213
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @219
                rightParenthesis: ) @220
              element2: dart:core::@class::Object::@constructor::new
        CommentAroundAnnotation @304
          reference: <testLibraryFragment>::@typeAlias::CommentAroundAnnotation
          element: <testLibrary>::@typeAlias::CommentAroundAnnotation
          documentationComment: /// Comment 2.
          metadata
            Annotation
              atSign: @ @271
              name: SimpleIdentifier
                token: Object @272
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @278
                rightParenthesis: ) @279
              element2: dart:core::@class::Object::@constructor::new
  typeAliases
    Raw
      firstFragment: <testLibraryFragment>::@typeAlias::Raw
      aliasedType: dynamic Function()
    HasDocComment
      firstFragment: <testLibraryFragment>::@typeAlias::HasDocComment
      documentationComment: /// Comment 1.\n/// Comment 2.
      aliasedType: dynamic Function()
    HasAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::HasAnnotation
      metadata
        Annotation
          atSign: @ @72
          name: SimpleIdentifier
            token: Object @73
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @79
            rightParenthesis: ) @80
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    AnnotationThenComment
      firstFragment: <testLibraryFragment>::@typeAlias::AnnotationThenComment
      documentationComment: /// Comment 1.\n/// Comment 2.
      metadata
        Annotation
          atSign: @ @108
          name: SimpleIdentifier
            token: Object @109
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @115
            rightParenthesis: ) @116
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    CommentThenAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::CommentThenAnnotation
      documentationComment: /// Comment 1.\n/// Comment 2.
      metadata
        Annotation
          atSign: @ @212
          name: SimpleIdentifier
            token: Object @213
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @219
            rightParenthesis: ) @220
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    CommentAroundAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::CommentAroundAnnotation
      documentationComment: /// Comment 2.
      metadata
        Annotation
          atSign: @ @271
          name: SimpleIdentifier
            token: Object @272
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @278
            rightParenthesis: ) @279
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
''');
  }

  test_codeRange_genericTypeAlias() async {
    var library = await buildLibrary('''
typedef Raw = Function();

/// Comment 1.
/// Comment 2.
typedef HasDocComment = Function();

@Object()
typedef HasAnnotation = Function();

@Object()
/// Comment 1.
/// Comment 2.
typedef AnnotationThenComment = Function();

/// Comment 1.
/// Comment 2.
@Object()
typedef CommentThenAnnotation = Function();

/// Comment 1.
@Object()
/// Comment 2.
typedef CommentAroundAnnotation = Function();
''');
    configuration.withCodeRanges = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        Raw @8
          reference: <testLibraryFragment>::@typeAlias::Raw
          element: <testLibrary>::@typeAlias::Raw
        HasDocComment @65
          reference: <testLibraryFragment>::@typeAlias::HasDocComment
          element: <testLibrary>::@typeAlias::HasDocComment
          documentationComment: /// Comment 1.\n/// Comment 2.
        HasAnnotation @112
          reference: <testLibraryFragment>::@typeAlias::HasAnnotation
          element: <testLibrary>::@typeAlias::HasAnnotation
          metadata
            Annotation
              atSign: @ @94
              name: SimpleIdentifier
                token: Object @95
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @101
                rightParenthesis: ) @102
              element2: dart:core::@class::Object::@constructor::new
        AnnotationThenComment @189
          reference: <testLibraryFragment>::@typeAlias::AnnotationThenComment
          element: <testLibrary>::@typeAlias::AnnotationThenComment
          documentationComment: /// Comment 1.\n/// Comment 2.
          metadata
            Annotation
              atSign: @ @141
              name: SimpleIdentifier
                token: Object @142
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @148
                rightParenthesis: ) @149
              element2: dart:core::@class::Object::@constructor::new
        CommentThenAnnotation @274
          reference: <testLibraryFragment>::@typeAlias::CommentThenAnnotation
          element: <testLibrary>::@typeAlias::CommentThenAnnotation
          documentationComment: /// Comment 1.\n/// Comment 2.
          metadata
            Annotation
              atSign: @ @256
              name: SimpleIdentifier
                token: Object @257
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @263
                rightParenthesis: ) @264
              element2: dart:core::@class::Object::@constructor::new
        CommentAroundAnnotation @359
          reference: <testLibraryFragment>::@typeAlias::CommentAroundAnnotation
          element: <testLibrary>::@typeAlias::CommentAroundAnnotation
          documentationComment: /// Comment 2.
          metadata
            Annotation
              atSign: @ @326
              name: SimpleIdentifier
                token: Object @327
                element: dart:core::@class::Object
                staticType: null
              arguments: ArgumentList
                leftParenthesis: ( @333
                rightParenthesis: ) @334
              element2: dart:core::@class::Object::@constructor::new
  typeAliases
    Raw
      firstFragment: <testLibraryFragment>::@typeAlias::Raw
      aliasedType: dynamic Function()
    HasDocComment
      firstFragment: <testLibraryFragment>::@typeAlias::HasDocComment
      documentationComment: /// Comment 1.\n/// Comment 2.
      aliasedType: dynamic Function()
    HasAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::HasAnnotation
      metadata
        Annotation
          atSign: @ @94
          name: SimpleIdentifier
            token: Object @95
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @101
            rightParenthesis: ) @102
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    AnnotationThenComment
      firstFragment: <testLibraryFragment>::@typeAlias::AnnotationThenComment
      documentationComment: /// Comment 1.\n/// Comment 2.
      metadata
        Annotation
          atSign: @ @141
          name: SimpleIdentifier
            token: Object @142
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @148
            rightParenthesis: ) @149
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    CommentThenAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::CommentThenAnnotation
      documentationComment: /// Comment 1.\n/// Comment 2.
      metadata
        Annotation
          atSign: @ @256
          name: SimpleIdentifier
            token: Object @257
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @263
            rightParenthesis: ) @264
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
    CommentAroundAnnotation
      firstFragment: <testLibraryFragment>::@typeAlias::CommentAroundAnnotation
      documentationComment: /// Comment 2.
      metadata
        Annotation
          atSign: @ @326
          name: SimpleIdentifier
            token: Object @327
            element: dart:core::@class::Object
            staticType: null
          arguments: ArgumentList
            leftParenthesis: ( @333
            rightParenthesis: ) @334
          element2: dart:core::@class::Object::@constructor::new
      aliasedType: dynamic Function()
''');
  }

  test_functionTypeAlias_enclosingElements() async {
    var library = await buildLibrary(r'''
typedef void F<T>(int a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(int)
''');
  }

  test_functionTypeAlias_type_element() async {
    var library = await buildLibrary(r'''
typedef T F<T>();
void f(F<int> a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
      functions
        f @23
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @32
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function()
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: int Function()
            alias: <testLibrary>::@typeAlias::F
              typeArguments
                int
      returnType: void
''');
  }

  test_functionTypeAlias_typeParameters_variance_contravariant() async {
    var library = await buildLibrary(r'''
typedef void F<T>(T a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(T)
''');
  }

  test_functionTypeAlias_typeParameters_variance_contravariant2() async {
    var library = await buildLibrary(r'''
typedef void F1<T>(T a);
typedef F1<T> F2<T>();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @13
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @16
              element: T@16
        F2 @39
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @42
              element: T@42
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: void Function(T)
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: void Function(T) Function()
''');
  }

  test_functionTypeAlias_typeParameters_variance_contravariant3() async {
    var library = await buildLibrary(r'''
typedef F1<T> F2<T>();
typedef void F1<T>(T a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F2 @14
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @17
              element: T@17
        F1 @36
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @39
              element: T@39
  typeAliases
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: void Function(T) Function()
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: void Function(T)
''');
  }

  test_functionTypeAlias_typeParameters_variance_covariant() async {
    var library = await buildLibrary(r'''
typedef T F<T>();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function()
''');
  }

  test_functionTypeAlias_typeParameters_variance_covariant2() async {
    var library = await buildLibrary(r'''
typedef List<T> F<T>();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @16
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @18
              element: T@18
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: List<T> Function()
''');
  }

  test_functionTypeAlias_typeParameters_variance_covariant3() async {
    var library = await buildLibrary(r'''
typedef T F1<T>();
typedef F1<T> F2<T>();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @10
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @13
              element: T@13
        F2 @33
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @36
              element: T@36
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: T Function()
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: T Function() Function()
''');
  }

  test_functionTypeAlias_typeParameters_variance_covariant4() async {
    var library = await buildLibrary(r'''
typedef void F1<T>(T a);
typedef void F2<T>(F1<T> a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @13
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @16
              element: T@16
        F2 @38
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @41
              element: T@41
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: void Function(T)
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: void Function(void Function(T))
''');
  }

  test_functionTypeAlias_typeParameters_variance_invariant() async {
    var library = await buildLibrary(r'''
typedef T F<T>(T a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function(T)
''');
  }

  test_functionTypeAlias_typeParameters_variance_invariant2() async {
    var library = await buildLibrary(r'''
typedef T F1<T>();
typedef F1<T> F2<T>(T a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @10
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @13
              element: T@13
        F2 @33
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @36
              element: T@36
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: T Function()
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: T Function() Function(T)
''');
  }

  test_functionTypeAlias_typeParameters_variance_unrelated() async {
    var library = await buildLibrary(r'''
typedef void F<T>(int a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(int)
''');
  }

  test_genericTypeAlias_enclosingElements() async {
    var library = await buildLibrary(r'''
typedef F<T> = void Function<U>(int a);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function<U>(int)
''');
  }

  test_genericTypeAlias_recursive() async {
    var library = await buildLibrary('''
typedef F<X extends F> = Function(F);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            X @10
              element: X@10
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        X
          bound: dynamic
      aliasedType: dynamic Function(dynamic)
''');
  }

  test_new_typedef_function_notSimplyBounded_functionType_returnType() async {
    var library = await buildLibrary('''
typedef F = G Function();
typedef G = F Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
        G @34
          reference: <testLibraryFragment>::@typeAlias::G
          element: <testLibrary>::@typeAlias::G
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function()
    notSimplyBounded G
      firstFragment: <testLibraryFragment>::@typeAlias::G
      aliasedType: dynamic Function()
''');
  }

  test_new_typedef_function_notSimplyBounded_functionType_returnType_viaInterfaceType() async {
    var library = await buildLibrary('''
typedef F = List<F> Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: List<dynamic> Function()
''');
  }

  test_new_typedef_function_notSimplyBounded_self() async {
    var library = await buildLibrary('''
typedef F<T extends F> = void Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: dynamic
      aliasedType: void Function()
''');
  }

  test_new_typedef_function_notSimplyBounded_simple_no_bounds() async {
    var library = await buildLibrary('''
typedef F<T> = void Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function()
''');
  }

  test_new_typedef_function_notSimplyBounded_simple_non_generic() async {
    var library = await buildLibrary('''
typedef F = void Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function()
''');
  }

  test_new_typedef_nonFunction_notSimplyBounded_self() async {
    var library = await buildLibrary('''
typedef F<T extends F> = List<int>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: dynamic
      aliasedType: List<int>
''');
  }

  test_new_typedef_nonFunction_notSimplyBounded_viaInterfaceType() async {
    var library = await buildLibrary('''
typedef F = List<F>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: List<dynamic>
''');
  }

  test_typeAlias_formalParameters_optional() async {
    var library = await buildLibrary(r'''
typedef A = void Function({int p});

void f(A a) {}
''');
    configuration.withFunctionTypeParameters = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @42
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @46
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: void Function({int p})
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: void Function({int p})
            alias: <testLibrary>::@typeAlias::A
      returnType: void
''');
  }

  test_typeAlias_parameter_typeParameters() async {
    var library = await buildLibrary(r'''
typedef void F(T a<T, U>(U u));
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function(T Function<T, U>(U))
''');
  }

  test_typeAlias_typeParameters_variance_function_contravariant() async {
    var library = await buildLibrary(r'''
typedef F<T> = void Function(T);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(T)
''');
  }

  test_typeAlias_typeParameters_variance_function_contravariant2() async {
    var library = await buildLibrary(r'''
typedef F1<T> = void Function(T);
typedef F2<T> = F1<T> Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @8
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @11
              element: T@11
        F2 @42
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @45
              element: T@45
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: void Function(T)
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: void Function(T) Function()
''');
  }

  test_typeAlias_typeParameters_variance_function_covariant() async {
    var library = await buildLibrary(r'''
typedef F<T> = T Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function()
''');
  }

  test_typeAlias_typeParameters_variance_function_covariant2() async {
    var library = await buildLibrary(r'''
typedef F<T> = List<T> Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: List<T> Function()
''');
  }

  test_typeAlias_typeParameters_variance_function_covariant3() async {
    var library = await buildLibrary(r'''
typedef F1<T> = T Function();
typedef F2<T> = F1<T> Function();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @8
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @11
              element: T@11
        F2 @38
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @41
              element: T@41
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: T Function()
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: T Function() Function()
''');
  }

  test_typeAlias_typeParameters_variance_function_covariant4() async {
    var library = await buildLibrary(r'''
typedef F1<T> = void Function(T);
typedef F2<T> = void Function(F1<T>);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @8
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @11
              element: T@11
        F2 @42
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @45
              element: T@45
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: void Function(T)
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: void Function(void Function(T))
''');
  }

  test_typeAlias_typeParameters_variance_function_invalid() async {
    var library = await buildLibrary(r'''
class A {}
typedef F<T> = void Function(A<int>);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @6
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        F @19
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @21
              element: T@21
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(A)
''');
  }

  test_typeAlias_typeParameters_variance_function_invalid2() async {
    var library = await buildLibrary(r'''
typedef F = void Function();
typedef G<T> = void Function(F<int>);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
        G @37
          reference: <testLibraryFragment>::@typeAlias::G
          element: <testLibrary>::@typeAlias::G
          typeParameters
            T @39
              element: T@39
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function()
    G
      firstFragment: <testLibraryFragment>::@typeAlias::G
      typeParameters
        T
      aliasedType: void Function(void Function())
''');
  }

  test_typeAlias_typeParameters_variance_function_invariant() async {
    var library = await buildLibrary(r'''
typedef F<T> = T Function(T);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function(T)
''');
  }

  test_typeAlias_typeParameters_variance_function_invariant2() async {
    var library = await buildLibrary(r'''
typedef F1<T> = T Function();
typedef F2<T> = F1<T> Function(T);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F1 @8
          reference: <testLibraryFragment>::@typeAlias::F1
          element: <testLibrary>::@typeAlias::F1
          typeParameters
            T @11
              element: T@11
        F2 @38
          reference: <testLibraryFragment>::@typeAlias::F2
          element: <testLibrary>::@typeAlias::F2
          typeParameters
            T @41
              element: T@41
  typeAliases
    F1
      firstFragment: <testLibraryFragment>::@typeAlias::F1
      typeParameters
        T
      aliasedType: T Function()
    F2
      firstFragment: <testLibraryFragment>::@typeAlias::F2
      typeParameters
        T
      aliasedType: T Function() Function(T)
''');
  }

  test_typeAlias_typeParameters_variance_function_unrelated() async {
    var library = await buildLibrary(r'''
typedef F<T> = void Function(int);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function(int)
''');
  }

  test_typeAlias_typeParameters_variance_interface_contravariant() async {
    var library = await buildLibrary(r'''
typedef A<T> = List<void Function(T)>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: List<void Function(T)>
''');
  }

  test_typeAlias_typeParameters_variance_interface_contravariant2() async {
    var library = await buildLibrary(r'''
typedef A<T> = void Function(T);
typedef B<T> = List<A<T>>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
        B @41
          reference: <testLibraryFragment>::@typeAlias::B
          element: <testLibrary>::@typeAlias::B
          typeParameters
            T @43
              element: T@43
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: void Function(T)
    B
      firstFragment: <testLibraryFragment>::@typeAlias::B
      typeParameters
        T
      aliasedType: List<void Function(T)>
''');
  }

  test_typeAlias_typeParameters_variance_interface_covariant() async {
    var library = await buildLibrary(r'''
typedef A<T> = List<T>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: List<T>
''');
  }

  test_typeAlias_typeParameters_variance_interface_covariant2() async {
    var library = await buildLibrary(r'''
typedef A<T> = Map<int, T>;
typedef B<T> = List<A<T>>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
        B @36
          reference: <testLibraryFragment>::@typeAlias::B
          element: <testLibrary>::@typeAlias::B
          typeParameters
            T @38
              element: T@38
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: Map<int, T>
    B
      firstFragment: <testLibraryFragment>::@typeAlias::B
      typeParameters
        T
      aliasedType: List<Map<int, T>>
''');
  }

  test_typeAlias_typeParameters_variance_record_contravariant() async {
    var library = await buildLibrary(r'''
typedef A<T> = (void Function(T), int);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: (void Function(T), int)
''');
  }

  test_typeAlias_typeParameters_variance_record_contravariant2() async {
    var library = await buildLibrary(r'''
typedef A<T> = (void Function(T), int);
typedef B<T> = List<A<T>>;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
        B @48
          reference: <testLibraryFragment>::@typeAlias::B
          element: <testLibrary>::@typeAlias::B
          typeParameters
            T @50
              element: T@50
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: (void Function(T), int)
    B
      firstFragment: <testLibraryFragment>::@typeAlias::B
      typeParameters
        T
      aliasedType: List<(void Function(T), int)>
''');
  }

  test_typeAlias_typeParameters_variance_record_covariant() async {
    var library = await buildLibrary(r'''
typedef A<T> = (T, int);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: (T, int)
''');
  }

  test_typeAlias_typeParameters_variance_record_invariant() async {
    var library = await buildLibrary(r'''
typedef A<T> = (T Function(T), int);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: (T Function(T), int)
''');
  }

  test_typeAlias_typeParameters_variance_record_unrelated() async {
    var library = await buildLibrary(r'''
typedef A<T> = (int, String);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: (int, String)
''');
  }

  test_typedef_function_generic() async {
    var library = await buildLibrary(
      'typedef F<T> = int Function<S>(List<S> list, num Function<A>(A), T);',
    );
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: int Function<S>(List<S>, num Function<A>(A), T)
''');
  }

  test_typedef_function_generic_asFieldType() async {
    var library = await buildLibrary(r'''
typedef Foo<S> = S Function<T>(T x);
class A {
  Foo<int> f;
}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @43
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          fields
            f @58
              reference: <testLibraryFragment>::@class::A::@field::f
              element: <testLibrary>::@class::A::@field::f
              getter2: <testLibraryFragment>::@class::A::@getter::f
              setter2: <testLibraryFragment>::@class::A::@setter::f
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
          getters
            synthetic get f
              reference: <testLibraryFragment>::@class::A::@getter::f
              element: <testLibraryFragment>::@class::A::@getter::f#element
          setters
            synthetic set f
              reference: <testLibraryFragment>::@class::A::@setter::f
              element: <testLibraryFragment>::@class::A::@setter::f#element
              formalParameters
                _f
                  element: <testLibraryFragment>::@class::A::@setter::f::@parameter::_f#element
      typeAliases
        Foo @8
          reference: <testLibraryFragment>::@typeAlias::Foo
          element: <testLibrary>::@typeAlias::Foo
          typeParameters
            S @12
              element: S@12
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      fields
        f
          firstFragment: <testLibraryFragment>::@class::A::@field::f
          type: int Function<T>(T)
            alias: <testLibrary>::@typeAlias::Foo
              typeArguments
                int
          getter: <testLibraryFragment>::@class::A::@getter::f#element
          setter: <testLibraryFragment>::@class::A::@setter::f#element
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
      getters
        synthetic get f
          firstFragment: <testLibraryFragment>::@class::A::@getter::f
          returnType: int Function<T>(T)
            alias: <testLibrary>::@typeAlias::Foo
              typeArguments
                int
      setters
        synthetic set f
          firstFragment: <testLibraryFragment>::@class::A::@setter::f
          formalParameters
            requiredPositional _f
              type: int Function<T>(T)
                alias: <testLibrary>::@typeAlias::Foo
                  typeArguments
                    int
          returnType: void
  typeAliases
    Foo
      firstFragment: <testLibraryFragment>::@typeAlias::Foo
      typeParameters
        S
      aliasedType: S Function<T>(T)
''');
  }

  test_typedef_function_notSimplyBounded_dependency_via_param_type_name_included() async {
    // F is considered "not simply bounded" because it expands to a type that
    // refers to C, which is not simply bounded.
    var library = await buildLibrary('''
typedef F = void Function(C c);
class C<T extends C<T>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @38
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            T @40
              element: T@40
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  classes
    notSimplyBounded class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        T
          bound: C<T>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function(C<C<dynamic>>)
''');
  }

  test_typedef_function_notSimplyBounded_dependency_via_param_type_name_omitted() async {
    // F is considered "not simply bounded" because it expands to a type that
    // refers to C, which is not simply bounded.
    var library = await buildLibrary('''
typedef F = void Function(C);
class C<T extends C<T>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @36
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            T @38
              element: T@38
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  classes
    notSimplyBounded class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        T
          bound: C<T>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function(C<C<dynamic>>)
''');
  }

  test_typedef_function_notSimplyBounded_dependency_via_return_type() async {
    // F is considered "not simply bounded" because it expands to a type that
    // refers to C, which is not simply bounded.
    var library = await buildLibrary('''
typedef F = C Function();
class C<T extends C<T>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @32
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            T @34
              element: T@34
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  classes
    notSimplyBounded class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        T
          bound: C<T>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: C<C<dynamic>> Function()
''');
  }

  test_typedef_function_typeParameters_f_bound_simple() async {
    var library = await buildLibrary(
      'typedef F<T extends U, U> = U Function(T t);',
    );
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
            U @23
              element: U@23
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: U
        U
      aliasedType: U Function(T)
''');
  }

  test_typedef_legacy_documented() async {
    var library = await buildLibrary('''
// Extra comment so doc comment offset != 0
/**
 * Docs
 */
typedef F();''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @68
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          documentationComment: /**\n * Docs\n */
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      documentationComment: /**\n * Docs\n */
      aliasedType: dynamic Function()
''');
  }

  test_typedef_legacy_notSimplyBounded_dependency_via_param_type() async {
    // F is considered "not simply bounded" because it expands to a type that
    // refers to C, which is not simply bounded.
    var library = await buildLibrary('''
typedef void F(C c);
class C<T extends C<T>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @27
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            T @29
              element: T@29
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  classes
    notSimplyBounded class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        T
          bound: C<T>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function(C<C<dynamic>>)
''');
  }

  test_typedef_legacy_notSimplyBounded_dependency_via_return_type() async {
    // F is considered "not simply bounded" because it expands to a type that
    // refers to C, which is not simply bounded.
    var library = await buildLibrary('''
typedef C F();
class C<T extends C<T>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class C @21
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            T @23
              element: T@23
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  classes
    notSimplyBounded class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        T
          bound: C<T>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: C<C<dynamic>> Function()
''');
  }

  test_typedef_legacy_notSimplyBounded_self() async {
    var library = await buildLibrary('''
typedef void F<T extends F>();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: dynamic
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_notSimplyBounded_simple_because_non_generic() async {
    var library = await buildLibrary('''
typedef void F();
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_notSimplyBounded_simple_no_bounds() async {
    var library = await buildLibrary('typedef void F<T>();');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_parameter_hasImplicitType() async {
    var library = await buildLibrary(r'''
typedef void F(int a, b, [int c, d]);
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function(int, dynamic, [int, dynamic])
''');
  }

  test_typedef_legacy_parameter_parameters() async {
    var library = await buildLibrary('typedef F(g(x, y));');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function(dynamic Function(dynamic, dynamic))
''');
  }

  test_typedef_legacy_parameter_parameters_in_generic_class() async {
    var library = await buildLibrary('typedef F<A, B>(A g(B x));');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            A @10
              element: A@10
            B @13
              element: B@13
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        A
        B
      aliasedType: dynamic Function(A Function(B))
''');
  }

  test_typedef_legacy_parameter_return_type() async {
    var library = await buildLibrary('typedef F(int g());');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function(int Function())
''');
  }

  test_typedef_legacy_parameter_type() async {
    var library = await buildLibrary('typedef F(int i);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function(int)
''');
  }

  test_typedef_legacy_parameter_type_generic() async {
    var library = await buildLibrary('typedef F<T>(T t);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @10
              element: T@10
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: dynamic Function(T)
''');
  }

  test_typedef_legacy_parameters() async {
    var library = await buildLibrary('typedef F(x, y);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function(dynamic, dynamic)
''');
  }

  test_typedef_legacy_parameters_named() async {
    var library = await buildLibrary('typedef F({y, z, x});');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function({dynamic x, dynamic y, dynamic z})
''');
  }

  test_typedef_legacy_return_type() async {
    var library = await buildLibrary('typedef int F();');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @12
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: int Function()
''');
  }

  test_typedef_legacy_return_type_generic() async {
    var library = await buildLibrary('typedef T F<T>();');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
      aliasedType: T Function()
''');
  }

  test_typedef_legacy_return_type_implicit() async {
    var library = await buildLibrary('typedef F();');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: dynamic Function()
''');
  }

  test_typedef_legacy_return_type_void() async {
    var library = await buildLibrary('typedef void F();');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_typeParameters() async {
    var library = await buildLibrary('typedef U F<T, U>(T t);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
            U @15
              element: U@15
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
        U
      aliasedType: U Function(T)
''');
  }

  test_typedef_legacy_typeParameters_bound() async {
    var library = await buildLibrary(
      'typedef U F<T extends Object, U extends D>(T t); class D {}',
    );
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class D @55
          reference: <testLibraryFragment>::@class::D
          element: <testLibrary>::@class::D
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::D::@constructor::new
              element: <testLibrary>::@class::D::@constructor::new
              typeName: D
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
            U @30
              element: U@30
  classes
    class D
      reference: <testLibrary>::@class::D
      firstFragment: <testLibraryFragment>::@class::D
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::D::@constructor::new
  typeAliases
    F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: Object
        U
          bound: D
      aliasedType: U Function(T)
''');
  }

  test_typedef_legacy_typeParameters_bound_recursive() async {
    var library = await buildLibrary('typedef void F<T extends F>();');
    // Typedefs cannot reference themselves.
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: dynamic
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_typeParameters_bound_recursive2() async {
    var library = await buildLibrary('typedef void F<T extends List<F>>();');
    // Typedefs cannot reference themselves.
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @13
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @15
              element: T@15
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: List<dynamic>
      aliasedType: void Function()
''');
  }

  test_typedef_legacy_typeParameters_f_bound_complex() async {
    var library = await buildLibrary('typedef U F<T extends List<U>, U>(T t);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
            U @31
              element: U@31
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: List<U>
        U
      aliasedType: U Function(T)
''');
  }

  test_typedef_legacy_typeParameters_f_bound_simple() async {
    var library = await buildLibrary('typedef U F<T extends U, U>(T t);');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @10
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
          typeParameters
            T @12
              element: T@12
            U @25
              element: U@25
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      typeParameters
        T
          bound: U
        U
      aliasedType: U Function(T)
''');
  }

  @SkippedTest(
    issue: 'https://github.com/dart-lang/sdk/issues/45291',
    reason: 'Type dynamic is special, no support for its aliases yet',
  )
  test_typedef_nonFunction_aliasElement_dynamic() async {
    var library = await buildLibrary(r'''
typedef A = dynamic;
void f(A a) {}
''');

    checkElementText(library, r'''
typedef A = dynamic;
void f(dynamic<aliasElement: self::@typeAlias::A> a) {}
''');
  }

  test_typedef_nonFunction_aliasElement_functionType() async {
    var library = await buildLibrary(r'''
typedef A1 = void Function();
typedef A2<R> = R Function();
void f1(A1 a) {}
void f2(A2<int> a) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A1 @8
          reference: <testLibraryFragment>::@typeAlias::A1
          element: <testLibrary>::@typeAlias::A1
        A2 @38
          reference: <testLibraryFragment>::@typeAlias::A2
          element: <testLibrary>::@typeAlias::A2
          typeParameters
            R @41
              element: R@41
      functions
        f1 @65
          reference: <testLibraryFragment>::@function::f1
          element: <testLibrary>::@function::f1
          formalParameters
            a @71
              element: <testLibraryFragment>::@function::f1::@parameter::a#element
        f2 @82
          reference: <testLibraryFragment>::@function::f2
          element: <testLibrary>::@function::f2
          formalParameters
            a @93
              element: <testLibraryFragment>::@function::f2::@parameter::a#element
  typeAliases
    A1
      firstFragment: <testLibraryFragment>::@typeAlias::A1
      aliasedType: void Function()
    A2
      firstFragment: <testLibraryFragment>::@typeAlias::A2
      typeParameters
        R
      aliasedType: R Function()
  functions
    f1
      reference: <testLibrary>::@function::f1
      firstFragment: <testLibraryFragment>::@function::f1
      formalParameters
        requiredPositional a
          type: void Function()
            alias: <testLibrary>::@typeAlias::A1
      returnType: void
    f2
      reference: <testLibrary>::@function::f2
      firstFragment: <testLibraryFragment>::@function::f2
      formalParameters
        requiredPositional a
          type: int Function()
            alias: <testLibrary>::@typeAlias::A2
              typeArguments
                int
      returnType: void
''');
  }

  test_typedef_nonFunction_aliasElement_interfaceType() async {
    var library = await buildLibrary(r'''
typedef A1 = List<int>;
typedef A2<T, U> = Map<T, U>;
void f1(A1 a) {}
void f2(A2<int, String> a) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A1 @8
          reference: <testLibraryFragment>::@typeAlias::A1
          element: <testLibrary>::@typeAlias::A1
        A2 @32
          reference: <testLibraryFragment>::@typeAlias::A2
          element: <testLibrary>::@typeAlias::A2
          typeParameters
            T @35
              element: T@35
            U @38
              element: U@38
      functions
        f1 @59
          reference: <testLibraryFragment>::@function::f1
          element: <testLibrary>::@function::f1
          formalParameters
            a @65
              element: <testLibraryFragment>::@function::f1::@parameter::a#element
        f2 @76
          reference: <testLibraryFragment>::@function::f2
          element: <testLibrary>::@function::f2
          formalParameters
            a @95
              element: <testLibraryFragment>::@function::f2::@parameter::a#element
  typeAliases
    A1
      firstFragment: <testLibraryFragment>::@typeAlias::A1
      aliasedType: List<int>
    A2
      firstFragment: <testLibraryFragment>::@typeAlias::A2
      typeParameters
        T
        U
      aliasedType: Map<T, U>
  functions
    f1
      reference: <testLibrary>::@function::f1
      firstFragment: <testLibraryFragment>::@function::f1
      formalParameters
        requiredPositional a
          type: List<int>
            alias: <testLibrary>::@typeAlias::A1
      returnType: void
    f2
      reference: <testLibrary>::@function::f2
      firstFragment: <testLibraryFragment>::@function::f2
      formalParameters
        requiredPositional a
          type: Map<int, String>
            alias: <testLibrary>::@typeAlias::A2
              typeArguments
                int
                String
      returnType: void
''');
  }

  @SkippedTest(
    issue: 'https://github.com/dart-lang/sdk/issues/45291',
    reason: 'Type Never is special, no support for its aliases yet',
  )
  test_typedef_nonFunction_aliasElement_never() async {
    var library = await buildLibrary(r'''
typedef A1 = Never;
typedef A2<T> = Never?;
void f1(A1 a) {}
void f2(A2<int> a) {}
''');

    checkElementText(library, r'''
typedef A1 = Never;
typedef A2<T> = Never?;
void f1(Never<aliasElement: self::@typeAlias::A1> a) {}
void f2(Never?<aliasElement: self::@typeAlias::A2, aliasArguments: [int]> a) {}
''');
  }

  test_typedef_nonFunction_aliasElement_recordType_generic() async {
    var library = await buildLibrary(r'''
typedef A<T, U> = (T, U);
void f(A<int, String> a) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
            U @13
              element: U@13
      functions
        f @31
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @48
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
        U
      aliasedType: (T, U)
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: (int, String)
            alias: <testLibrary>::@typeAlias::A
              typeArguments
                int
                String
      returnType: void
''');
  }

  test_typedef_nonFunction_aliasElement_typeParameterType() async {
    var library = await buildLibrary(r'''
typedef A<T> = T;
void f<U>(A<U> a) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
      functions
        f @23
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          typeParameters
            U @25
              element: U@25
          formalParameters
            a @33
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: T
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      typeParameters
        U
      formalParameters
        requiredPositional a
          type: U
            alias: <testLibrary>::@typeAlias::A
              typeArguments
                U
      returnType: void
''');
  }

  @SkippedTest(
    issue: 'https://github.com/dart-lang/sdk/issues/45291',
    reason: 'Type void is special, no support for its aliases yet',
  )
  test_typedef_nonFunction_aliasElement_void() async {
    var library = await buildLibrary(r'''
typedef A = void;
void f(A a) {}
''');

    checkElementText(library, r'''
typedef A = void;
void f(void<aliasElement: self::@typeAlias::A> a) {}
''');
  }

  test_typedef_nonFunction_asInterfaceType_interfaceType_none() async {
    var library = await buildLibrary(r'''
typedef X<T> = A<int, T>;
class A<T, U> {}
class B implements X<String> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @32
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @34
              element: T@34
            U @37
              element: U@37
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @49
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
          typeParameters
            T @10
              element: T@10
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
        U
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      interfaces
        A<int, String>
          alias: <testLibrary>::@typeAlias::X
            typeArguments
              String
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      typeParameters
        T
      aliasedType: A<int, T>
''');
  }

  test_typedef_nonFunction_asInterfaceType_interfaceType_question() async {
    var library = await buildLibrary(r'''
typedef X<T> = A<T>?;
class A<T> {}
class B {}
class C {}
class D implements B, X<int>, C {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @28
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @30
              element: T@30
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @42
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
        class C @53
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
        class D @64
          reference: <testLibraryFragment>::@class::D
          element: <testLibrary>::@class::D
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::D::@constructor::new
              element: <testLibrary>::@class::D::@constructor::new
              typeName: D
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
          typeParameters
            T @10
              element: T@10
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
    class D
      reference: <testLibrary>::@class::D
      firstFragment: <testLibraryFragment>::@class::D
      interfaces
        B
        C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::D::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      typeParameters
        T
      aliasedType: A<T>?
''');
  }

  test_typedef_nonFunction_asInterfaceType_interfaceType_question2() async {
    var library = await buildLibrary(r'''
typedef X<T> = A<T?>;
class A<T> {}
class B {}
class C {}
class D implements B, X<int>, C {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @28
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @30
              element: T@30
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @42
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
        class C @53
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
        class D @64
          reference: <testLibraryFragment>::@class::D
          element: <testLibrary>::@class::D
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::D::@constructor::new
              element: <testLibrary>::@class::D::@constructor::new
              typeName: D
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
          typeParameters
            T @10
              element: T@10
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
    class D
      reference: <testLibrary>::@class::D
      firstFragment: <testLibraryFragment>::@class::D
      interfaces
        B
        A<int?>
          alias: <testLibrary>::@typeAlias::X
            typeArguments
              int
        C
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::D::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      typeParameters
        T
      aliasedType: A<T?>
''');
  }

  test_typedef_nonFunction_asInterfaceType_Never_none() async {
    var library = await buildLibrary(r'''
typedef X = Never;
class A implements X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @25
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Never
''');
  }

  test_typedef_nonFunction_asInterfaceType_Null_none() async {
    var library = await buildLibrary(r'''
typedef X = Null;
class A implements X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Null
''');
  }

  test_typedef_nonFunction_asInterfaceType_typeParameterType() async {
    var library = await buildLibrary(r'''
typedef X<T> = T;
class A {}
class B {}
class C<U> implements A, X<U>, B {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @35
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
        class C @46
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          typeParameters
            U @48
              element: U@48
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
          typeParameters
            T @10
              element: T@10
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      typeParameters
        U
      interfaces
        A
        B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      typeParameters
        T
      aliasedType: T
''');
  }

  test_typedef_nonFunction_asInterfaceType_void() async {
    var library = await buildLibrary(r'''
typedef X = void;
class A {}
class B {}
class C implements A, X, B {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @35
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
        class C @46
          reference: <testLibraryFragment>::@class::C
          element: <testLibrary>::@class::C
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::C::@constructor::new
              element: <testLibrary>::@class::C::@constructor::new
              typeName: C
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
    class C
      reference: <testLibrary>::@class::C
      firstFragment: <testLibraryFragment>::@class::C
      interfaces
        A
        B
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::C::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: void
''');
  }

  test_typedef_nonFunction_asMixinType_none() async {
    var library = await buildLibrary(r'''
typedef X = A<int>;
class A<T> {}
class B with X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @26
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @28
              element: T@28
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @40
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: Object
      mixins
        A<int>
          alias: <testLibrary>::@typeAlias::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int>
''');
  }

  test_typedef_nonFunction_asMixinType_question() async {
    var library = await buildLibrary(r'''
typedef X = A<int>?;
class A<T> {}
mixin M1 {}
mixin M2 {}
class B with M1, X, M2 {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @27
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @29
              element: T@29
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @65
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      mixins
        mixin M1 @41
          reference: <testLibraryFragment>::@mixin::M1
          element: <testLibrary>::@mixin::M1
        mixin M2 @53
          reference: <testLibraryFragment>::@mixin::M2
          element: <testLibrary>::@mixin::M2
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: Object
      mixins
        M1
        M2
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
  mixins
    mixin M1
      reference: <testLibrary>::@mixin::M1
      firstFragment: <testLibraryFragment>::@mixin::M1
      superclassConstraints
        Object
    mixin M2
      reference: <testLibrary>::@mixin::M2
      firstFragment: <testLibraryFragment>::@mixin::M2
      superclassConstraints
        Object
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int>?
''');
  }

  test_typedef_nonFunction_asMixinType_question2() async {
    var library = await buildLibrary(r'''
typedef X = A<int?>;
class A<T> {}
mixin M1 {}
mixin M2 {}
class B with M1, X, M2 {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @27
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @29
              element: T@29
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @65
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      mixins
        mixin M1 @41
          reference: <testLibraryFragment>::@mixin::M1
          element: <testLibrary>::@mixin::M1
        mixin M2 @53
          reference: <testLibraryFragment>::@mixin::M2
          element: <testLibrary>::@mixin::M2
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: Object
      mixins
        M1
        A<int?>
          alias: <testLibrary>::@typeAlias::X
        M2
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
  mixins
    mixin M1
      reference: <testLibrary>::@mixin::M1
      firstFragment: <testLibraryFragment>::@mixin::M1
      superclassConstraints
        Object
    mixin M2
      reference: <testLibrary>::@mixin::M2
      firstFragment: <testLibraryFragment>::@mixin::M2
      superclassConstraints
        Object
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int?>
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_Never_none() async {
    var library = await buildLibrary(r'''
typedef X = Never;
class A extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @25
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Never
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_none() async {
    var library = await buildLibrary(r'''
typedef X = A<int>;
class A<T> {}
class B extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @26
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @28
              element: T@28
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @40
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: A<int>
        alias: <testLibrary>::@typeAlias::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
          superConstructor: <testLibrary>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int>
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_none_viaTypeParameter() async {
    var library = await buildLibrary(r'''
typedef X<T> = T;
class A<T> {}
class B extends X<A<int>> {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @26
              element: T@26
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class B @38
          reference: <testLibraryFragment>::@class::B
          element: <testLibrary>::@class::B
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::B::@constructor::new
              element: <testLibrary>::@class::B::@constructor::new
              typeName: B
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
          typeParameters
            T @10
              element: T@10
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class B
      reference: <testLibrary>::@class::B
      firstFragment: <testLibraryFragment>::@class::B
      supertype: A<int>
        alias: <testLibrary>::@typeAlias::X
          typeArguments
            A<int>
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::B::@constructor::new
          superConstructor: <testLibrary>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      typeParameters
        T
      aliasedType: T
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_Null_none() async {
    var library = await buildLibrary(r'''
typedef X = Null;
class A extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Null
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_question() async {
    var library = await buildLibrary(r'''
typedef X = A<int>?;
class A<T> {}
class D extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @27
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @29
              element: T@29
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class D @41
          reference: <testLibraryFragment>::@class::D
          element: <testLibrary>::@class::D
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::D::@constructor::new
              element: <testLibrary>::@class::D::@constructor::new
              typeName: D
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class D
      reference: <testLibrary>::@class::D
      firstFragment: <testLibraryFragment>::@class::D
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::D::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int>?
''');
  }

  test_typedef_nonFunction_asSuperType_interfaceType_question2() async {
    var library = await buildLibrary(r'''
typedef X = A<int?>;
class A<T> {}
class D extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @27
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          typeParameters
            T @29
              element: T@29
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
        class D @41
          reference: <testLibraryFragment>::@class::D
          element: <testLibrary>::@class::D
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::D::@constructor::new
              element: <testLibrary>::@class::D::@constructor::new
              typeName: D
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      typeParameters
        T
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
    class D
      reference: <testLibrary>::@class::D
      firstFragment: <testLibraryFragment>::@class::D
      supertype: A<int?>
        alias: <testLibrary>::@typeAlias::X
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::D::@constructor::new
          superConstructor: <testLibrary>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: A<int?>
''');
  }

  test_typedef_nonFunction_asSuperType_Never_none() async {
    var library = await buildLibrary(r'''
typedef X = Never;
class A extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @25
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Never
''');
  }

  test_typedef_nonFunction_asSuperType_Null_none() async {
    var library = await buildLibrary(r'''
typedef X = Null;
class A extends X {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      classes
        class A @24
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
          constructors
            synthetic new
              reference: <testLibraryFragment>::@class::A::@constructor::new
              element: <testLibrary>::@class::A::@constructor::new
              typeName: A
      typeAliases
        X @8
          reference: <testLibraryFragment>::@typeAlias::X
          element: <testLibrary>::@typeAlias::X
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
      constructors
        synthetic new
          firstFragment: <testLibraryFragment>::@class::A::@constructor::new
  typeAliases
    X
      firstFragment: <testLibraryFragment>::@typeAlias::X
      aliasedType: Null
''');
  }

  test_typedef_nonFunction_missingName() async {
    var library = await buildLibrary(r'''
typedef = int;
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        <null-name> (offset=8)
          reference: <testLibraryFragment>::@typeAlias::0
          element: <testLibrary>::@typeAlias::0
  typeAliases
    <null-name>
      firstFragment: <testLibraryFragment>::@typeAlias::0
      aliasedType: int
''');
  }

  test_typedef_nonFunction_using_dynamic() async {
    var library = await buildLibrary(r'''
typedef A = dynamic;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @26
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @30
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: dynamic
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: dynamic
      returnType: void
''');
  }

  test_typedef_nonFunction_using_interface_disabled() async {
    var library = await buildLibrary(r'''
// @dart = 2.12
typedef A = int;
void f(A a) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @24
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @38
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @42
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: dynamic Function()
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: dynamic Function()
            alias: <testLibrary>::@typeAlias::A
      returnType: void
''');
  }

  test_typedef_nonFunction_using_interface_noTypeParameters() async {
    var library = await buildLibrary(r'''
typedef A = int;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @22
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @26
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: int
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: int
            alias: <testLibrary>::@typeAlias::A
      returnType: void
''');
  }

  test_typedef_nonFunction_using_interface_noTypeParameters_question() async {
    var library = await buildLibrary(r'''
typedef A = int?;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @23
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @27
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: int?
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: int?
            alias: <testLibrary>::@typeAlias::A
      returnType: void
''');
  }

  test_typedef_nonFunction_using_interface_withTypeParameters() async {
    var library = await buildLibrary(r'''
typedef A<T> = Map<int, T>;
void f(A<String> a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
      functions
        f @33
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @45
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: Map<int, T>
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: Map<int, String>
            alias: <testLibrary>::@typeAlias::A
              typeArguments
                String
      returnType: void
''');
  }

  test_typedef_nonFunction_using_Never_none() async {
    var library = await buildLibrary(r'''
typedef A = Never;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @24
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @28
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: Never
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: Never
      returnType: void
''');
  }

  test_typedef_nonFunction_using_Never_question() async {
    var library = await buildLibrary(r'''
typedef A = Never?;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @25
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @29
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: Never?
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: Never?
      returnType: void
''');
  }

  test_typedef_nonFunction_using_typeParameter_none() async {
    var library = await buildLibrary(r'''
typedef A<T> = T;
void f1(A a) {}
void f2(A<int> a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
      functions
        f1 @23
          reference: <testLibraryFragment>::@function::f1
          element: <testLibrary>::@function::f1
          formalParameters
            a @28
              element: <testLibraryFragment>::@function::f1::@parameter::a#element
        f2 @39
          reference: <testLibraryFragment>::@function::f2
          element: <testLibrary>::@function::f2
          formalParameters
            a @49
              element: <testLibraryFragment>::@function::f2::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: T
  functions
    f1
      reference: <testLibrary>::@function::f1
      firstFragment: <testLibraryFragment>::@function::f1
      formalParameters
        requiredPositional a
          type: dynamic
      returnType: void
    f2
      reference: <testLibrary>::@function::f2
      firstFragment: <testLibraryFragment>::@function::f2
      formalParameters
        requiredPositional a
          type: int
            alias: <testLibrary>::@typeAlias::A
              typeArguments
                int
      returnType: void
''');
  }

  test_typedef_nonFunction_using_typeParameter_question() async {
    var library = await buildLibrary(r'''
typedef A<T> = T?;
void f1(A a) {}
void f2(A<int> a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
          typeParameters
            T @10
              element: T@10
      functions
        f1 @24
          reference: <testLibraryFragment>::@function::f1
          element: <testLibrary>::@function::f1
          formalParameters
            a @29
              element: <testLibraryFragment>::@function::f1::@parameter::a#element
        f2 @40
          reference: <testLibraryFragment>::@function::f2
          element: <testLibrary>::@function::f2
          formalParameters
            a @50
              element: <testLibraryFragment>::@function::f2::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      typeParameters
        T
      aliasedType: T?
  functions
    f1
      reference: <testLibrary>::@function::f1
      firstFragment: <testLibraryFragment>::@function::f1
      formalParameters
        requiredPositional a
          type: dynamic
      returnType: void
    f2
      reference: <testLibrary>::@function::f2
      firstFragment: <testLibraryFragment>::@function::f2
      formalParameters
        requiredPositional a
          type: int?
            alias: <testLibrary>::@typeAlias::A
              typeArguments
                int
      returnType: void
''');
  }

  test_typedef_nonFunction_using_void() async {
    var library = await buildLibrary(r'''
typedef A = void;
void f(A a) {}
''');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        A @8
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
      functions
        f @23
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
          formalParameters
            a @27
              element: <testLibraryFragment>::@function::f::@parameter::a#element
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: void
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      formalParameters
        requiredPositional a
          type: void
      returnType: void
''');
  }

  test_typedef_selfReference_recordType() async {
    var library = await buildLibrary(r'''
typedef F = (F, int) Function();
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      typeAliases
        F @8
          reference: <testLibraryFragment>::@typeAlias::F
          element: <testLibrary>::@typeAlias::F
  typeAliases
    notSimplyBounded F
      firstFragment: <testLibraryFragment>::@typeAlias::F
      aliasedType: (dynamic, int) Function()
''');
  }

  test_typedefs() async {
    var library = await buildLibrary('f() {} g() {}');
    checkElementText(library, r'''
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      functions
        f @0
          reference: <testLibraryFragment>::@function::f
          element: <testLibrary>::@function::f
        g @7
          reference: <testLibraryFragment>::@function::g
          element: <testLibrary>::@function::g
  functions
    f
      reference: <testLibrary>::@function::f
      firstFragment: <testLibraryFragment>::@function::f
      returnType: dynamic
    g
      reference: <testLibrary>::@function::g
      firstFragment: <testLibraryFragment>::@function::g
      returnType: dynamic
''');
  }
}

abstract class TypeAliasElementTest_augmentation extends ElementsBaseTest {
  test_typeAlias_augments_class() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
class A {}
''');

    configuration.withConstructors = false;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      classes
        class A @21
          reference: <testLibraryFragment>::@class::A
          enclosingElement3: <testLibraryFragment>
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
          augmentationTargetAny: <testLibraryFragment>::@class::A
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      classes
        class A @21
          reference: <testLibraryFragment>::@class::A
          element: <testLibrary>::@class::A
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  classes
    class A
      reference: <testLibrary>::@class::A
      firstFragment: <testLibraryFragment>::@class::A
  typeAliases
    A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
      aliasedType: int
''');
  }

  test_typeAlias_augments_function() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
void A() {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      functions
        A @20
          reference: <testLibraryFragment>::@function::A
          enclosingElement3: <testLibraryFragment>
          returnType: void
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
          augmentationTargetAny: <testLibraryFragment>::@function::A
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      functions
        A @20
          reference: <testLibraryFragment>::@function::A
          element: <testLibrary>::@function::A
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  typeAliases
    A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
      aliasedType: int
  functions
    A
      reference: <testLibrary>::@function::A
      firstFragment: <testLibraryFragment>::@function::A
      returnType: void
''');
  }

  test_typeAlias_augments_getter() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
int get A => 0;
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      topLevelVariables
        synthetic static A @-1
          reference: <testLibraryFragment>::@topLevelVariable::A
          enclosingElement3: <testLibraryFragment>
          type: int
      accessors
        static get A @23
          reference: <testLibraryFragment>::@getter::A
          enclosingElement3: <testLibraryFragment>
          returnType: int
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
          augmentationTargetAny: <testLibraryFragment>::@getter::A
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      topLevelVariables
        synthetic A (offset=-1)
          reference: <testLibraryFragment>::@topLevelVariable::A
          element: <testLibrary>::@topLevelVariable::A
          getter2: <testLibraryFragment>::@getter::A
      getters
        get A @23
          reference: <testLibraryFragment>::@getter::A
          element: <testLibraryFragment>::@getter::A#element
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  typeAliases
    A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
      aliasedType: int
  topLevelVariables
    synthetic A
      reference: <testLibrary>::@topLevelVariable::A
      firstFragment: <testLibraryFragment>::@topLevelVariable::A
      type: int
      getter: <testLibraryFragment>::@getter::A#element
  getters
    static get A
      firstFragment: <testLibraryFragment>::@getter::A
''');
  }

  test_typeAlias_augments_nothing() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
  exportedReferences
  exportNamespace
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  typeAliases
    A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
      aliasedType: int
  exportedReferences
  exportNamespace
''');
  }

  test_typeAlias_augments_setter() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
set A(int _) {}
''');

    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      topLevelVariables
        synthetic static A @-1
          reference: <testLibraryFragment>::@topLevelVariable::A
          enclosingElement3: <testLibraryFragment>
          type: int
      accessors
        static set A= @19
          reference: <testLibraryFragment>::@setter::A
          enclosingElement3: <testLibraryFragment>
          parameters
            requiredPositional _ @25
              type: int
          returnType: void
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
          augmentationTargetAny: <testLibraryFragment>::@setter::A
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      topLevelVariables
        synthetic A (offset=-1)
          reference: <testLibraryFragment>::@topLevelVariable::A
          element: <testLibrary>::@topLevelVariable::A
          setter2: <testLibraryFragment>::@setter::A
      setters
        set A @19
          reference: <testLibraryFragment>::@setter::A
          element: <testLibraryFragment>::@setter::A#element
          formalParameters
            _ @25
              element: <testLibraryFragment>::@setter::A::@parameter::_#element
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  typeAliases
    A
      firstFragment: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
      aliasedType: int
  topLevelVariables
    synthetic A
      reference: <testLibrary>::@topLevelVariable::A
      firstFragment: <testLibraryFragment>::@topLevelVariable::A
      type: int
      setter: <testLibraryFragment>::@setter::A#element
  setters
    static set A
      firstFragment: <testLibraryFragment>::@setter::A
      formalParameters
        requiredPositional _
          type: int
''');
  }

  test_typeAlias_augments_typeAlias() async {
    newFile('$testPackageLibPath/a.dart', r'''
part of 'test.dart';
augment typedef A = int;
''');

    var library = await buildLibrary(r'''
part 'a.dart';
typedef A = int;
''');

    configuration.withExportScope = true;
    checkElementText(library, r'''
library
  reference: <testLibrary>
  definingUnit: <testLibraryFragment>
  units
    <testLibraryFragment>
      enclosingElement3: <null>
      parts
        part_0
          uri: package:test/a.dart
          enclosingElement3: <testLibraryFragment>
          unit: <testLibrary>::@fragment::package:test/a.dart
      typeAliases
        A @23
          reference: <testLibraryFragment>::@typeAlias::A
          aliasedType: int
          augmentation: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
    <testLibrary>::@fragment::package:test/a.dart
      enclosingElement3: <testLibraryFragment>
      typeAliases
        augment notSimplyBounded A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          aliasedType: int
          augmentationTarget: <testLibraryFragment>::@typeAlias::A
  exportedReferences
    declared <testLibraryFragment>::@typeAlias::A
  exportNamespace
    A: <testLibraryFragment>::@typeAlias::A
----------------------------------------
library
  reference: <testLibrary>
  fragments
    <testLibraryFragment>
      element: <testLibrary>
      nextFragment: <testLibrary>::@fragment::package:test/a.dart
      typeAliases
        A @23
          reference: <testLibraryFragment>::@typeAlias::A
          element: <testLibrary>::@typeAlias::A
    <testLibrary>::@fragment::package:test/a.dart
      element: <testLibrary>
      enclosingFragment: <testLibraryFragment>
      previousFragment: <testLibraryFragment>
      typeAliases
        A @37
          reference: <testLibrary>::@fragment::package:test/a.dart::@typeAliasAugmentation::A
          element: <testLibrary>::@typeAlias::A
  typeAliases
    A
      firstFragment: <testLibraryFragment>::@typeAlias::A
      aliasedType: int
  exportedReferences
    declared <testLibraryFragment>::@typeAlias::A
  exportNamespace
    A: <testLibraryFragment>::@typeAlias::A
''');
  }
}

@reflectiveTest
class TypeAliasElementTest_augmentation_fromBytes
    extends TypeAliasElementTest_augmentation {
  @override
  bool get keepLinkingLibraries => false;
}

@reflectiveTest
class TypeAliasElementTest_augmentation_keepLinking
    extends TypeAliasElementTest_augmentation {
  @override
  bool get keepLinkingLibraries => true;
}

@reflectiveTest
class TypeAliasElementTest_fromBytes extends TypeAliasElementTest {
  @override
  bool get keepLinkingLibraries => false;
}

@reflectiveTest
class TypeAliasElementTest_keepLinking extends TypeAliasElementTest {
  @override
  bool get keepLinkingLibraries => true;
}
