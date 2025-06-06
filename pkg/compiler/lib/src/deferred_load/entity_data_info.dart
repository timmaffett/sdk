// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart' as ir;

import 'entity_data.dart';

import '../common.dart';
import '../common/elements.dart' show CommonElements, KElementEnvironment;
import '../compiler.dart' show Compiler;
import '../constants/values.dart'
    show ConstantValue, ConstructedConstantValue, InstantiationConstantValue;
import '../elements/entities.dart';
import '../elements/types.dart';
import '../ir/util.dart';
import '../kernel/element_map.dart';
import '../kernel/kernel_world.dart' show KClosedWorld;
import '../js_model/elements.dart' show JLocalFunction;
import '../universe/use.dart';
import '../universe/world_impact.dart' show WorldImpact;

/// [EntityDataInfo] is meta data about [EntityData] for a given compilation
/// [Entity].
class EntityDataInfo {
  /// The deferred [EntityData] roots collected by the collector.
  final Map<EntityData, List<ImportEntity>> deferredRoots = {};

  /// The direct [EntityData] collected by the collector.
  final Set<EntityData> directDependencies = {};

  /// Various [add] methods for various types of direct dependencies.
  void add(EntityData entityData, {ImportEntity? import}) {
    // If we already have a direct dependency on [entityData] then we have
    // nothing left to do.
    if (directDependencies.contains(entityData)) return;

    // If [import] is null, then create a direct dependency on [entityData] and
    // remove any deferred roots. Otherwise, add [import] to [deferredRoots] for
    // [entityData].
    if (import == null) {
      deferredRoots.remove(entityData);
      directDependencies.add(entityData);
    } else {
      (deferredRoots[entityData] ??= []).add(import);
    }
  }
}

/// Builds [EntityDataInfo] to help update dependencies of [EntityData] in the
/// deferred_load algorithm.
class EntityDataInfoBuilder {
  final EntityDataInfo info = EntityDataInfo();
  final KClosedWorld closedWorld;
  final KernelToElementMap elementMap;
  final Compiler compiler;
  final EntityDataRegistry registry;

  EntityDataInfoBuilder(
    this.closedWorld,
    this.elementMap,
    this.compiler,
    this.registry,
  );

  Map<Entity, WorldImpact> get impactCache => compiler.impactCache;
  KElementEnvironment get elementEnvironment =>
      compiler.frontendStrategy.elementEnvironment;
  CommonElements get commonElements => compiler.frontendStrategy.commonElements;

  void add(EntityData data, {ImportEntity? import}) {
    info.add(data, import: import);
  }

  void addClass(ClassEntity cls, {ImportEntity? import}) {
    add(registry.createClassEntityData(cls), import: import);

    // Add a classType entityData as well just in case we optimize out
    // the class later.
    addClassType(cls, import: import);
  }

  void addClassType(ClassEntity cls, {ImportEntity? import}) {
    add(registry.createClassTypeEntityData(cls), import: import);
  }

  void addMember(MemberEntity m, {ImportEntity? import}) {
    add(registry.createMemberEntityData(m), import: import);
  }

  void addConstant(ConstantValue c, {ImportEntity? import}) {
    add(registry.createConstantEntityData(c), import: import);
  }

  void addLocalFunction(Local localFunction) {
    add(registry.createLocalFunctionEntityData(localFunction));
  }

  /// Recursively collects all the dependencies of [type].
  void addTypeDependencies(DartType type, [ImportEntity? import]) {
    TypeEntityDataVisitor(this, import, commonElements).visit(type);
  }

  /// Recursively collects all the dependencies of [types].
  void addTypeListDependencies(
    Iterable<DartType>? types, [
    ImportEntity? import,
  ]) {
    if (types == null) return;
    TypeEntityDataVisitor(this, import, commonElements).visitIterable(types);
  }

  /// Collects all direct dependencies of [element].
  ///
  /// The collected dependent elements and constants are added to
  /// [elements] and [constants] respectively.
  void addDirectMemberDependencies(MemberEntity element) {
    // TODO(sigurdm): We want to be more specific about this - need a better
    // way to query "liveness".
    if (!closedWorld.isMemberUsed(element)) {
      return;
    }
    _addDependenciesFromEntityImpact(element);
    ConstantCollector.collect(elementMap, element, this);
  }

  void _addFromStaticUse(MemberEntity? parent, StaticUse staticUse) {
    void processEntity() {
      Entity usedEntity = staticUse.element;
      if (usedEntity is MemberEntity) {
        addMember(usedEntity, import: staticUse.deferredImport);
      } else {
        assert(
          usedEntity is JLocalFunction,
          failedAt(usedEntity, "Unexpected static use $staticUse."),
        );
        var localFunction = usedEntity as JLocalFunction;
        // TODO(sra): Consult KClosedWorld to see if signature is needed.
        addTypeDependencies(localFunction.functionType);
        addLocalFunction(localFunction);
      }
    }

    switch (staticUse.kind) {
      case StaticUseKind.constructorInvoke:
      case StaticUseKind.constConstructorInvoke:
        // The receiver type of generative constructors is a entityData of
        // the constructor (handled by `addMember` above) and not a
        // entityData at the call site.
        // Factory methods, on the other hand, are like static methods so
        // the target type is not relevant.
        // TODO(johnniwinther): Use rti need data to skip unneeded type
        // arguments.
        addTypeListDependencies(staticUse.type!.typeArguments);
        processEntity();
        break;
      case StaticUseKind.staticInvoke:
      case StaticUseKind.closureCall:
      case StaticUseKind.directInvoke:
        // TODO(johnniwinther): Use rti need data to skip unneeded type
        // arguments.
        addTypeListDependencies(staticUse.typeArguments);
        processEntity();
        break;
      case StaticUseKind.staticTearOff:
      case StaticUseKind.closure:
      case StaticUseKind.staticGet:
      case StaticUseKind.staticSet:
      case StaticUseKind.weakStaticTearOff:
        processEntity();
        break;
      case StaticUseKind.superTearOff:
      case StaticUseKind.superFieldSet:
      case StaticUseKind.superGet:
      case StaticUseKind.superSetterSet:
      case StaticUseKind.superInvoke:
      case StaticUseKind.instanceFieldGet:
      case StaticUseKind.instanceFieldSet:
      case StaticUseKind.fieldInit:
      case StaticUseKind.fieldConstantInit:
        // These static uses are not relevant for this algorithm.
        break;
      case StaticUseKind.callMethod:
      case StaticUseKind.inlining:
        failedAt(parent!, "Unexpected static use: $staticUse.");
    }
  }

  void _addFromTypeUse(MemberEntity? parent, TypeUse typeUse) {
    void addClassIfInterfaceType(DartType t, [ImportEntity? import]) {
      var typeWithoutNullability = t.withoutNullability;
      if (typeWithoutNullability is InterfaceType) {
        addClass(typeWithoutNullability.element, import: import);
      }
    }

    DartType type = typeUse.type;
    switch (typeUse.kind) {
      case TypeUseKind.typeLiteral:
        addTypeDependencies(type, typeUse.deferredImport);
        break;
      case TypeUseKind.constInstantiation:
        addClassIfInterfaceType(type, typeUse.deferredImport);
        addTypeDependencies(type, typeUse.deferredImport);
        break;
      case TypeUseKind.instantiation:
      case TypeUseKind.nativeInstantiation:
      case TypeUseKind.recordInstantiation:
        addClassIfInterfaceType(type);
        addTypeDependencies(type);
        break;
      case TypeUseKind.isCheck:
      case TypeUseKind.catchType:
        addTypeDependencies(type);
        break;
      case TypeUseKind.asCast:
        if (closedWorld.annotationsData
            .getExplicitCastCheckPolicy(parent)
            .isEmitted) {
          addTypeDependencies(type);
        }
        break;
      case TypeUseKind.implicitCast:
        if (closedWorld.annotationsData
            .getImplicitDowncastCheckPolicy(parent)
            .isEmitted) {
          addTypeDependencies(type);
        }
        break;
      case TypeUseKind.parameterCheck:
      case TypeUseKind.typeVariableBoundCheck:
        if (closedWorld.annotationsData
            .getParameterCheckPolicy(parent)
            .isEmitted) {
          addTypeDependencies(type);
        }
        break;
      case TypeUseKind.rtiValue:
      case TypeUseKind.typeArgument:
      case TypeUseKind.namedTypeVariable:
      case TypeUseKind.constructorReference:
        failedAt(parent!, "Unexpected type use: $typeUse.");
    }
  }

  void _addFromConditionalUse(ConditionalUse conditionalUse) {
    if (conditionalUse.originalConditions.any(closedWorld.isMemberUsed)) {
      _addDependenciesFromImpact(conditionalUse.impact);
    } else {
      final replacementImpact = conditionalUse.replacementImpact;
      if (replacementImpact != null) {
        _addDependenciesFromImpact(replacementImpact);
      }
    }
  }

  void _addDependenciesFromImpact(WorldImpact worldImpact) {
    worldImpact.forEachStaticUse(_addFromStaticUse);
    worldImpact.forEachTypeUse(_addFromTypeUse);
    worldImpact.forEachConditionalUse((_, use) => _addFromConditionalUse(use));

    // TODO(johnniwinther): Use rti need data to skip unneeded type
    // arguments.
    worldImpact.forEachDynamicUse(
      (_, use) => addTypeListDependencies(use.typeArguments),
    );
  }

  /// Extract any dependencies that are known from the impact of [element].
  void _addDependenciesFromEntityImpact(MemberEntity element) {
    _addDependenciesFromImpact(impactCache[element]!);
  }
}

/// Collects the necessary [EntityDataInfo] for a given [EntityData].
class EntityDataInfoVisitor extends EntityDataVisitor {
  final EntityDataInfoBuilder infoBuilder;

  EntityDataInfoVisitor(this.infoBuilder);

  KClosedWorld get closedWorld => infoBuilder.closedWorld;
  KElementEnvironment get elementEnvironment =>
      infoBuilder.compiler.frontendStrategy.elementEnvironment;

  /// Finds all elements and constants that [element] depends directly on.
  /// (not the transitive closure.)
  ///
  /// Adds the results to [elements] and [constants].
  @override
  void visitClassEntityData(ClassEntity element) {
    // If we see a class, add everything its live instance members refer
    // to.  Static members are not relevant, unless we are processing
    // extra dependencies due to mirrors.
    void addLiveInstanceMember(MemberEntity member) {
      if (!closedWorld.isMemberUsed(member)) return;
      if (!member.isInstanceMember) return;
      infoBuilder.addMember(member);
      infoBuilder.addDirectMemberDependencies(member);
    }

    void addClassAndMaybeAddEffectiveMixinClass(ClassEntity cls) {
      infoBuilder.addClass(cls);
      if (elementEnvironment.isMixinApplication(cls)) {
        infoBuilder.addClass(elementEnvironment.getEffectiveMixinClass(cls)!);
      }
    }

    ClassEntity cls = element;
    elementEnvironment.forEachLocalClassMember(cls, addLiveInstanceMember);
    elementEnvironment.forEachSupertype(cls, (InterfaceType type) {
      infoBuilder.addTypeDependencies(type);
    });
    elementEnvironment.forEachSuperClass(cls, (superClass) {
      addClassAndMaybeAddEffectiveMixinClass(superClass);
      infoBuilder.addTypeDependencies(
        elementEnvironment.getThisType(superClass),
      );
    });
    addClassAndMaybeAddEffectiveMixinClass(cls);
  }

  @override
  void visitClassTypeEntityData(ClassEntity element) {
    infoBuilder.addClassType(element);
  }

  /// Finds all elements and constants that [element] depends directly on.
  /// (not the transitive closure.)
  ///
  /// Adds the results to [elements] and [constants].
  @override
  void visitMemberEntityData(MemberEntity element) {
    if (element is FunctionEntity) {
      infoBuilder.addTypeDependencies(
        elementEnvironment.getFunctionType(element),
      );
    }
    if (element.isStatic ||
        element.isTopLevel ||
        element is ConstructorEntity) {
      infoBuilder.addMember(element);
      infoBuilder.addDirectMemberDependencies(element);
    }
    if (element is ConstructorEntity && element.isGenerativeConstructor) {
      // When instantiating a class, we record a reference to the
      // constructor, not the class itself.  We must add all the
      // instance members of the constructor's class.
      ClassEntity cls = element.enclosingClass;
      visitClassEntityData(cls);
    }

    // Other elements, in particular instance members, are ignored as
    // they are processed as part of the class.
  }

  @override
  void visitConstantEntityData(ConstantValue constant) {
    if (constant is ConstructedConstantValue) {
      infoBuilder.addClass(constant.type.element);
    }
    if (constant is InstantiationConstantValue) {
      for (DartType type in constant.typeArguments) {
        type = type.withoutNullability;
        if (type is InterfaceType) {
          infoBuilder.addClass(type.element);
        }
      }
    }

    // TODO(51016): Track shapes of RecordConstantValue constants.

    // Constants are not allowed to refer to deferred constants, so
    // no need to check for a deferred type literal here.
    constant.getDependencies().forEach(infoBuilder.addConstant);
  }
}

class TypeEntityDataVisitor implements DartTypeVisitor<void, Null> {
  final EntityDataInfoBuilder _infoBuilder;
  final ImportEntity? _import;
  final CommonElements _commonElements;

  TypeEntityDataVisitor(this._infoBuilder, this._import, this._commonElements);

  @override
  void visit(DartType type, [_]) {
    type.accept(this, null);
  }

  void visitIterable(Iterable<DartType> types) {
    types.forEach(visit);
  }

  @override
  void visitNullableType(NullableType type, Null argument) {
    visit(type.baseType);
  }

  @override
  void visitFutureOrType(FutureOrType type, Null argument) {
    _infoBuilder.addClassType(_commonElements.futureClass);
    visit(type.typeArgument);
  }

  @override
  void visitNeverType(NeverType type, Null argument) {
    // Nothing to add.
  }

  @override
  void visitDynamicType(DynamicType type, Null argument) {
    // Nothing to add.
  }

  @override
  void visitErasedType(ErasedType type, Null argument) {
    // Nothing to add.
  }

  @override
  void visitAnyType(AnyType type, Null argument) {
    // Nothing to add.
  }

  @override
  void visitInterfaceType(InterfaceType type, Null argument) {
    visitIterable(type.typeArguments);
    _infoBuilder.addClassType(type.element, import: _import);
  }

  @override
  void visitRecordType(RecordType type, Null argument) {
    visitIterable(type.fields);
    // TODO(49718): Deferred loading could track record types to ensure that the
    // shape predicate attached to the Rti for a shape (instanceof SomeClass)
    // has access to the shape class.
  }

  @override
  void visitFunctionType(FunctionType type, Null argument) {
    for (FunctionTypeVariable typeVariable in type.typeVariables) {
      visit(typeVariable.bound);
    }
    visitIterable(type.parameterTypes);
    visitIterable(type.optionalParameterTypes);
    visitIterable(type.namedParameterTypes);
    visit(type.returnType);
  }

  @override
  void visitFunctionTypeVariable(FunctionTypeVariable type, Null argument) {
    // Nothing to add. Handled in [visitFunctionType].
  }

  @override
  void visitTypeVariableType(TypeVariableType type, Null argument) {
    // TODO(johnniwinther): Do we need to collect the bound?
  }

  @override
  void visitVoidType(VoidType type, Null argument) {
    // Nothing to add.
  }
}

class ConstantCollector extends ir.RecursiveVisitor {
  final KernelToElementMap elementMap;
  final EntityDataInfoBuilder infoBuilder;

  ConstantCollector(this.elementMap, this.infoBuilder);

  CommonElements get commonElements => elementMap.commonElements;

  /// Extract the set of constants that are used in the body of [member].
  static void collect(
    KernelToElementMap elementMap,
    MemberEntity member,
    EntityDataInfoBuilder infoBuilder,
  ) {
    ir.Member node = elementMap.getMemberNode(member);

    // Fetch the internal node in order to skip annotations on the member.
    // TODO(sigmund): replace this pattern when the kernel-ast provides a better
    // way to skip annotations (issue 31565).
    var visitor = ConstantCollector(elementMap, infoBuilder);
    if (node is ir.Field) {
      node.initializer?.accept(visitor);
      return;
    }

    if (node is ir.Constructor) {
      for (var i in node.initializers) {
        i.accept(visitor);
      }
    }
    node.function?.accept(visitor);
  }

  void add(ir.Expression node, {bool requireConstant = true}) {
    ConstantValue? constant = elementMap.getConstantValue(
      node,
      requireConstant: requireConstant,
    );
    if (constant != null) {
      infoBuilder.addConstant(
        constant,
        import: elementMap.getImport(getDeferredImport(node)),
      );
    }
  }

  @override
  void visitIntLiteral(ir.IntLiteral node) {}

  @override
  void visitDoubleLiteral(ir.DoubleLiteral node) {}

  @override
  void visitBoolLiteral(ir.BoolLiteral node) {}

  @override
  void visitStringLiteral(ir.StringLiteral node) {}

  @override
  void visitSymbolLiteral(ir.SymbolLiteral node) => add(node);

  @override
  void visitNullLiteral(ir.NullLiteral node) {}

  @override
  void visitListLiteral(ir.ListLiteral node) {
    if (node.isConst) {
      add(node);
    } else {
      super.visitListLiteral(node);
    }
  }

  @override
  void visitSetLiteral(ir.SetLiteral node) {
    if (node.isConst) {
      add(node);
    } else {
      super.visitSetLiteral(node);
    }
  }

  @override
  void visitMapLiteral(ir.MapLiteral node) {
    if (node.isConst) {
      add(node);
    } else {
      super.visitMapLiteral(node);
    }
  }

  @override
  void visitRecordLiteral(ir.RecordLiteral node) {
    if (node.isConst) {
      add(node);
    } else {
      super.visitRecordLiteral(node);
    }
  }

  @override
  void visitConstructorInvocation(ir.ConstructorInvocation node) {
    if (node.isConst) {
      add(node);
    } else {
      super.visitConstructorInvocation(node);
    }
  }

  @override
  void visitTypeParameter(ir.TypeParameter node) {
    // We avoid visiting metadata on the type parameter declaration. The bound
    // cannot hold constants so we skip that as well.
  }

  @override
  void visitVariableDeclaration(ir.VariableDeclaration node) {
    // We avoid visiting metadata on the parameter declaration by only visiting
    // the initializer. The type cannot hold constants so can kan skip that
    // as well.
    node.initializer?.accept(this);
  }

  @override
  void visitTypeLiteral(ir.TypeLiteral node) {
    // Type literals may be [ir.TypeParameterType] or contain TypeParameterType
    // variables nested within (e.g. in a generic type literals). As such,
    // we can't assume that all type literals are constant.
    add(node, requireConstant: false);
  }

  @override
  void visitInstantiation(ir.Instantiation node) {
    // TODO(johnniwinther): The CFE should mark constant instantiations as
    // constant.
    add(node, requireConstant: false);
    super.visitInstantiation(node);
  }

  @override
  void visitConstantExpression(ir.ConstantExpression node) {
    add(node);
  }
}
