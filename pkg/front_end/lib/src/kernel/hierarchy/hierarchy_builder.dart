// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchyBase, ClassHierarchyExtensionTypeMixin;
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/src/types.dart' show Types;
import 'package:kernel/type_algebra.dart' show Substitution, uniteNullabilities;

import '../../base/loader.dart' show Loader;
import '../../builder/declaration_builders.dart';
import '../../source/source_class_builder.dart';
import '../../source/source_extension_type_declaration_builder.dart';
import '../../source/source_loader.dart' show SourceLoader;
import 'hierarchy_node.dart';

class ClassHierarchyBuilder
    with ClassHierarchyExtensionTypeMixin
    implements ClassHierarchyBase {
  final Map<Class, ClassHierarchyNode> classNodes = {};

  final Map<ExtensionTypeDeclaration, ExtensionTypeHierarchyNode>
      extensionTypeNodes = {};

  final ClassBuilder objectClassBuilder;

  final Loader loader;

  final Class objectClass;

  final Class futureClass;

  final Class functionClass;

  @override
  final CoreTypes coreTypes;

  late Types types;

  ClassHierarchyBuilder(this.objectClassBuilder, this.loader, this.coreTypes)
      : objectClass = objectClassBuilder.cls,
        futureClass = coreTypes.futureClass,
        functionClass = coreTypes.functionClass {
    types = new Types(this);
  }

  void clear() {
    classNodes.clear();
    extensionTypeNodes.clear();
  }

  ClassHierarchyNode getNodeFromClassBuilder(ClassBuilder classBuilder) {
    return classNodes[classBuilder.cls] ??=
        new ClassHierarchyNodeBuilder(this, classBuilder).build();
  }

  ClassHierarchyNode getNodeFromClass(Class cls) {
    return classNodes[cls] ??
        getNodeFromClassBuilder(loader.computeClassBuilderFromTargetClass(cls));
  }

  ExtensionTypeHierarchyNode getNodeFromExtensionTypeDeclarationBuilder(
      ExtensionTypeDeclarationBuilder extensionTypeBuilder) {
    return extensionTypeNodes[extensionTypeBuilder.extensionTypeDeclaration] ??=
        new ExtensionTypeHierarchyNodeBuilder(this, extensionTypeBuilder)
            .build();
  }

  ExtensionTypeHierarchyNode getNodeFromExtensionType(
      ExtensionTypeDeclaration extensionType) {
    return extensionTypeNodes[extensionType] ??
        getNodeFromExtensionTypeDeclarationBuilder(loader
            .computeExtensionTypeBuilderFromTargetExtensionType(extensionType));
  }

  Supertype? asSupertypeOf(InterfaceType subtype, Class supertype) {
    if (subtype.classNode == supertype) {
      // Coverage-ignore-block(suite): Not run.
      return new Supertype(supertype, subtype.typeArguments);
    }
    Supertype? cls = getClassAsInstanceOf(subtype.classNode, supertype);
    if (cls != null) {
      return Substitution.fromInterfaceType(subtype).substituteSupertype(cls);
    }
    return null;
  }

  @override
  Supertype? getClassAsInstanceOf(Class subclass, Class superclass) {
    if (identical(subclass, superclass)) return subclass.asThisSupertype;
    ClassHierarchyNode clsNode = getNodeFromClass(subclass);
    ClassHierarchyNode supertypeNode = getNodeFromClass(superclass);
    List<Supertype> superclasses = clsNode.superclasses;
    int depth = supertypeNode.depth;
    if (depth < superclasses.length) {
      Supertype cls = superclasses[depth];
      if (cls.classNode == superclass) {
        return cls;
      }
    }
    List<Supertype> superinterfaces = clsNode.interfaces;
    for (int i = 0; i < superinterfaces.length; i++) {
      Supertype interface = superinterfaces[i];
      if (interface.classNode == superclass) {
        return interface;
      }
    }
    return null;
  }

  @override
  InterfaceType? getInterfaceTypeAsInstanceOfClass(
      InterfaceType type, Class superclass) {
    if (type.classNode == superclass) return type;
    return asSupertypeOf(type, superclass)
        ?.asInterfaceType
        .withDeclaredNullability(type.nullability);
  }

  @override
  List<DartType>? getInterfaceTypeArgumentsAsInstanceOfClass(
      InterfaceType type, Class superclass) {
    if (type.classReference == superclass.reference) return type.typeArguments;
    return asSupertypeOf(type, superclass)?.typeArguments;
  }

  @override
  // Coverage-ignore(suite): Not run.
  bool isSubInterfaceOf(Class subtype, Class superclass) {
    return getClassAsInstanceOf(subtype, superclass) != null;
  }

  // Coverage-ignore(suite): Not run.
  InterfaceType _getLegacyLeastUpperBoundInternal(
      TypeDeclarationType type1,
      TypeDeclarationType type2,
      List<ClassHierarchyNode> supertypeNodes1,
      List<ClassHierarchyNode> supertypeNodes2) {
    Set<ClassHierarchyNode> supertypeNodesSet1 = supertypeNodes1.toSet();
    List<ClassHierarchyNode> common = <ClassHierarchyNode>[];

    for (int i = 0; i < supertypeNodes2.length; i++) {
      ClassHierarchyNode node = supertypeNodes2[i];
      if (node.classBuilder.cls.isAnonymousMixin) {
        // Never find unnamed mixin application in least upper bound.
        continue;
      }
      if (supertypeNodesSet1.contains(node)) {
        DartType candidate1 =
            getTypeAsInstanceOf(type1, node.classBuilder.cls)!;
        DartType candidate2 =
            getTypeAsInstanceOf(type2, node.classBuilder.cls)!;
        if (candidate1 == candidate2) {
          common.add(node);
        }
      }
    }

    if (common.length == 1) {
      assert(common.single.classBuilder.cls == coreTypes.objectClass);
      if (type1 is ExtensionType && type1.isPotentiallyNullable ||
          type2 is ExtensionType && type2.isPotentiallyNullable) {
        return coreTypes.objectNullableRawType;
      } else {
        return coreTypes.objectRawType(
            uniteNullabilities(type1.nullability, type2.nullability));
      }
    }
    common.sort(ClassHierarchyNode.compareMaxInheritancePath);

    for (int i = 0; i < common.length - 1; i++) {
      ClassHierarchyNode node = common[i];
      if (node.maxInheritancePath != common[i + 1].maxInheritancePath) {
        return getTypeAsInstanceOf(type1, node.classBuilder.cls)!
                .withDeclaredNullability(
                    uniteNullabilities(type1.nullability, type2.nullability))
            as InterfaceType;
      } else {
        do {
          i++;
        } while (node.maxInheritancePath == common[i + 1].maxInheritancePath);
      }
    }
    if (type1 is ExtensionType && type1.isPotentiallyNullable ||
        type2 is ExtensionType && type2.isPotentiallyNullable) {
      return coreTypes.objectNullableRawType;
    } else {
      return coreTypes.objectRawType(
          uniteNullabilities(type1.nullability, type2.nullability));
    }
  }

  @override
  // Coverage-ignore(suite): Not run.
  InterfaceType getLegacyLeastUpperBound(
      InterfaceType type1, InterfaceType type2) {
    if (type1 == type2) return type1;

    return getLegacyLeastUpperBoundFromSupertypeLists(
        type1, type2, <InterfaceType>[type1], <InterfaceType>[type2]);
  }

  @override
  // Coverage-ignore(suite): Not run.
  InterfaceType getLegacyLeastUpperBoundFromSupertypeLists(
      TypeDeclarationType type1,
      TypeDeclarationType type2,
      List<InterfaceType> supertypes1,
      List<InterfaceType> supertypes2) {
    List<ClassHierarchyNode> supertypeNodes1 = <ClassHierarchyNode>[
      for (InterfaceType supertype in supertypes1)
        ...getNodeFromClass(supertype.classNode).computeAllSuperNodes(this)
    ];
    List<ClassHierarchyNode> supertypeNodes2 = <ClassHierarchyNode>[
      for (InterfaceType supertype in supertypes2)
        ...getNodeFromClass(supertype.classNode).computeAllSuperNodes(this)
    ];

    return _getLegacyLeastUpperBoundInternal(
        type1, type2, supertypeNodes1, supertypeNodes2);
  }

  static ClassHierarchyBuilder build(
      ClassBuilder objectClass,
      List<SourceClassBuilder> classes,
      List<SourceExtensionTypeDeclarationBuilder> extensionTypes,
      SourceLoader loader,
      CoreTypes coreTypes) {
    ClassHierarchyBuilder hierarchy =
        new ClassHierarchyBuilder(objectClass, loader, coreTypes);
    for (int i = 0; i < classes.length; i++) {
      SourceClassBuilder classBuilder = classes[i];
      hierarchy.classNodes[classBuilder.cls] =
          new ClassHierarchyNodeBuilder(hierarchy, classBuilder).build();
    }
    for (int i = 0; i < extensionTypes.length; i++) {
      SourceExtensionTypeDeclarationBuilder extensionTypeBuilder =
          extensionTypes[i];
      hierarchy.extensionTypeNodes[
              extensionTypeBuilder.extensionTypeDeclaration] =
          new ExtensionTypeHierarchyNodeBuilder(hierarchy, extensionTypeBuilder)
              .build();
    }
    return hierarchy;
  }
}
