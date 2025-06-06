// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'masks.dart';

class ValueTypeMask extends ForwardingTypeMask {
  /// Tag used for identifying serialized [ValueTypeMask] objects in a
  /// debugging data stream.
  static const String tag = 'value-type-mask';

  @override
  final TypeMask forwardTo;
  final PrimitiveConstantValue value;

  const ValueTypeMask(this.forwardTo, this.value);

  /// Deserializes a [ValueTypeMask] object from [source].
  factory ValueTypeMask.readFromDataSource(
    DataSourceReader source,
    CommonMasks domain,
  ) {
    source.begin(tag);
    TypeMask forwardTo = TypeMask.readFromDataSource(source, domain);
    final constant = source.readConstant() as PrimitiveConstantValue;
    source.end(tag);
    return ValueTypeMask(forwardTo, constant);
  }

  /// Serializes this [ValueTypeMask] to [sink].
  @override
  void writeToDataSink(DataSinkWriter sink) {
    sink.writeEnum(TypeMaskKind.value);
    sink.begin(tag);
    forwardTo.writeToDataSink(sink);
    sink.writeConstant(value);
    sink.end(tag);
  }

  @override
  ValueTypeMask withPowerset(Bitset powerset, CommonMasks domain) {
    if (powerset == this.powerset) return this;
    return ValueTypeMask(forwardTo.withPowerset(powerset, domain), value);
  }

  @override
  TypeMask? _unionSpecialCases(
    TypeMask other,
    CommonMasks domain,
    Bitset powerset,
  ) {
    if (other is ValueTypeMask &&
        forwardTo.withoutSpecialValues(domain) ==
            other.forwardTo.withoutSpecialValues(domain) &&
        value == other.value) {
      return withPowerset(powerset, domain);
    }
    return null;
  }

  @override
  bool operator ==(other) {
    if (identical(this, other)) return true;
    if (other is! ValueTypeMask) return false;
    return super == other && value == other.value;
  }

  @override
  int get hashCode => Hashing.objectHash(value, super.hashCode);

  @override
  String toString() {
    return 'Value($forwardTo, value: ${value.toDartText(null)}, '
        'powerset: ${TypeMask.powersetToString(powerset)})';
  }
}
