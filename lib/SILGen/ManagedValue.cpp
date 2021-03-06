//===--- ManagedValue.cpp - Value with cleanup ----------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// A storage structure for holding a destructured rvalue with an optional
// cleanup(s).
// Ownership of the rvalue can be "forwarded" to disable the associated
// cleanup(s).
//
//===----------------------------------------------------------------------===//

#include "ManagedValue.h"
#include "SILGenFunction.h"
using namespace swift;
using namespace Lowering;

/// Emit a copy of this value with independent ownership.
ManagedValue ManagedValue::copy(SILGenFunction &gen, SILLocation l) {
  if (!cleanup.isValid()) {
    assert(gen.getTypeLowering(getType()).isTrivial());
    return *this;
  }
  
  auto &lowering = gen.getTypeLowering(getType());
  assert(!lowering.isTrivial() && "trivial value has cleanup?");
  
  if (!lowering.isAddressOnly()) {
    return gen.emitManagedRetain(l, getValue(), lowering);
  }
  
  SILValue buf = gen.emitTemporaryAllocation(l, getType());
  gen.B.createCopyAddr(l, getValue(), buf, IsNotTake, IsInitialization);
  return gen.emitManagedRValueWithCleanup(buf, lowering);
}

/// Store a copy of this value with independent ownership into the given
/// uninitialized address.
void ManagedValue::copyInto(SILGenFunction &gen, SILValue dest,
                            SILLocation loc) {
  auto &lowering = gen.getTypeLowering(getType());
  if (lowering.isAddressOnly()) {
    gen.B.createCopyAddr(loc, getValue(), dest, IsNotTake, IsInitialization);
    return;
  }

  SILValue copy = lowering.emitCopyValue(gen.B, loc, getValue());
  lowering.emitStoreOfCopy(gen.B, loc, copy, dest, IsInitialization);
}

/// This is the same operation as 'copy', but works on +0 values that don't
/// have cleanups.  It returns a +1 value with one.
ManagedValue ManagedValue::copyUnmanaged(SILGenFunction &gen, SILLocation loc) {
  auto &lowering = gen.getTypeLowering(getType());
  
  if (lowering.isTrivial())
    return *this;
  
  SILValue result;
  if (!lowering.isAddress()) {
    result = lowering.emitCopyValue(gen.B, loc, getValue());
  } else {
    result = gen.emitTemporaryAllocation(loc, getType());
    gen.B.createCopyAddr(loc, getValue(), result, IsNotTake,IsInitialization);
  }
  return gen.emitManagedRValueWithCleanup(result, lowering);
}

/// Disable the cleanup for this value.
void ManagedValue::forwardCleanup(SILGenFunction &gen) const {
  assert(hasCleanup() && "value doesn't have cleanup!");
  gen.Cleanups.forwardCleanup(getCleanup());
}

/// Forward this value, deactivating the cleanup and returning the
/// underlying value.
SILValue ManagedValue::forward(SILGenFunction &gen) const {
  if (hasCleanup())
    forwardCleanup(gen);
  return getValue();
}

void ManagedValue::forwardInto(SILGenFunction &gen, SILLocation loc,
                               SILValue address) {
  if (hasCleanup())
    forwardCleanup(gen);
  auto &addrTL = gen.getTypeLowering(address->getType());
  gen.emitSemanticStore(loc, getValue(), address, addrTL, IsInitialization);
}

void ManagedValue::assignInto(SILGenFunction &gen, SILLocation loc,
                              SILValue address) {
  if (hasCleanup())
    forwardCleanup(gen);
  
  auto &addrTL = gen.getTypeLowering(address->getType());
  gen.emitSemanticStore(loc, getValue(), address, addrTL,
                        IsNotInitialization);
}

ManagedValue ManagedValue::borrow(SILGenFunction &gen, SILLocation loc) const {
  assert(getValue() && "cannot borrow an invalid or in-context value");
  if (isLValue())
    return *this;
  if (getType().isAddress())
    return ManagedValue::forUnmanaged(getValue());
  return gen.emitManagedBeginBorrow(loc, getValue());
}

void BorrowedManagedValue::cleanupImpl() {
  if (!gen.B.hasValidInsertionPoint()) {
    handle.reset();
    return;
  }

  // We had a trivial or an address value so there isn't anything to
  // cleanup. Still be sure to unset borrowedValue though.
  if (!handle.hasValue()) {
    borrowedValue = ManagedValue();
    return;
  }

  assert(borrowedValue && "already cleaned up this object!?");

  CleanupHandle handleValue = handle.getValue();
  CleanupLocation cleanupLoc = CleanupLocation::get(loc);

  auto iter = gen.Cleanups.Stack.find(handleValue);
  assert(iter != gen.Cleanups.Stack.end() &&
         "can't change end of cleanups stack");

  Cleanup &cleanup = *iter;
  assert(cleanup.isActive() && "Cleanup emitted out of order?!");

  CleanupState newState =
      (cleanup.getState() == CleanupState::Active ? CleanupState::Dead
                                                  : CleanupState::Dormant);
  cleanup.emit(gen, cleanupLoc);
  gen.Cleanups.setCleanupState(cleanup, newState);

  borrowedValue = ManagedValue();
  handle.reset();
}

BorrowedManagedValue::BorrowedManagedValue(SILGenFunction &gen,
                                           ManagedValue originalValue,
                                           SILLocation loc)
    : gen(gen), borrowedValue(), handle(), loc(loc) {
  if (!originalValue)
    return;
  auto &lowering = gen.F.getTypeLowering(originalValue.getType());
  assert(lowering.getLoweredType().getObjectType() ==
         originalValue.getType().getObjectType());

  if (lowering.isTrivial()) {
    borrowedValue = ManagedValue::forUnmanaged(originalValue.getValue());
    return;
  }

  if (originalValue.getOwnershipKind() == ValueOwnershipKind::Guaranteed) {
    borrowedValue = ManagedValue::forUnmanaged(originalValue.getValue());
    return;
  }

  if (originalValue.getType().isAddress()) {
    borrowedValue = ManagedValue::forUnmanaged(originalValue.getValue());
    return;
  }

  SILValue borrowed = gen.B.createBeginBorrow(loc, originalValue.getValue());
  if (borrowed->getType().isObject())
    handle = gen.enterEndBorrowCleanup(originalValue.getValue(), borrowed);
  borrowedValue = ManagedValue(borrowed, CleanupHandle::invalid());
}
