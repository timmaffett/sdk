// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// This file has been automatically generated. Please do not edit it manually.
// Generated by tests/ffi/generator/structs_by_value_tests_generator.dart.

import 'dart:ffi';

final class Struct1ByteBool extends Struct {
  @Bool()
  external bool a0;

  String toString() => "(${a0})";
}

final class Struct1ByteInt extends Struct {
  @Int8()
  external int a0;

  String toString() => "(${a0})";
}

final class Struct3BytesHomogeneousUint8 extends Struct {
  @Uint8()
  external int a0;

  @Uint8()
  external int a1;

  @Uint8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct3BytesInt2ByteAligned extends Struct {
  @Int16()
  external int a0;

  @Int8()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct4BytesHomogeneousInt16 extends Struct {
  @Int16()
  external int a0;

  @Int16()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct4BytesFloat extends Struct {
  @Float()
  external double a0;

  String toString() => "(${a0})";
}

final class Struct7BytesHomogeneousUint8 extends Struct {
  @Uint8()
  external int a0;

  @Uint8()
  external int a1;

  @Uint8()
  external int a2;

  @Uint8()
  external int a3;

  @Uint8()
  external int a4;

  @Uint8()
  external int a5;

  @Uint8()
  external int a6;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6})";
}

final class Struct7BytesInt4ByteAligned extends Struct {
  @Int32()
  external int a0;

  @Int16()
  external int a1;

  @Int8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct8BytesInt extends Struct {
  @Int16()
  external int a0;

  @Int16()
  external int a1;

  @Int32()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct8BytesHomogeneousFloat extends Struct {
  @Float()
  external double a0;

  @Float()
  external double a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct8BytesFloat extends Struct {
  @Double()
  external double a0;

  String toString() => "(${a0})";
}

final class Struct8BytesMixed extends Struct {
  @Float()
  external double a0;

  @Int16()
  external int a1;

  @Int16()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct9BytesHomogeneousUint8 extends Struct {
  @Uint8()
  external int a0;

  @Uint8()
  external int a1;

  @Uint8()
  external int a2;

  @Uint8()
  external int a3;

  @Uint8()
  external int a4;

  @Uint8()
  external int a5;

  @Uint8()
  external int a6;

  @Uint8()
  external int a7;

  @Uint8()
  external int a8;

  String toString() =>
      "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6}, ${a7}, ${a8})";
}

final class Struct9BytesInt4Or8ByteAligned extends Struct {
  @Int64()
  external int a0;

  @Int8()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct10BytesHomogeneousBool extends Struct {
  @Bool()
  external bool a0;

  @Bool()
  external bool a1;

  @Bool()
  external bool a2;

  @Bool()
  external bool a3;

  @Bool()
  external bool a4;

  @Bool()
  external bool a5;

  @Bool()
  external bool a6;

  @Bool()
  external bool a7;

  @Bool()
  external bool a8;

  @Bool()
  external bool a9;

  String toString() =>
      "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6}, ${a7}, ${a8}, ${a9})";
}

final class Struct12BytesHomogeneousFloat extends Struct {
  @Float()
  external double a0;

  @Float()
  external double a1;

  @Float()
  external double a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct12BytesHomogeneousInt32 extends Struct {
  @Int32()
  external int a0;

  @Int32()
  external int a1;

  @Int32()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct16BytesHomogeneousFloat extends Struct {
  @Float()
  external double a0;

  @Float()
  external double a1;

  @Float()
  external double a2;

  @Float()
  external double a3;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3})";
}

final class Struct16BytesMixed extends Struct {
  @Double()
  external double a0;

  @Int64()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct16BytesMixed2 extends Struct {
  @Float()
  external double a0;

  @Float()
  external double a1;

  @Float()
  external double a2;

  @Int32()
  external int a3;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3})";
}

final class Struct17BytesInt extends Struct {
  @Int64()
  external int a0;

  @Int64()
  external int a1;

  @Int8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct19BytesHomogeneousUint8 extends Struct {
  @Uint8()
  external int a0;

  @Uint8()
  external int a1;

  @Uint8()
  external int a2;

  @Uint8()
  external int a3;

  @Uint8()
  external int a4;

  @Uint8()
  external int a5;

  @Uint8()
  external int a6;

  @Uint8()
  external int a7;

  @Uint8()
  external int a8;

  @Uint8()
  external int a9;

  @Uint8()
  external int a10;

  @Uint8()
  external int a11;

  @Uint8()
  external int a12;

  @Uint8()
  external int a13;

  @Uint8()
  external int a14;

  @Uint8()
  external int a15;

  @Uint8()
  external int a16;

  @Uint8()
  external int a17;

  @Uint8()
  external int a18;

  String toString() =>
      "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6}, ${a7}, ${a8}, ${a9}, ${a10}, ${a11}, ${a12}, ${a13}, ${a14}, ${a15}, ${a16}, ${a17}, ${a18})";
}

final class Struct20BytesHomogeneousInt32 extends Struct {
  @Int32()
  external int a0;

  @Int32()
  external int a1;

  @Int32()
  external int a2;

  @Int32()
  external int a3;

  @Int32()
  external int a4;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4})";
}

final class Struct20BytesHomogeneousFloat extends Struct {
  @Float()
  external double a0;

  @Float()
  external double a1;

  @Float()
  external double a2;

  @Float()
  external double a3;

  @Float()
  external double a4;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4})";
}

final class Struct32BytesHomogeneousDouble extends Struct {
  @Double()
  external double a0;

  @Double()
  external double a1;

  @Double()
  external double a2;

  @Double()
  external double a3;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3})";
}

final class Struct40BytesHomogeneousDouble extends Struct {
  @Double()
  external double a0;

  @Double()
  external double a1;

  @Double()
  external double a2;

  @Double()
  external double a3;

  @Double()
  external double a4;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4})";
}

final class Struct1024BytesHomogeneousUint64 extends Struct {
  @Uint64()
  external int a0;

  @Uint64()
  external int a1;

  @Uint64()
  external int a2;

  @Uint64()
  external int a3;

  @Uint64()
  external int a4;

  @Uint64()
  external int a5;

  @Uint64()
  external int a6;

  @Uint64()
  external int a7;

  @Uint64()
  external int a8;

  @Uint64()
  external int a9;

  @Uint64()
  external int a10;

  @Uint64()
  external int a11;

  @Uint64()
  external int a12;

  @Uint64()
  external int a13;

  @Uint64()
  external int a14;

  @Uint64()
  external int a15;

  @Uint64()
  external int a16;

  @Uint64()
  external int a17;

  @Uint64()
  external int a18;

  @Uint64()
  external int a19;

  @Uint64()
  external int a20;

  @Uint64()
  external int a21;

  @Uint64()
  external int a22;

  @Uint64()
  external int a23;

  @Uint64()
  external int a24;

  @Uint64()
  external int a25;

  @Uint64()
  external int a26;

  @Uint64()
  external int a27;

  @Uint64()
  external int a28;

  @Uint64()
  external int a29;

  @Uint64()
  external int a30;

  @Uint64()
  external int a31;

  @Uint64()
  external int a32;

  @Uint64()
  external int a33;

  @Uint64()
  external int a34;

  @Uint64()
  external int a35;

  @Uint64()
  external int a36;

  @Uint64()
  external int a37;

  @Uint64()
  external int a38;

  @Uint64()
  external int a39;

  @Uint64()
  external int a40;

  @Uint64()
  external int a41;

  @Uint64()
  external int a42;

  @Uint64()
  external int a43;

  @Uint64()
  external int a44;

  @Uint64()
  external int a45;

  @Uint64()
  external int a46;

  @Uint64()
  external int a47;

  @Uint64()
  external int a48;

  @Uint64()
  external int a49;

  @Uint64()
  external int a50;

  @Uint64()
  external int a51;

  @Uint64()
  external int a52;

  @Uint64()
  external int a53;

  @Uint64()
  external int a54;

  @Uint64()
  external int a55;

  @Uint64()
  external int a56;

  @Uint64()
  external int a57;

  @Uint64()
  external int a58;

  @Uint64()
  external int a59;

  @Uint64()
  external int a60;

  @Uint64()
  external int a61;

  @Uint64()
  external int a62;

  @Uint64()
  external int a63;

  @Uint64()
  external int a64;

  @Uint64()
  external int a65;

  @Uint64()
  external int a66;

  @Uint64()
  external int a67;

  @Uint64()
  external int a68;

  @Uint64()
  external int a69;

  @Uint64()
  external int a70;

  @Uint64()
  external int a71;

  @Uint64()
  external int a72;

  @Uint64()
  external int a73;

  @Uint64()
  external int a74;

  @Uint64()
  external int a75;

  @Uint64()
  external int a76;

  @Uint64()
  external int a77;

  @Uint64()
  external int a78;

  @Uint64()
  external int a79;

  @Uint64()
  external int a80;

  @Uint64()
  external int a81;

  @Uint64()
  external int a82;

  @Uint64()
  external int a83;

  @Uint64()
  external int a84;

  @Uint64()
  external int a85;

  @Uint64()
  external int a86;

  @Uint64()
  external int a87;

  @Uint64()
  external int a88;

  @Uint64()
  external int a89;

  @Uint64()
  external int a90;

  @Uint64()
  external int a91;

  @Uint64()
  external int a92;

  @Uint64()
  external int a93;

  @Uint64()
  external int a94;

  @Uint64()
  external int a95;

  @Uint64()
  external int a96;

  @Uint64()
  external int a97;

  @Uint64()
  external int a98;

  @Uint64()
  external int a99;

  @Uint64()
  external int a100;

  @Uint64()
  external int a101;

  @Uint64()
  external int a102;

  @Uint64()
  external int a103;

  @Uint64()
  external int a104;

  @Uint64()
  external int a105;

  @Uint64()
  external int a106;

  @Uint64()
  external int a107;

  @Uint64()
  external int a108;

  @Uint64()
  external int a109;

  @Uint64()
  external int a110;

  @Uint64()
  external int a111;

  @Uint64()
  external int a112;

  @Uint64()
  external int a113;

  @Uint64()
  external int a114;

  @Uint64()
  external int a115;

  @Uint64()
  external int a116;

  @Uint64()
  external int a117;

  @Uint64()
  external int a118;

  @Uint64()
  external int a119;

  @Uint64()
  external int a120;

  @Uint64()
  external int a121;

  @Uint64()
  external int a122;

  @Uint64()
  external int a123;

  @Uint64()
  external int a124;

  @Uint64()
  external int a125;

  @Uint64()
  external int a126;

  @Uint64()
  external int a127;

  String toString() =>
      "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6}, ${a7}, ${a8}, ${a9}, ${a10}, ${a11}, ${a12}, ${a13}, ${a14}, ${a15}, ${a16}, ${a17}, ${a18}, ${a19}, ${a20}, ${a21}, ${a22}, ${a23}, ${a24}, ${a25}, ${a26}, ${a27}, ${a28}, ${a29}, ${a30}, ${a31}, ${a32}, ${a33}, ${a34}, ${a35}, ${a36}, ${a37}, ${a38}, ${a39}, ${a40}, ${a41}, ${a42}, ${a43}, ${a44}, ${a45}, ${a46}, ${a47}, ${a48}, ${a49}, ${a50}, ${a51}, ${a52}, ${a53}, ${a54}, ${a55}, ${a56}, ${a57}, ${a58}, ${a59}, ${a60}, ${a61}, ${a62}, ${a63}, ${a64}, ${a65}, ${a66}, ${a67}, ${a68}, ${a69}, ${a70}, ${a71}, ${a72}, ${a73}, ${a74}, ${a75}, ${a76}, ${a77}, ${a78}, ${a79}, ${a80}, ${a81}, ${a82}, ${a83}, ${a84}, ${a85}, ${a86}, ${a87}, ${a88}, ${a89}, ${a90}, ${a91}, ${a92}, ${a93}, ${a94}, ${a95}, ${a96}, ${a97}, ${a98}, ${a99}, ${a100}, ${a101}, ${a102}, ${a103}, ${a104}, ${a105}, ${a106}, ${a107}, ${a108}, ${a109}, ${a110}, ${a111}, ${a112}, ${a113}, ${a114}, ${a115}, ${a116}, ${a117}, ${a118}, ${a119}, ${a120}, ${a121}, ${a122}, ${a123}, ${a124}, ${a125}, ${a126}, ${a127})";
}

final class StructAlignmentInt16 extends Struct {
  @Int8()
  external int a0;

  @Int16()
  external int a1;

  @Int8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class StructAlignmentInt32 extends Struct {
  @Int8()
  external int a0;

  @Int32()
  external int a1;

  @Int8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class StructAlignmentInt64 extends Struct {
  @Int8()
  external int a0;

  @Int64()
  external int a1;

  @Int8()
  external int a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class Struct8BytesNestedInt extends Struct {
  external Struct4BytesHomogeneousInt16 a0;

  external Struct4BytesHomogeneousInt16 a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct8BytesNestedFloat extends Struct {
  external Struct4BytesFloat a0;

  external Struct4BytesFloat a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct8BytesNestedFloat2 extends Struct {
  external Struct4BytesFloat a0;

  @Float()
  external double a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct8BytesNestedMixed extends Struct {
  external Struct4BytesHomogeneousInt16 a0;

  external Struct4BytesFloat a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct16BytesNestedInt extends Struct {
  external Struct8BytesNestedInt a0;

  external Struct8BytesNestedInt a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct32BytesNestedInt extends Struct {
  external Struct16BytesNestedInt a0;

  external Struct16BytesNestedInt a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructNestedIntStructAlignmentInt16 extends Struct {
  external StructAlignmentInt16 a0;

  external StructAlignmentInt16 a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructNestedIntStructAlignmentInt32 extends Struct {
  external StructAlignmentInt32 a0;

  external StructAlignmentInt32 a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructNestedIntStructAlignmentInt64 extends Struct {
  external StructAlignmentInt64 a0;

  external StructAlignmentInt64 a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructNestedIrregularBig extends Struct {
  @Uint16()
  external int a0;

  external Struct8BytesNestedMixed a1;

  @Uint16()
  external int a2;

  external Struct8BytesNestedFloat2 a3;

  @Uint16()
  external int a4;

  external Struct8BytesNestedFloat a5;

  @Uint16()
  external int a6;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4}, ${a5}, ${a6})";
}

final class StructNestedIrregularBigger extends Struct {
  external StructNestedIrregularBig a0;

  external Struct8BytesNestedMixed a1;

  @Float()
  external double a2;

  @Double()
  external double a3;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3})";
}

final class StructNestedIrregularEvenBigger extends Struct {
  @Uint64()
  external int a0;

  external StructNestedIrregularBigger a1;

  external StructNestedIrregularBigger a2;

  @Double()
  external double a3;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3})";
}

final class Struct8BytesInlineArrayInt extends Struct {
  @Array(8)
  external Array<Uint8> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 8; i0 += 1) a0[i0]]})";
}

final class Struct10BytesInlineArrayBool extends Struct {
  @Array(10)
  external Array<Bool> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 10; i0 += 1) a0[i0]]})";
}

final class StructInlineArrayIrregular extends Struct {
  @Array(2)
  external Array<Struct3BytesInt2ByteAligned> a0;

  @Uint8()
  external int a1;

  String toString() => "(${[for (var i0 = 0; i0 < 2; i0 += 1) a0[i0]]}, ${a1})";
}

final class StructInlineArray100Bytes extends Struct {
  @Array(100)
  external Array<Uint8> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 100; i0 += 1) a0[i0]]})";
}

final class StructInlineArrayBig extends Struct {
  @Uint32()
  external int a0;

  @Uint32()
  external int a1;

  @Array(4000)
  external Array<Uint8> a2;

  String toString() =>
      "(${a0}, ${a1}, ${[for (var i0 = 0; i0 < 4000; i0 += 1) a2[i0]]})";
}

final class StructStruct16BytesHomogeneousFloat2 extends Struct {
  external Struct4BytesFloat a0;

  @Array(2)
  external Array<Struct4BytesFloat> a1;

  @Float()
  external double a2;

  String toString() =>
      "(${a0}, ${[for (var i0 = 0; i0 < 2; i0 += 1) a1[i0]]}, ${a2})";
}

final class StructStruct32BytesHomogeneousDouble2 extends Struct {
  external Struct8BytesFloat a0;

  @Array(2)
  external Array<Struct8BytesFloat> a1;

  @Double()
  external double a2;

  String toString() =>
      "(${a0}, ${[for (var i0 = 0; i0 < 2; i0 += 1) a1[i0]]}, ${a2})";
}

final class StructStruct16BytesMixed3 extends Struct {
  external Struct4BytesFloat a0;

  @Array(1)
  external Array<Struct8BytesMixed> a1;

  @Array(2)
  external Array<Int16> a2;

  String toString() =>
      "(${a0}, ${[for (var i0 = 0; i0 < 1; i0 += 1) a1[i0]]}, ${[for (var i0 = 0; i0 < 2; i0 += 1) a2[i0]]})";
}

final class Struct8BytesInlineArrayMultiDimensionalInt extends Struct {
  @Array(2, 2, 2)
  external Array<Array<Array<Uint8>>> a0;

  String toString() =>
      "(${[
        for (var i0 = 0; i0 < 2; i0 += 1) [
            for (var i1 = 0; i1 < 2; i1 += 1) [for (var i2 = 0; i2 < 2; i2 += 1) a0[i0][i1][i2]],
          ],
      ]})";
}

final class Struct32BytesInlineArrayMultiDimensionalInt extends Struct {
  @Array(2, 2, 2, 2, 2)
  external Array<Array<Array<Array<Array<Uint8>>>>> a0;

  String toString() =>
      "(${[
        for (var i0 = 0; i0 < 2; i0 += 1) [
            for (var i1 = 0; i1 < 2; i1 += 1) [
                for (var i2 = 0; i2 < 2; i2 += 1) [
                    for (var i3 = 0; i3 < 2; i3 += 1) [for (var i4 = 0; i4 < 2; i4 += 1) a0[i0][i1][i2][i3][i4]],
                  ],
              ],
          ],
      ]})";
}

final class Struct64BytesInlineArrayMultiDimensionalInt extends Struct {
  @Array.multi([2, 2, 2, 2, 2, 2])
  external Array<Array<Array<Array<Array<Array<Uint8>>>>>> a0;

  String toString() =>
      "(${[
        for (var i0 = 0; i0 < 2; i0 += 1) [
            for (var i1 = 0; i1 < 2; i1 += 1) [
                for (var i2 = 0; i2 < 2; i2 += 1) [
                    for (var i3 = 0; i3 < 2; i3 += 1) [
                        for (var i4 = 0; i4 < 2; i4 += 1) [for (var i5 = 0; i5 < 2; i5 += 1) a0[i0][i1][i2][i3][i4][i5]],
                      ],
                  ],
              ],
          ],
      ]})";
}

final class Struct4BytesInlineArrayMultiDimensionalInt extends Struct {
  @Array(2, 2)
  external Array<Array<Struct1ByteInt>> a0;

  String toString() =>
      "(${[
        for (var i0 = 0; i0 < 2; i0 += 1) [for (var i1 = 0; i1 < 2; i1 += 1) a0[i0][i1]],
      ]})";
}

@Packed(1)
final class Struct3BytesPackedInt extends Struct {
  @Int8()
  external int a0;

  @Int16()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

@Packed(1)
final class Struct3BytesPackedIntMembersAligned extends Struct {
  @Int8()
  external int a0;

  @Int16()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

@Packed(1)
final class Struct5BytesPackedMixed extends Struct {
  @Float()
  external double a0;

  @Uint8()
  external int a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructNestedAlignmentStruct5BytesPackedMixed extends Struct {
  @Uint8()
  external int a0;

  external Struct5BytesPackedMixed a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct6BytesInlineArrayInt extends Struct {
  @Array(2)
  external Array<Struct3BytesPackedIntMembersAligned> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 2; i0 += 1) a0[i0]]})";
}

@Packed(1)
final class Struct8BytesPackedInt extends Struct {
  @Uint8()
  external int a0;

  @Uint32()
  external int a1;

  @Uint8()
  external int a2;

  @Uint8()
  external int a3;

  @Uint8()
  external int a4;

  String toString() => "(${a0}, ${a1}, ${a2}, ${a3}, ${a4})";
}

@Packed(1)
final class Struct9BytesPackedMixed extends Struct {
  @Uint8()
  external int a0;

  @Double()
  external double a1;

  String toString() => "(${a0}, ${a1})";
}

final class Struct15BytesInlineArrayMixed extends Struct {
  @Array(3)
  external Array<Struct5BytesPackedMixed> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 3; i0 += 1) a0[i0]]})";
}

final class Union4BytesMixed extends Union {
  @Uint32()
  external int a0;

  @Float()
  external double a1;

  String toString() => "(${a0}, ${a1})";
}

final class Union8BytesNestedFloat extends Union {
  @Double()
  external double a0;

  external Struct8BytesHomogeneousFloat a1;

  String toString() => "(${a0}, ${a1})";
}

final class Union9BytesNestedInt extends Union {
  external Struct8BytesInt a0;

  external Struct9BytesHomogeneousUint8 a1;

  String toString() => "(${a0}, ${a1})";
}

final class Union16BytesNestedInlineArrayFloat extends Union {
  @Array(4)
  external Array<Float> a0;

  external Struct16BytesHomogeneousFloat a1;

  String toString() => "(${[for (var i0 = 0; i0 < 4; i0 += 1) a0[i0]]}, ${a1})";
}

final class Union16BytesNestedFloat extends Union {
  external Struct8BytesHomogeneousFloat a0;

  external Struct12BytesHomogeneousFloat a1;

  external Struct16BytesHomogeneousFloat a2;

  String toString() => "(${a0}, ${a1}, ${a2})";
}

final class StructInlineArrayInt extends Struct {
  @Array(10)
  external Array<WChar> a0;

  String toString() => "(${[for (var i0 = 0; i0 < 10; i0 += 1) a0[i0]]})";
}

final class StructInlineArrayVariable extends Struct {
  @Uint32()
  external int a0;

  @Array.variable()
  external Array<Uint8> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariableNested extends Struct {
  @Uint32()
  external int a0;

  @Array.variable(2, 2)
  external Array<Array<Array<Uint8>>> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariableNestedDeep extends Struct {
  @Uint32()
  external int a0;

  @Array.variableMulti([2, 2, 2, 2, 2, 2])
  external Array<Array<Array<Array<Array<Array<Array<Uint8>>>>>>> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariableAlign extends Struct {
  @Uint8()
  external int a0;

  @Array.variable()
  external Array<Uint32> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariable2 extends Struct {
  @Uint32()
  external int a0;

  @Array.variableWithVariableDimension(1)
  external Array<Uint8> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariableNested2 extends Struct {
  @Uint32()
  external int a0;

  @Array.variableWithVariableDimension(1, 2, 2)
  external Array<Array<Array<Uint8>>> a1;

  String toString() => "(${a0}, ${a1})";
}

final class StructInlineArrayVariableNestedDeep2 extends Struct {
  @Uint32()
  external int a0;

  @Array.variableMulti(variableDimension: 1, [2, 2, 2, 2, 2, 2])
  external Array<Array<Array<Array<Array<Array<Array<Uint8>>>>>>> a1;

  String toString() => "(${a0}, ${a1})";
}
