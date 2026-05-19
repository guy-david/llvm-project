//===- AArch64CodeGenPrepare.cpp ------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// AArch64-specific IR-level pre-codegen transformations.
//
//  widenCrossBlockBoolVectorChains
//  -------------------------------
//  The DAG type-legalizer commits to a single promoted MVT for <N x i1>
//  globally, so at a phi <N x i1> where predecessors compute the mask from
//  different source widths the legalizer cannot adapt per producer. The
//  consequence is XTN/SSHLL sequences emitted at every producer that doesn't
//  match the chosen width.
//
//  This pass identifies connected boolean-vector-op chains (cmps,
//  and/or/xor, shufflevector, phi on <N x i1>) that contain a phi <N x i1>,
//  picks the *widest* element bit-width among the chain's producer compares,
//  and rewrites the chain on <N x iSrcWidth>. Because that width is itself a
//  legal vector type, the type legalizer leaves the chain alone and no
//  XTN/SSHLL is emitted along the chain. Re-narrowing happens only at the
//  boundary where some non-chain user still expects <N x i1>.
//
//===----------------------------------------------------------------------===//

#include "AArch64.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/InitializePasses.h"
#include "llvm/Pass.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "aarch64-codegenprepare"
#define PASS_NAME "AArch64 CodeGenPrepare"

static cl::opt<bool> EnableWidenCrossBlockBoolVec(
    "aarch64-enable-widen-cross-block-bool-vec",
    cl::desc("Pre-widen <N x i1> chains that span block boundaries to their "
             "natural producer width before SelectionDAG."),
    cl::init(true), cl::Hidden);

namespace {

static bool isBoolVectorTy(Type *Ty) {
  auto *VT = dyn_cast<FixedVectorType>(Ty);
  return VT && VT->getElementType()->isIntegerTy(1);
}

/// Members of a widenable boolean-vector chain. All values have the same
/// element count (NumElts) and produce <NumElts x i1>.
static bool isChainMember(Value *V, unsigned NumElts) {
  if (!isBoolVectorTy(V->getType()))
    return false;
  if (cast<FixedVectorType>(V->getType())->getNumElements() != NumElts)
    return false;
  // Producer compares.
  if (isa<CmpInst>(V))
    return true;
  // In-chain ops: phi, and/or/xor, shufflevector.
  auto *I = dyn_cast<Instruction>(V);
  if (!I)
    return false;
  if (isa<PHINode>(I) || isa<ShuffleVectorInst>(I))
    return true;
  switch (I->getOpcode()) {
  case Instruction::And:
  case Instruction::Or:
  case Instruction::Xor:
    return true;
  default:
    return false;
  }
}

/// Return the element bit-width of a producer compare's source operand,
/// or 0 if not applicable.
static unsigned getCmpSourceWidth(CmpInst *C) {
  Type *SrcTy = C->getOperand(0)->getType();
  if (auto *VT = dyn_cast<FixedVectorType>(SrcTy))
    return VT->getElementType()->getPrimitiveSizeInBits();
  return 0;
}

class AArch64CodeGenPrepare {
  Function &F;

public:
  AArch64CodeGenPrepare(Function &F) : F(F) {}

  bool run() {
    if (!EnableWidenCrossBlockBoolVec)
      return false;
    return widenCrossBlockBoolVectorChains();
  }

private:
  bool widenCrossBlockBoolVectorChains();

  /// Discover the chain reachable from `Seed` by walking def-use edges
  /// through chain members of the same NumElts.
  void collectChain(Value *Seed, unsigned NumElts,
                    DenseSet<Value *> &Members);

  /// Rewrite the chain to operate on <NumElts x WideEltTy>.
  void applyWidening(const DenseSet<Value *> &Members, unsigned NumElts,
                     Type *WideEltTy);
};

} // namespace

void AArch64CodeGenPrepare::collectChain(Value *Seed, unsigned NumElts,
                                         DenseSet<Value *> &Members) {
  SmallVector<Value *, 32> Worklist;
  Worklist.push_back(Seed);
  while (!Worklist.empty()) {
    Value *V = Worklist.pop_back_val();
    if (!isChainMember(V, NumElts))
      continue;
    if (!Members.insert(V).second)
      continue;
    // Forward: users.
    for (User *U : V->users())
      if (isChainMember(U, NumElts))
        Worklist.push_back(U);
    // Backward: operands of instructions.
    if (auto *I = dyn_cast<Instruction>(V))
      for (Value *Op : I->operands())
        if (isChainMember(Op, NumElts))
          Worklist.push_back(Op);
  }
}

bool AArch64CodeGenPrepare::widenCrossBlockBoolVectorChains() {
  // True if `I`'s value crosses a basic-block boundary: either the
  // instruction is itself a PHI (the canonical merge), or any of its users
  // lives in a different block. This is the property that makes the DAG
  // type-legalizer's global, per-MVT promotion choice load-bearing for the
  // chain (it cannot adapt per producer at the boundary).
  auto crossesBlock = [](Instruction *I) -> bool {
    if (isa<PHINode>(I))
      return true;
    BasicBlock *DefBB = I->getParent();
    for (User *U : I->users())
      if (auto *UI = dyn_cast<Instruction>(U))
        if (UI->getParent() != DefBB)
          return true;
    return false;
  };

  // Snapshot of all chain-member instructions; iterating live IR would risk
  // iterator invalidation when applyWidening inserts new instructions.
  SmallVector<Instruction *, 32> Seeds;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (isBoolVectorTy(I.getType()))
        Seeds.push_back(&I);
  if (Seeds.empty())
    return false;

  DenseSet<Value *> AllProcessed;
  bool Changed = false;

  for (Instruction *Seed : Seeds) {
    if (AllProcessed.count(Seed))
      continue;
    auto *VT = dyn_cast<FixedVectorType>(Seed->getType());
    if (!VT)
      continue;
    unsigned NumElts = VT->getNumElements();
    if (!isChainMember(Seed, NumElts))
      continue;

    // Build the connected chain reachable from `Seed`.
    DenseSet<Value *> Members;
    collectChain(Seed, NumElts, Members);
    if (Members.empty())
      continue;

    // Mark every member processed regardless of whether we widen.
    for (Value *V : Members)
      AllProcessed.insert(V);

    // Trigger only if the chain has any cross-block member.
    bool HasCrossBlock = false;
    for (Value *V : Members)
      if (auto *I = dyn_cast<Instruction>(V))
        if (crossesBlock(I)) {
          HasCrossBlock = true;
          break;
        }
    if (!HasCrossBlock)
      continue;

    // Find producer compares and the widest source width among them.
    // Pick wider per the project policy for mixed-source chains.
    unsigned MaxSrcWidth = 0;
    for (Value *V : Members)
      if (auto *C = dyn_cast<CmpInst>(V))
        MaxSrcWidth = std::max(MaxSrcWidth, getCmpSourceWidth(C));
    if (MaxSrcWidth == 0 || MaxSrcWidth == 1)
      continue;

    Type *WideEltTy = IntegerType::get(F.getContext(), MaxSrcWidth);

    LLVM_DEBUG({
      dbgs() << "AArch64CodeGenPrepare: widening cross-block <" << NumElts
             << " x i1> chain (" << Members.size() << " members) in @"
             << F.getName() << " to <" << NumElts << " x i" << MaxSrcWidth
             << ">\n";
    });
    applyWidening(Members, NumElts, WideEltTy);
    Changed = true;
  }

  return Changed;
}

void AArch64CodeGenPrepare::applyWidening(const DenseSet<Value *> &Members,
                                          unsigned NumElts, Type *WideEltTy) {
  Type *WideTy = FixedVectorType::get(WideEltTy, NumElts);

  // Map original chain values to their wide replacements.
  DenseMap<Value *, Value *> Wide;
  // Instructions we created (not to be re-narrowed).
  DenseSet<Instruction *> Created;

  // --- Phase 1: create wide replacements without filling PHI operands. ---
  // PHI placeholders are needed first to break back-edge cycles.
  SmallVector<std::pair<PHINode *, PHINode *>, 8> PhiPairs;
  for (Value *V : Members) {
    if (auto *PN = dyn_cast<PHINode>(V)) {
      PHINode *WidePN = PHINode::Create(WideTy, PN->getNumIncomingValues(),
                                        PN->getName() + ".wide");
      WidePN->insertBefore(PN->getIterator());
      Wide[PN] = WidePN;
      Created.insert(WidePN);
      PhiPairs.push_back({PN, WidePN});
    }
  }

  // Producer cmps: widen result via sext to WideTy.
  for (Value *V : Members) {
    if (auto *C = dyn_cast<CmpInst>(V)) {
      IRBuilder<> B(C->getNextNode());
      Value *Ext = B.CreateSExt(C, WideTy, C->getName() + ".wide");
      Wide[C] = Ext;
      if (auto *I = dyn_cast<Instruction>(Ext))
        Created.insert(I);
    }
  }

  // Helper: get wide form of an operand. If the operand is a chain member,
  // its wide form must already be in `Wide`; the caller is responsible for
  // ordering (handled by the fixed-point loop in Phase 3). For non-chain
  // operands (constants and outside values) insert a sext on the spot.
  auto getWide = [&](Value *Op, IRBuilder<> &B) -> Value * {
    if (auto It = Wide.find(Op); It != Wide.end())
      return It->second;
    Value *E = B.CreateSExt(Op, WideTy);
    if (auto *I = dyn_cast<Instruction>(E))
      Created.insert(I);
    return E;
  };

  // --- Phase 2: widen non-PHI chain ops (and/or/xor, shufflevector) using a
  // fixed-point loop. Every chain-member operand must already be in `Wide`
  // before we rewrite a node.
  auto isChainOp = [&](Value *V) -> bool { return Members.count(V); };
  SmallVector<Value *, 32> Pending;
  for (Value *V : Members) {
    if (Wide.count(V))
      continue; // PHI or cmp already handled in Phase 1.
    if (auto *I = dyn_cast<Instruction>(V)) {
      if (isa<ShuffleVectorInst>(I) || I->getOpcode() == Instruction::And ||
          I->getOpcode() == Instruction::Or || I->getOpcode() == Instruction::Xor)
        Pending.push_back(I);
    }
  }

  bool Progress = true;
  while (Progress && !Pending.empty()) {
    Progress = false;
    SmallVector<Value *, 32> Next;
    for (Value *V : Pending) {
      auto *I = cast<Instruction>(V);
      // All chain-member operands must be ready.
      bool Ready = true;
      for (Value *Op : I->operands()) {
        if (isChainOp(Op) && !Wide.count(Op)) {
          Ready = false;
          break;
        }
      }
      if (!Ready) {
        Next.push_back(V);
        continue;
      }
      Progress = true;

      if (auto *SVI = dyn_cast<ShuffleVectorInst>(I)) {
        IRBuilder<> B(SVI->getNextNode());
        Value *W0 = getWide(SVI->getOperand(0), B);
        Value *Op1 = SVI->getOperand(1);
        Value *W1;
        if (isa<PoisonValue>(Op1) || isa<UndefValue>(Op1))
          W1 = PoisonValue::get(WideTy);
        else
          W1 = getWide(Op1, B);
        Value *Shuf = B.CreateShuffleVector(W0, W1, SVI->getShuffleMask(),
                                            SVI->getName() + ".wide");
        Wide[SVI] = Shuf;
        if (auto *WI = dyn_cast<Instruction>(Shuf))
          Created.insert(WI);
        continue;
      }

      IRBuilder<> B(I->getNextNode());
      Value *W0 = getWide(I->getOperand(0), B);
      Value *W1 = getWide(I->getOperand(1), B);
      Value *WideRes;
      switch (I->getOpcode()) {
      case Instruction::And:
        WideRes = B.CreateAnd(W0, W1, I->getName() + ".wide");
        break;
      case Instruction::Or:
        WideRes = B.CreateOr(W0, W1, I->getName() + ".wide");
        break;
      case Instruction::Xor:
        WideRes = B.CreateXor(W0, W1, I->getName() + ".wide");
        break;
      default:
        llvm_unreachable("filtered above");
      }
      Wide[I] = WideRes;
      if (auto *WI = dyn_cast<Instruction>(WideRes))
        Created.insert(WI);
    }
    Pending = std::move(Next);
  }
  // Anything left in Pending could not be resolved — unexpected, bail out.
  if (!Pending.empty())
    return;

  // --- Phase 3: fill in PHI incoming values. ---
  for (auto &[OrigPN, WidePN] : PhiPairs) {
    for (unsigned i = 0; i < OrigPN->getNumIncomingValues(); ++i) {
      Value *Inc = OrigPN->getIncomingValue(i);
      BasicBlock *PredBB = OrigPN->getIncomingBlock(i);
      Value *WInc;
      if (auto It = Wide.find(Inc); It != Wide.end()) {
        WInc = It->second;
      } else {
        // Outside the chain: sext at the predecessor terminator.
        IRBuilder<> B(PredBB->getTerminator());
        WInc = B.CreateSExt(Inc, WideTy);
        if (auto *I = dyn_cast<Instruction>(WInc))
          Created.insert(I);
      }
      WidePN->addIncoming(WInc, PredBB);
    }
  }

  // --- Phase 4: replace external uses of original chain values with a
  // re-narrowed (icmp slt 0) version. ---
  DenseMap<Value *, Value *> NarrowCache;
  for (auto &KV : Wide) {
    Value *Orig = KV.first;
    Value *W = KV.second;

    SmallVector<Use *, 8> ExtUses;
    for (Use &U : Orig->uses()) {
      auto *User = dyn_cast<Instruction>(U.getUser());
      if (!User)
        continue;
      if (Created.count(User))
        continue;
      if (Wide.count(User))
        continue;
      ExtUses.push_back(&U);
    }
    if (ExtUses.empty())
      continue;

    Value *Narrow;
    if (auto It = NarrowCache.find(W); It != NarrowCache.end()) {
      Narrow = It->second;
    } else {
      // Pick an insertion point that dominates all uses.
      BasicBlock::iterator InsertIt;
      if (auto *WI = dyn_cast<Instruction>(W)) {
        if (auto *WPN = dyn_cast<PHINode>(WI))
          InsertIt = WPN->getParent()->getFirstNonPHIIt();
        else if (Instruction *Next = WI->getNextNode())
          InsertIt = Next->getIterator();
        else
          continue;
      } else {
        continue;
      }
      IRBuilder<> B(InsertIt->getParent(), InsertIt);
      Narrow = B.CreateICmpSLT(W, Constant::getNullValue(WideTy),
                               Orig->getName() + ".narrow");
      NarrowCache[W] = Narrow;
      if (auto *I = dyn_cast<Instruction>(Narrow))
        Created.insert(I);
    }
    for (Use *U : ExtUses)
      U->set(Narrow);
  }

  // --- Phase 5: erase dead originals. ---
  SmallVector<Instruction *, 16> Dead;
  for (auto &KV : Wide) {
    if (auto *I = dyn_cast<Instruction>(KV.first))
      if (I->use_empty() && !Created.count(I))
        Dead.push_back(I);
  }
  for (Instruction *I : llvm::reverse(Dead))
    if (I->use_empty())
      I->eraseFromParent();
}

namespace {
class AArch64CodeGenPrepareLegacyPass : public FunctionPass {
public:
  static char ID;
  AArch64CodeGenPrepareLegacyPass() : FunctionPass(ID) {}
  bool runOnFunction(Function &F) override {
    if (skipFunction(F))
      return false;
    return AArch64CodeGenPrepare(F).run();
  }
  StringRef getPassName() const override { return PASS_NAME; }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesCFG();
  }
};
} // namespace

INITIALIZE_PASS(AArch64CodeGenPrepareLegacyPass, DEBUG_TYPE, PASS_NAME, false,
                false)

char AArch64CodeGenPrepareLegacyPass::ID = 0;

FunctionPass *llvm::createAArch64CodeGenPrepareLegacyPass() {
  return new AArch64CodeGenPrepareLegacyPass();
}

PreservedAnalyses AArch64CodeGenPreparePass::run(Function &F,
                                                 FunctionAnalysisManager &) {
  bool Changed = AArch64CodeGenPrepare(F).run();
  if (!Changed)
    return PreservedAnalyses::all();
  PreservedAnalyses PA = PreservedAnalyses::none();
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
