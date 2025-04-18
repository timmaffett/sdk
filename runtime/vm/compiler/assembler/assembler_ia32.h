// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_COMPILER_ASSEMBLER_ASSEMBLER_IA32_H_
#define RUNTIME_VM_COMPILER_ASSEMBLER_ASSEMBLER_IA32_H_

#if defined(DART_PRECOMPILED_RUNTIME)
#error "AOT runtime should not use compiler sources (including header files)"
#endif  // defined(DART_PRECOMPILED_RUNTIME)

#ifndef RUNTIME_VM_COMPILER_ASSEMBLER_ASSEMBLER_H_
#error Do not include assembler_ia32.h directly; use assembler.h instead.
#endif

#include <functional>

#include "platform/assert.h"
#include "platform/utils.h"
#include "vm/compiler/assembler/assembler_base.h"
#include "vm/constants.h"
#include "vm/constants_x86.h"
#include "vm/pointer_tagging.h"

namespace dart {

namespace compiler {

class Immediate : public ValueObject {
 public:
  explicit Immediate(int32_t value) : value_(value) {}

  Immediate(const Immediate& other) : ValueObject(), value_(other.value_) {}

  int32_t value() const { return value_; }

  bool is_int8() const { return Utils::IsInt(8, value_); }
  bool is_uint8() const { return Utils::IsUint(8, value_); }
  bool is_uint16() const { return Utils::IsUint(16, value_); }

 private:
  const int32_t value_;

  // TODO(5411081): Add DISALLOW_COPY_AND_ASSIGN(Immediate) once the mac
  // build issue is resolved.
  // And remove the unnecessary copy constructor.
};

class Operand : public ValueObject {
 public:
  uint8_t mod() const { return (encoding_at(0) >> 6) & 3; }

  Register rm() const { return static_cast<Register>(encoding_at(0) & 7); }

  ScaleFactor scale() const {
    return static_cast<ScaleFactor>((encoding_at(1) >> 6) & 3);
  }

  Register index() const {
    return static_cast<Register>((encoding_at(1) >> 3) & 7);
  }

  Register base() const { return static_cast<Register>(encoding_at(1) & 7); }

  int8_t disp8() const {
    ASSERT(length_ >= 2);
    return static_cast<int8_t>(encoding_[length_ - 1]);
  }

  int32_t disp32() const {
    ASSERT(length_ >= 5);
    return bit_copy<int32_t>(encoding_[length_ - 4]);
  }

  Operand(const Operand& other) : ValueObject(), length_(other.length_) {
    memmove(&encoding_[0], &other.encoding_[0], other.length_);
  }

  Operand& operator=(const Operand& other) {
    length_ = other.length_;
    memmove(&encoding_[0], &other.encoding_[0], other.length_);
    return *this;
  }

  bool Equals(const Operand& other) const {
    if (length_ != other.length_) return false;
    for (uint8_t i = 0; i < length_; i++) {
      if (encoding_[i] != other.encoding_[i]) return false;
    }
    return true;
  }

 protected:
  Operand() : length_(0) {}  // Needed by subclass Address.

  void SetModRM(int mod, Register rm) {
    ASSERT((mod & ~3) == 0);
    encoding_[0] = (mod << 6) | rm;
    length_ = 1;
  }

  void SetSIB(ScaleFactor scale, Register index, Register base) {
    ASSERT(length_ == 1);
    ASSERT((scale & ~3) == 0);
    encoding_[1] = (scale << 6) | (index << 3) | base;
    length_ = 2;
  }

  void SetDisp8(int8_t disp) {
    ASSERT(length_ == 1 || length_ == 2);
    encoding_[length_++] = static_cast<uint8_t>(disp);
  }

  void SetDisp32(int32_t disp) {
    ASSERT(length_ == 1 || length_ == 2);
    intptr_t disp_size = sizeof(disp);
    memmove(&encoding_[length_], &disp, disp_size);
    length_ += disp_size;
  }

 private:
  uint8_t length_;
  uint8_t encoding_[6];
  uint8_t padding_;

  explicit Operand(Register reg) { SetModRM(3, reg); }

  // Get the operand encoding byte at the given index.
  uint8_t encoding_at(intptr_t index) const {
    ASSERT(index >= 0 && index < length_);
    return encoding_[index];
  }

  // Returns whether or not this operand is really the given register in
  // disguise. Used from the assembler to generate better encodings.
  bool IsRegister(Register reg) const {
    return ((encoding_[0] & 0xF8) == 0xC0)  // Addressing mode is register only.
           && ((encoding_[0] & 0x07) == reg);  // Register codes match.
  }

  friend class Assembler;
};

class Address : public Operand {
 public:
  Address(Register base, int32_t disp) {
    if (disp == 0 && base != EBP) {
      SetModRM(0, base);
      if (base == ESP) SetSIB(TIMES_1, ESP, base);
    } else if (Utils::IsInt(8, disp)) {
      SetModRM(1, base);
      if (base == ESP) SetSIB(TIMES_1, ESP, base);
      SetDisp8(disp);
    } else {
      SetModRM(2, base);
      if (base == ESP) SetSIB(TIMES_1, ESP, base);
      SetDisp32(disp);
    }
  }

  Address(Register index, ScaleFactor scale, int32_t disp) {
    ASSERT(index != ESP);       // Illegal addressing mode.
    ASSERT(scale != TIMES_16);  // Unsupported scale factor.
    SetModRM(0, ESP);
    SetSIB(scale, index, EBP);
    SetDisp32(disp);
  }

  // This addressing mode does not exist.
  Address(Register index, ScaleFactor scale, Register r);

  Address(Register base, Register index, ScaleFactor scale, int32_t disp) {
    ASSERT(index != ESP);       // Illegal addressing mode.
    ASSERT(scale != TIMES_16);  // Unsupported scale factor.
    if (disp == 0 && base != EBP) {
      SetModRM(0, ESP);
      SetSIB(scale, index, base);
    } else if (Utils::IsInt(8, disp)) {
      SetModRM(1, ESP);
      SetSIB(scale, index, base);
      SetDisp8(disp);
    } else {
      SetModRM(2, ESP);
      SetSIB(scale, index, base);
      SetDisp32(disp);
    }
  }

  // This addressing mode does not exist.
  Address(Register base, Register index, ScaleFactor scale, Register r);

  Address(const Address& other) : Operand(other) {}

  Address& operator=(const Address& other) {
    Operand::operator=(other);
    return *this;
  }

  static Address Absolute(const uword addr) {
    Address result;
    result.SetModRM(0, EBP);
    result.SetDisp32(addr);
    return result;
  }

 private:
  Address() {}  // Needed by Address::Absolute.
};

class FieldAddress : public Address {
 public:
  FieldAddress(Register base, int32_t disp)
      : Address(base, disp - kHeapObjectTag) {}

  // This addressing mode does not exist.
  FieldAddress(Register base, Register r);

  FieldAddress(Register base, Register index, ScaleFactor scale, int32_t disp)
      : Address(base, index, scale, disp - kHeapObjectTag) {}

  // This addressing mode does not exist.
  FieldAddress(Register base, Register index, ScaleFactor scale, Register r);

  FieldAddress(const FieldAddress& other) : Address(other) {}

  FieldAddress& operator=(const FieldAddress& other) {
    Address::operator=(other);
    return *this;
  }
};

class Assembler : public AssemblerBase {
 public:
  explicit Assembler(ObjectPoolBuilder* object_pool_builder,
                     intptr_t far_branch_level = 0)
      : AssemblerBase(object_pool_builder),
        jit_cookie_(0),
        code_(NewZoneHandle(ThreadState::Current()->zone())) {
    // This mode is only needed and implemented for ARM.
    ASSERT(far_branch_level == 0);
  }
  ~Assembler() {}

  /*
   * Emit Machine Instructions.
   */
  void call(Register reg);
  void call(const Address& address);
  void call(Label* label);
  void call(const ExternalLabel* label);

  static constexpr intptr_t kCallExternalLabelSize = 5;

  void pushl(Register reg);
  void pushl(const Address& address);
  void pushl(const Immediate& imm);
  void PushImmediate(int32_t value) { pushl(Immediate(value)); }

  void popl(Register reg);
  void popl(const Address& address);

  void pushal();
  void popal();

  void setcc(Condition condition, ByteRegister dst);

  void movl(Register dst, const Immediate& src);
  void movl(Register dst, Register src);

  void movl(Register dst, const Address& src);
  void movl(const Address& dst, Register src);
  void movl(const Address& dst, const Immediate& imm);

  void movzxb(Register dst, ByteRegister src);
  void movzxb(Register dst, const Address& src);
  void movsxb(Register dst, ByteRegister src);
  void movsxb(Register dst, const Address& src);
  void movb(Register dst, const Address& src);
  void movb(const Address& dst, Register src);
  void movb(const Address& dst, ByteRegister src);
  void movb(const Address& dst, const Immediate& imm);

  void movzxw(Register dst, Register src);
  void movzxw(Register dst, const Address& src);
  void movsxw(Register dst, Register src);
  void movsxw(Register dst, const Address& src);
  void movw(Register dst, const Address& src);
  void movw(const Address& dst, Register src);
  void movw(const Address& dst, const Immediate& imm);

  void leal(Register dst, const Address& src);

  void cmovno(Register dst, Register src);
  void cmove(Register dst, Register src);
  void cmovne(Register dst, Register src);
  void cmovs(Register dst, Register src);
  void cmovns(Register dst, Register src);

  void cmovgel(Register dst, Register src);
  void cmovlessl(Register dst, Register src);

  void rep_movsb();
  void rep_movsw();
  void rep_movsd();

  void movss(XmmRegister dst, const Address& src);
  void movss(const Address& dst, XmmRegister src);
  void movss(XmmRegister dst, XmmRegister src);

  void movd(XmmRegister dst, Register src);
  void movd(Register dst, XmmRegister src);

  void movq(const Address& dst, XmmRegister src);
  void movq(XmmRegister dst, const Address& src);

  void addss(XmmRegister dst, XmmRegister src);
  void addss(XmmRegister dst, const Address& src);
  void subss(XmmRegister dst, XmmRegister src);
  void subss(XmmRegister dst, const Address& src);
  void mulss(XmmRegister dst, XmmRegister src);
  void mulss(XmmRegister dst, const Address& src);
  void divss(XmmRegister dst, XmmRegister src);
  void divss(XmmRegister dst, const Address& src);

  void movsd(XmmRegister dst, const Address& src);
  void movsd(const Address& dst, XmmRegister src);
  void movsd(XmmRegister dst, XmmRegister src);

  void movaps(XmmRegister dst, XmmRegister src);

  void movups(XmmRegister dst, const Address& src);
  void movups(const Address& dst, XmmRegister src);

  void addsd(XmmRegister dst, XmmRegister src);
  void addsd(XmmRegister dst, const Address& src);
  void subsd(XmmRegister dst, XmmRegister src);
  void subsd(XmmRegister dst, const Address& src);
  void mulsd(XmmRegister dst, XmmRegister src);
  void mulsd(XmmRegister dst, const Address& src);
  void divsd(XmmRegister dst, XmmRegister src);
  void divsd(XmmRegister dst, const Address& src);

  void addpl(XmmRegister dst, XmmRegister src);
  void subpl(XmmRegister dst, XmmRegister src);
  void addps(XmmRegister dst, XmmRegister src);
  void subps(XmmRegister dst, XmmRegister src);
  void divps(XmmRegister dst, XmmRegister src);
  void mulps(XmmRegister dst, XmmRegister src);
  void minps(XmmRegister dst, XmmRegister src);
  void maxps(XmmRegister dst, XmmRegister src);
  void andps(XmmRegister dst, XmmRegister src);
  void andps(XmmRegister dst, const Address& src);
  void orps(XmmRegister dst, XmmRegister src);
  void notps(XmmRegister dst);
  void negateps(XmmRegister dst);
  void absps(XmmRegister dst);
  void zerowps(XmmRegister dst);
  void cmppseq(XmmRegister dst, XmmRegister src);
  void cmppsneq(XmmRegister dst, XmmRegister src);
  void cmppslt(XmmRegister dst, XmmRegister src);
  void cmppsle(XmmRegister dst, XmmRegister src);
  void cmppsnlt(XmmRegister dst, XmmRegister src);
  void cmppsnle(XmmRegister dst, XmmRegister src);
  void sqrtps(XmmRegister dst);
  void rsqrtps(XmmRegister dst);
  void reciprocalps(XmmRegister dst);
  void movhlps(XmmRegister dst, XmmRegister src);
  void movlhps(XmmRegister dst, XmmRegister src);
  void unpcklps(XmmRegister dst, XmmRegister src);
  void unpckhps(XmmRegister dst, XmmRegister src);
  void unpcklpd(XmmRegister dst, XmmRegister src);
  void unpckhpd(XmmRegister dst, XmmRegister src);

  void set1ps(XmmRegister dst, Register tmp, const Immediate& imm);
  void shufps(XmmRegister dst, XmmRegister src, const Immediate& mask);

  void addpd(XmmRegister dst, XmmRegister src);
  void negatepd(XmmRegister dst);
  void subpd(XmmRegister dst, XmmRegister src);
  void mulpd(XmmRegister dst, XmmRegister src);
  void divpd(XmmRegister dst, XmmRegister src);
  void abspd(XmmRegister dst);
  void minpd(XmmRegister dst, XmmRegister src);
  void maxpd(XmmRegister dst, XmmRegister src);
  void sqrtpd(XmmRegister dst);
  void cvtps2pd(XmmRegister dst, XmmRegister src);
  void cvtpd2ps(XmmRegister dst, XmmRegister src);
  void shufpd(XmmRegister dst, XmmRegister src, const Immediate& mask);

  void cvtsi2ss(XmmRegister dst, Register src);
  void cvtsi2sd(XmmRegister dst, Register src);

  void cvtss2si(Register dst, XmmRegister src);
  void cvtss2sd(XmmRegister dst, XmmRegister src);

  void cvtsd2si(Register dst, XmmRegister src);
  void cvtsd2ss(XmmRegister dst, XmmRegister src);

  void cvttss2si(Register dst, XmmRegister src);
  void cvttsd2si(Register dst, XmmRegister src);

  void cvtdq2pd(XmmRegister dst, XmmRegister src);

  void comiss(XmmRegister a, XmmRegister b);
  void comisd(XmmRegister a, XmmRegister b);

  void movmskpd(Register dst, XmmRegister src);
  void movmskps(Register dst, XmmRegister src);
  void pmovmskb(Register dst, XmmRegister src);

  void sqrtsd(XmmRegister dst, XmmRegister src);
  void sqrtss(XmmRegister dst, XmmRegister src);

  void xorpd(XmmRegister dst, const Address& src);
  void xorpd(XmmRegister dst, XmmRegister src);
  void xorps(XmmRegister dst, const Address& src);
  void xorps(XmmRegister dst, XmmRegister src);

  void andpd(XmmRegister dst, const Address& src);
  void andpd(XmmRegister dst, XmmRegister src);

  void orpd(XmmRegister dst, XmmRegister src);

  void pextrd(Register dst, XmmRegister src, const Immediate& imm);
  void pmovsxdq(XmmRegister dst, XmmRegister src);
  void pcmpeqq(XmmRegister dst, XmmRegister src);

  void pxor(XmmRegister dst, XmmRegister src);

  enum RoundingMode {
    kRoundToNearest = 0x0,
    kRoundDown = 0x1,
    kRoundUp = 0x2,
    kRoundToZero = 0x3
  };
  void roundsd(XmmRegister dst, XmmRegister src, RoundingMode mode);

  void flds(const Address& src);
  void fstps(const Address& dst);

  void fldl(const Address& src);
  void fstpl(const Address& dst);

  void fnstcw(const Address& dst);
  void fldcw(const Address& src);

  void fistpl(const Address& dst);
  void fistps(const Address& dst);
  void fildl(const Address& src);
  void filds(const Address& src);

  void fincstp();
  void ffree(intptr_t value);

  void fsin();
  void fcos();
  void fsincos();
  void fptan();

  void xchgl(Register dst, Register src);

  void cmpw(const Address& address, const Immediate& imm);
  void cmpb(const Address& address, const Immediate& imm);

  void testl(Register reg1, Register reg2);
  void testl(Register reg, const Immediate& imm);
  void testl(const Address& address, const Immediate& imm);
  void testl(const Address& address, Register reg);
  void testb(const Address& address, const Immediate& imm);
  void testb(const Address& address, ByteRegister reg);

  // clang-format off
// Macro for handling common ALU instructions. Arguments to F:
//   name, opcode, reversed opcode, opcode for the reg field of the modrm byte.
#define ALU_OPS(F)                                                             \
  F(and, 0x23, 0x21, 4)                                                        \
  F(or, 0x0b, 0x09, 1)                                                         \
  F(xor, 0x33, 0x31, 6)                                                        \
  F(add, 0x03, 0x01, 0)                                                        \
  F(adc, 0x13, 0x11, 2)                                                        \
  F(sub, 0x2b, 0x29, 5)                                                        \
  F(sbb, 0x1b, 0x19, 3)                                                        \
  F(cmp, 0x3b, 0x39, 7)
  // clang-format on

#define DECLARE_ALU(op, opcode, opcode2, modrm_opcode)                         \
  void op##l(Register dst, Register src) { Alu(4, opcode, dst, src); }         \
  void op##w(Register dst, Register src) { Alu(2, opcode, dst, src); }         \
  void op##l(Register dst, const Address& src) { Alu(4, opcode, dst, src); }   \
  void op##w(Register dst, const Address& src) { Alu(2, opcode, dst, src); }   \
  void op##l(const Address& dst, Register src) { Alu(4, opcode2, dst, src); }  \
  void op##w(const Address& dst, Register src) { Alu(2, opcode2, dst, src); }  \
  void op##l(Register dst, const Immediate& imm) {                             \
    Alu(modrm_opcode, dst, imm);                                               \
  }                                                                            \
  void op##l(const Address& dst, const Immediate& imm) {                       \
    Alu(modrm_opcode, dst, imm);                                               \
  }

  ALU_OPS(DECLARE_ALU);

#undef DECLARE_ALU
#undef ALU_OPS

  void cdq();

  void idivl(Register reg);

  void divl(Register reg);

  void imull(Register dst, Register src);
  void imull(Register reg, const Immediate& imm);
  void imull(Register reg, const Address& address);

  void imull(Register reg);
  void imull(const Address& address);

  void mull(Register reg);
  void mull(const Address& address);

  void incl(Register reg);
  void incl(const Address& address);

  void decl(Register reg);
  void decl(const Address& address);

  void shll(Register reg, const Immediate& imm);
  void shll(Register operand, Register shifter);
  void shll(const Address& operand, Register shifter);
  void shrl(Register reg, const Immediate& imm);
  void shrl(Register operand, Register shifter);
  void sarl(Register reg, const Immediate& imm);
  void sarl(Register operand, Register shifter);
  void sarl(const Address& address, Register shifter);
  void shldl(Register dst, Register src, Register shifter);
  void shldl(Register dst, Register src, const Immediate& imm);
  void shldl(const Address& operand, Register src, Register shifter);
  void shrdl(Register dst, Register src, Register shifter);
  void shrdl(Register dst, Register src, const Immediate& imm);
  void shrdl(const Address& dst, Register src, Register shifter);

  void negl(Register reg);
  void notl(Register reg);

  void bsfl(Register dst, Register src);
  void bsrl(Register dst, Register src);
  void popcntl(Register dst, Register src);
  void lzcntl(Register dst, Register src);

  void bt(Register base, Register offset);
  void bt(Register base, int bit);

  void enter(const Immediate& imm);
  void leave();

  void ret();
  void ret(const Immediate& imm);

  // 'size' indicates size in bytes and must be in the range 1..8.
  void nop(int size = 1);
  void int3();
  void hlt();

  void j(Condition condition, Label* label, JumpDistance distance = kFarJump);
  void j(Condition condition, const ExternalLabel* label);

  void jmp(Register reg);
  void jmp(const Address& address);
  void jmp(Label* label, JumpDistance distance = kFarJump);
  void jmp(const ExternalLabel* label);

  void lock();
  void cmpxchgl(const Address& address, Register reg);

  void cld();
  void std();

  void cpuid();

  /*
   * Macros for High-level operations and implemented on all architectures.
   */

  void Ret() { ret(); }

  // Sets the return address to [value] as if there was a call.
  // On IA32 pushes [value].
  void SetReturnAddress(Register value) { PushRegister(value); }

  void PushValueAtOffset(Register base, int32_t offset) {
    pushl(Address(base, offset));
  }

  void CompareRegisters(Register a, Register b);
  void CompareObjectRegisters(Register a, Register b) {
    CompareRegisters(a, b);
  }
  void BranchIf(Condition condition,
                Label* label,
                JumpDistance distance = kFarJump) {
    j(condition, label, distance);
  }
  void BranchIfZero(Register src,
                    Label* label,
                    JumpDistance distance = kFarJump) {
    cmpl(src, Immediate(0));
    j(ZERO, label, distance);
  }
  void BranchIfBit(Register rn,
                   intptr_t bit_number,
                   Condition condition,
                   Label* label,
                   JumpDistance distance = kFarJump) {
    testl(rn, Immediate(1 << bit_number));
    j(condition, label, distance);
  }

  // Arch-specific Load to choose the right operation for [sz].
  void Load(Register dst,
            const Address& address,
            OperandSize sz = kFourBytes) override;
  void LoadIndexedPayload(Register dst,
                          Register base,
                          int32_t payload_offset,
                          Register index,
                          ScaleFactor scale,
                          OperandSize sz = kFourBytes) override {
    Load(dst, FieldAddress(base, index, scale, payload_offset), sz);
  }
  void Store(Register src,
             const Address& address,
             OperandSize sz = kFourBytes) override;
  void Store(const Object& value, const Address& address);
  void StoreZero(const Address& address, Register temp = kNoRegister) {
    movl(address, Immediate(0));
  }
  void LoadFromStack(Register dst, intptr_t depth);
  void StoreToStack(Register src, intptr_t depth);
  void CompareToStack(Register src, intptr_t depth);
  void LoadMemoryValue(Register dst, Register base, int32_t offset) {
    movl(dst, Address(base, offset));
  }
  void StoreMemoryValue(Register src, Register base, int32_t offset) {
    movl(Address(base, offset), src);
  }

  void LoadUnboxedDouble(FpuRegister dst, Register base, int32_t offset) {
    movsd(dst, Address(base, offset));
  }
  void StoreUnboxedDouble(FpuRegister src, Register base, int32_t offset) {
    movsd(Address(base, offset), src);
  }
  void MoveUnboxedDouble(FpuRegister dst, FpuRegister src) {
    if (src != dst) {
      movaps(dst, src);
    }
  }

  void LoadUnboxedSimd128(FpuRegister dst, Register base, int32_t offset) {
    movups(dst, Address(base, offset));
  }
  void StoreUnboxedSimd128(FpuRegister dst, Register base, int32_t offset) {
    movups(Address(base, offset), dst);
  }
  void MoveUnboxedSimd128(FpuRegister dst, FpuRegister src) {
    if (src != dst) {
      movaps(dst, src);
    }
  }

  void LoadAcquire(Register dst,
                   const Address& address,
                   OperandSize size = kFourBytes) override {
    // On intel loads have load-acquire behavior (i.e. loads are not re-ordered
    // with other loads).
    Load(dst, address, size);
    if (FLAG_target_thread_sanitizer) {
      FATAL("No support for TSAN on IA32.");
    }
  }
  void StoreRelease(Register src,
                    const Address& address,
                    OperandSize size = kFourBytes) override {
    // On intel stores have store-release behavior (i.e. stores are not
    // re-ordered with other stores).
    Store(src, address, size);
    if (FLAG_target_thread_sanitizer) {
      FATAL("No support for TSAN on IA32.");
    }
  }

  void CompareWithMemoryValue(Register value,
                              Address address,
                              OperandSize size = kFourBytes) override {
    ASSERT_EQUAL(size, kFourBytes);
    cmpl(value, address);
  }

  void ExtendValue(Register to, Register from, OperandSize sz) override;
  void PushRegister(Register r);
  void PopRegister(Register r);

  void PushRegisterPair(Register r0, Register r1) {
    PushRegister(r1);
    PushRegister(r0);
  }
  void PopRegisterPair(Register r0, Register r1) {
    PopRegister(r0);
    PopRegister(r1);
  }

  void PushRegistersInOrder(std::initializer_list<Register> regs);

  void AddImmediate(Register reg, const Immediate& imm);
  void AddImmediate(Register reg, int32_t value) {
    AddImmediate(reg, Immediate(value));
  }
  void AddImmediate(Register dest, Register src, int32_t value);
  void AddRegisters(Register dest, Register src) { addl(dest, src); }
  void AddScaled(Register dest,
                 Register base,
                 Register index,
                 ScaleFactor scale,
                 int32_t disp) override {
    if (base == kNoRegister) {
      leal(dest, Address(index, scale, disp));
    } else {
      leal(dest, Address(base, index, scale, disp));
    }
  }
  void SubImmediate(Register reg, const Immediate& imm);
  void SubRegisters(Register dest, Register src) { subl(dest, src); }
  void MulImmediate(Register reg,
                    int32_t imm,
                    OperandSize width = kFourBytes) override {
    ASSERT(width == kFourBytes);
    if (Utils::IsPowerOfTwo(imm)) {
      const intptr_t shift = Utils::ShiftForPowerOfTwo(imm);
      shll(reg, Immediate(shift));
    } else {
      imull(reg, Immediate(imm));
    }
  }
  void AndImmediate(Register reg,
                    int32_t value,
                    OperandSize sz = kFourBytes) override {
    AndImmediate(reg, reg, value, sz);
  }
  void AndImmediate(Register dst,
                    Register src,
                    int32_t value,
                    OperandSize sz = kFourBytes) override;
  void AndRegisters(Register dst,
                    Register src1,
                    Register src2 = kNoRegister) override;
  void OrImmediate(Register dst, int32_t value) { orl(dst, Immediate(value)); }
  void LslImmediate(Register dst,
                    Register src,
                    int32_t shift,
                    OperandSize sz = kFourBytes) override {
    ASSERT((shift >= 0) && (shift < OperandSizeInBits(sz)));
    ExtendValue(dst, src, sz);
    if (shift != 0) {
      shll(dst, Immediate(shift));
    }
  }
  void LslImmediate(Register reg,
                    int32_t shift,
                    OperandSize sz = kFourBytes) override {
    LslImmediate(reg, reg, shift, sz);
  }
  void LslRegister(Register dst, Register shift) override {
    ASSERT_EQUAL(shift, ECX);  // IA32 does not have a TMP.
    shll(dst, shift);
  }
  void LsrImmediate(Register dst, int32_t shift) override {
    shrl(dst, Immediate(shift));
  }

  void CompareImmediate(Register reg,
                        int32_t immediate,
                        OperandSize width = kFourBytes) override {
    ASSERT_EQUAL(width, kFourBytes);
    cmpl(reg, Immediate(immediate));
  }

  void LoadImmediate(Register reg, int32_t immediate) override {
    if (immediate == 0) {
      xorl(reg, reg);
    } else {
      movl(reg, Immediate(immediate));
    }
  }

  void LoadImmediate(Register reg, Immediate immediate) {
    LoadImmediate(reg, immediate.value());
  }

  void LoadSImmediate(XmmRegister dst, float value);
  void LoadDImmediate(XmmRegister dst, double value);
  void LoadQImmediate(XmmRegister dst, simd128_value_t value);

  void Drop(intptr_t stack_elements);

  void LoadIsolate(Register dst);
  void LoadIsolateGroup(Register dst);

  void LoadUniqueObject(Register dst, const Object& object) {
    LoadObject(dst, object, /*movable_referent=*/true);
  }

  void LoadObject(Register dst,
                  const Object& object,
                  bool movable_referent = false);

  // If 'object' is a large Smi, xor it with a per-assembler cookie value to
  // prevent user-controlled immediates from appearing in the code stream.
  void LoadObjectSafely(Register dst, const Object& object);

  void PushObject(const Object& object);
  void CompareObject(Register reg, const Object& object);

  void InitializeHeader(Register tags, Register object) {
    movl(FieldAddress(object, target::Object::tags_offset()), tags);
    // No fence: all stores are ordered on ia32.
  }
  void InitializeHeader(Immediate tags, Register object) {
    movl(FieldAddress(object, target::Object::tags_offset()), tags);
    // No fence: all stores are ordered on ia32.
  }

  void StoreObjectIntoObjectNoBarrier(
      Register object,
      const Address& dest,
      const Object& value,
      MemoryOrder memory_order = kRelaxedNonAtomic,
      OperandSize size = kFourBytes) override;

  void StoreBarrier(Register object,
                    Register value,
                    CanBeSmi can_be_smi,
                    Register scratch) override;
  void ArrayStoreBarrier(Register object,
                         Register slot,
                         Register value,
                         CanBeSmi can_be_smi,
                         Register scratch) override;
  void VerifyStoreNeedsNoWriteBarrier(Register object, Register value) override;

  // Stores a non-tagged value into a heap object.
  void StoreInternalPointer(Register object,
                            const Address& dest,
                            Register value);

  // Stores a Smi value into a heap object field that always contains a Smi.
  void StoreIntoSmiField(const Address& dest, Register value);
  void ZeroInitSmiField(const Address& dest);
  // Increments a Smi field. Leaves flags in same state as an 'addl'.
  void IncrementSmiField(const Address& dest, int32_t increment);

  void DoubleNegate(XmmRegister d);
  void FloatNegate(XmmRegister f);

  void DoubleAbs(XmmRegister reg);

  void LockCmpxchgl(const Address& address, Register reg) {
    lock();
    cmpxchgl(address, reg);
  }

  void EnterFrame(intptr_t frame_space);
  void LeaveFrame();
  void ReserveAlignedFrameSpace(intptr_t frame_space);

  void MonomorphicCheckedEntryJIT();
  void MonomorphicCheckedEntryAOT();
  void BranchOnMonomorphicCheckedEntryJIT(Label* label);

  void CombineHashes(Register dst, Register other) override;
  void FinalizeHashForSize(intptr_t bit_size,
                           Register dst,
                           Register scratch = kNoRegister) override;

  // In debug mode, this generates code to check that:
  //   FP + kExitLinkSlotFromEntryFp == SP
  // or triggers breakpoint otherwise.
  //
  // Clobbers EAX.
  void EmitEntryFrameVerification();

  // Transitions safepoint and Thread state between generated and native code.
  // Updates top-exit-frame info, VM tag and execution-state. Leaves/enters a
  // safepoint.
  //
  // Require a temporary register 'tmp'.
  // Clobber all non-CPU registers (e.g. XMM registers and the "FPU stack").
  // However XMM0 is saved for convenience.
  void TransitionGeneratedToNative(Register destination_address,
                                   Register new_exit_frame,
                                   Register new_exit_through_ffi,
                                   bool enter_safepoint);
  void TransitionNativeToGenerated(Register scratch,
                                   bool exit_safepoint,
                                   bool set_tag = true);
  void EnterFullSafepoint(Register scratch);
  void ExitFullSafepoint(Register scratch);

  // For non-leaf runtime calls. For leaf runtime calls, use LeafRuntimeScope,
  void CallRuntime(const RuntimeEntry& entry, intptr_t argument_count);

  void Call(const Code& code,
            bool movable_target = false,
            CodeEntryKind entry_kind = CodeEntryKind::kNormal);
  // Will not clobber any registers and can therefore be called with 5 live
  // registers.
  void CallVmStub(const Code& code);

  void Call(Address target) { call(target); }

  void CallCFunction(Address target) { Call(target); }

  void CallCFunction(Register target) { call(target); }

  void Jmp(const Code& code);
  void J(Condition condition, const Code& code);

  void RangeCheck(Register value,
                  Register temp,
                  intptr_t low,
                  intptr_t high,
                  RangeCheckCondition condition,
                  Label* target) override;

  /*
   * Loading and comparing classes of objects.
   */
  void LoadClassId(Register result, Register object);

  void LoadClassById(Register result, Register class_id);

  void CompareClassId(Register object, intptr_t class_id, Register scratch);

  void LoadClassIdMayBeSmi(Register result, Register object);
  void LoadTaggedClassIdMayBeSmi(Register result, Register object);
  void EnsureHasClassIdInDEBUG(intptr_t cid,
                               Register src,
                               Register scratch,
                               bool can_be_null = false) override;

  void SmiUntagOrCheckClass(Register object,
                            intptr_t class_id,
                            Register scratch,
                            Label* is_smi);

  static bool AddressCanHoldConstantIndex(const Object& constant,
                                          bool is_external,
                                          intptr_t cid,
                                          intptr_t index_scale);

  static Address ElementAddressForIntIndex(bool is_external,
                                           intptr_t cid,
                                           intptr_t index_scale,
                                           Register array,
                                           intptr_t index,
                                           intptr_t extra_disp = 0);

  static Address ElementAddressForRegIndex(bool is_external,
                                           intptr_t cid,
                                           intptr_t index_scale,
                                           bool index_unboxed,
                                           Register array,
                                           Register index,
                                           intptr_t extra_disp = 0);

  void LoadStaticFieldAddress(Register address,
                              Register field,
                              Register scratch,
                              bool is_shared) {
    LoadFieldFromOffset(scratch, field,
                        target::Field::host_offset_or_field_id_offset());
    const intptr_t field_table_offset =
        is_shared ? compiler::target::Thread::shared_field_table_values_offset()
                  : compiler::target::Thread::field_table_values_offset();
    LoadMemoryValue(address, THR, static_cast<int32_t>(field_table_offset));
    static_assert(kSmiTagShift == 1, "adjust scale factor");
    leal(address, Address(address, scratch, TIMES_HALF_WORD_SIZE, 0));
  }

  void LoadFieldAddressForRegOffset(Register address,
                                    Register instance,
                                    Register offset_in_words_as_smi) override {
    static_assert(kSmiTagShift == 1, "adjust scale factor");
    leal(address, FieldAddress(instance, offset_in_words_as_smi, TIMES_2, 0));
  }

  void LoadFieldAddressForOffset(Register address,
                                 Register instance,
                                 int32_t offset) override {
    leal(address, FieldAddress(instance, offset));
  }

  static Address VMTagAddress() {
    return Address(THR, target::Thread::vm_tag_offset());
  }

  /*
   * Misc. functionality
   */
  void SmiTag(Register reg) override { addl(reg, reg); }

  void SmiUntag(Register reg) { sarl(reg, Immediate(kSmiTagSize)); }

  // Truncates upper bits.
  void LoadInt32FromBoxOrSmi(Register result, Register value) override {
    if (result != value) {
      MoveRegister(result, value);
      value = result;
    }
    ASSERT(value == result);
    compiler::Label done;
    SmiUntag(result);  // Leaves CF after SmiUntag.
    j(NOT_CARRY, &done, compiler::Assembler::kNearJump);
    // Undo untagging by multiplying value by 2.
    // [reg + reg + disp8] has a shorter encoding than [reg*2 + disp32]
    COMPILE_ASSERT(kSmiTagShift == 1);
    movl(result, compiler::Address(result, result, TIMES_1,
                                   target::Mint::value_offset()));
    Bind(&done);
  }

  void BranchIfNotSmi(Register reg,
                      Label* label,
                      JumpDistance distance = kFarJump) {
    testl(reg, Immediate(kSmiTagMask));
    j(NOT_ZERO, label, distance);
  }

  void BranchIfSmi(Register reg,
                   Label* label,
                   JumpDistance distance = kFarJump) override {
    testl(reg, Immediate(kSmiTagMask));
    j(ZERO, label, distance);
  }

  void ArithmeticShiftRightImmediate(Register dst,
                                     Register src,
                                     int32_t shift,
                                     OperandSize sz = kFourBytes) override {
    ASSERT(IsSignedOperand(sz));
    ASSERT((shift >= 0) && (shift < OperandSizeInBits(sz)));
    ExtendValue(dst, src, sz);
    if (shift != 0) {
      sarl(dst, Immediate(shift));
    }
  }
  void ArithmeticShiftRightImmediate(Register reg,
                                     int32_t shift,
                                     OperandSize sz = kFourBytes) override {
    ArithmeticShiftRightImmediate(reg, reg, shift, sz);
  }
  void CompareWords(Register reg1,
                    Register reg2,
                    intptr_t offset,
                    Register count,
                    Register temp,
                    Label* equals) override;

  void Align(intptr_t alignment, intptr_t offset);
  void Bind(Label* label) override;
  void Jump(Label* label, JumpDistance distance = kFarJump) {
    jmp(label, distance);
  }
  // Unconditional jump to a given address in register.
  void Jump(Register target) { jmp(target); }

  // Moves one word from the memory at [from] to the memory at [to].
  // Needs a temporary register.
  void MoveMemoryToMemory(Address to, Address from, Register tmp);

  // Set up a Dart frame on entry with a frame pointer and PC information to
  // enable easy access to the RawInstruction object of code corresponding
  // to this frame.
  // The dart frame layout is as follows:
  //   ....
  //   ret PC
  //   saved EBP     <=== EBP
  //   pc (used to derive the RawInstruction Object of the dart code)
  //   locals space  <=== ESP
  //   .....
  // This code sets this up with the sequence:
  //   pushl ebp
  //   movl ebp, esp
  //   call L
  //   L: <code to adjust saved pc if there is any intrinsification code>
  //   .....
  void EnterDartFrame(intptr_t frame_size);
  void LeaveDartFrame();

  // Set up a Dart frame for a function compiled for on-stack replacement.
  // The frame layout is a normal Dart frame, but the frame is partially set
  // up on entry (it is the frame of the unoptimized code).
  void EnterOsrFrame(intptr_t extra_size);

  // Set up a stub frame so that the stack traversal code can easily identify
  // a stub frame.
  // The stub frame layout is as follows:
  //   ....
  //   ret PC
  //   saved EBP
  //   0 (used to indicate frame is a stub frame)
  //   .....
  // This code sets this up with the sequence:
  //   pushl ebp
  //   movl ebp, esp
  //   pushl immediate(0)
  //   .....
  void EnterStubFrame();
  void LeaveStubFrame();
  static constexpr intptr_t kEnterStubFramePushedWords = 2;

  // Set up a frame for calling a C function.
  // Automatically save the pinned registers in Dart which are not callee-
  // saved in the native calling convention.
  // Use together with CallCFunction.
  void EnterCFrame(intptr_t frame_space);
  void LeaveCFrame();

  // Instruction pattern from entrypoint is used in dart frame prologs
  // to set up the frame and save a PC which can be used to figure out the
  // RawInstruction object corresponding to the code running in the frame.
  // entrypoint:
  //   pushl ebp          (size is 1 byte)
  //   movl ebp, esp      (size is 2 bytes)
  //   call L             (size is 5 bytes)
  //   L:
  static constexpr intptr_t kEntryPointToPcMarkerOffset = 8;
  static intptr_t EntryPointToPcMarkerOffset() {
    return kEntryPointToPcMarkerOffset;
  }

  // If allocation tracing for |cid| is enabled, will jump to |trace| label,
  // which will allocate in the runtime where tracing occurs.
  void MaybeTraceAllocation(intptr_t cid,
                            Label* trace,
                            Register temp_reg,
                            JumpDistance distance = JumpDistance::kFarJump);

  void TryAllocateObject(intptr_t cid,
                         intptr_t instance_size,
                         Label* failure,
                         JumpDistance distance,
                         Register instance_reg,
                         Register temp_reg) override;

  void TryAllocateArray(intptr_t cid,
                        intptr_t instance_size,
                        Label* failure,
                        JumpDistance distance,
                        Register instance,
                        Register end_address,
                        Register temp);

  void CheckAllocationCanary(Register top) {
#if defined(DEBUG)
    Label okay;
    cmpl(Address(top, 0), Immediate(kAllocationCanary));
    j(EQUAL, &okay, Assembler::kNearJump);
    Stop("Allocation canary");
    Bind(&okay);
#endif
  }
  void WriteAllocationCanary(Register top) {
#if defined(DEBUG)
    movl(Address(top, 0), Immediate(kAllocationCanary));
#endif
  }

  // Copy [size] bytes from [src] address to [dst] address.
  // [size] should be a multiple of word size.
  // Clobbers [src], [dst], [size] and [temp] registers.
  // IA32 requires fixed registers for memory copying:
  // [src] = ESI, [dst] = EDI, [size] = ECX.
  void CopyMemoryWords(Register src,
                       Register dst,
                       Register size,
                       Register temp = kNoRegister);

  // Debugging and bringup support.
  void Breakpoint() override { int3(); }

  // Check if the given value is an integer value that can be directly
  // embedded into the code without additional XORing with jit_cookie.
  // We consider 16-bit integers, powers of two and corresponding masks
  // as safe values that can be embedded into the code object.
  static bool IsSafeSmi(const Object& object) {
    if (!target::IsSmi(object)) {
      return false;
    }
    int64_t value;
    if (HasIntegerValue(object, &value)) {
      return Utils::IsInt(16, value) || Utils::IsPowerOfTwo(value) ||
             Utils::IsPowerOfTwo(value + 1);
    }
    return false;
  }
  static bool IsSafe(const Object& object) {
    return !target::IsSmi(object) || IsSafeSmi(object);
  }

  Object& GetSelfHandle() const { return code_; }

  void PushCodeObject();

 private:
  void Alu(int bytes, uint8_t opcode, Register dst, Register src);
  void Alu(uint8_t modrm_opcode, Register dst, const Immediate& imm);
  void Alu(int bytes, uint8_t opcode, Register dst, const Address& src);
  void Alu(int bytes, uint8_t opcode, const Address& dst, Register src);
  void Alu(uint8_t modrm_opcode, const Address& dst, const Immediate& imm);

  inline void EmitUint8(uint8_t value);
  inline void EmitInt32(int32_t value);
  inline void EmitRegisterOperand(int rm, int reg);
  inline void EmitXmmRegisterOperand(int rm, XmmRegister reg);
  inline void EmitFixup(AssemblerFixup* fixup);
  inline void EmitOperandSizeOverride();

  void EmitOperand(int rm, const Operand& operand);
  void EmitImmediate(const Immediate& imm);
  void EmitComplex(int rm, const Operand& operand, const Immediate& immediate);
  void EmitLabel(Label* label, intptr_t instruction_size);
  void EmitLabelLink(Label* label);
  void EmitNearLabelLink(Label* label);

  void EmitGenericShift(int rm, Register reg, const Immediate& imm);
  void EmitGenericShift(int rm, const Operand& operand, Register shifter);

  int32_t jit_cookie();

  int32_t jit_cookie_;
  Object& code_;

  DISALLOW_ALLOCATION();
  DISALLOW_COPY_AND_ASSIGN(Assembler);
};

inline void Assembler::EmitUint8(uint8_t value) {
  buffer_.Emit<uint8_t>(value);
}

inline void Assembler::EmitInt32(int32_t value) {
  buffer_.Emit<int32_t>(value);
}

inline void Assembler::EmitRegisterOperand(int rm, int reg) {
  ASSERT(rm >= 0 && rm < 8);
  buffer_.Emit<uint8_t>(0xC0 + (rm << 3) + reg);
}

inline void Assembler::EmitXmmRegisterOperand(int rm, XmmRegister reg) {
  EmitRegisterOperand(rm, static_cast<Register>(reg));
}

inline void Assembler::EmitFixup(AssemblerFixup* fixup) {
  buffer_.EmitFixup(fixup);
}

inline void Assembler::EmitOperandSizeOverride() {
  EmitUint8(0x66);
}

}  // namespace compiler
}  // namespace dart

#endif  // RUNTIME_VM_COMPILER_ASSEMBLER_ASSEMBLER_IA32_H_
