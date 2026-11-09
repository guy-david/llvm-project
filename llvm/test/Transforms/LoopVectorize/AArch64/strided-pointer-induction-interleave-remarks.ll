; RUN: opt -passes=loop-vectorize -force-vector-width=16 -force-vector-interleave=1 -pass-remarks-output=- -disable-output %s \
; RUN:   | FileCheck %s --implicit-check-not="Name: Vectorized"
; RUN: opt -passes=loop-vectorize -force-vector-width=1 -force-vector-interleave=4 -pass-remarks-output=- -disable-output %s \
; RUN:   | FileCheck %s --check-prefix=VF1
; RUN: opt -passes=loop-vectorize -force-vector-width=16 -force-vector-interleave=1 -max-interleave-group-factor=2 -pass-remarks-output=- -disable-output %s \
; RUN:   | FileCheck %s --check-prefix=MAXF2
; RUN: opt -passes=loop-vectorize -force-vector-width=16 -force-vector-interleave=1 -max-interleave-group-factor=3 -pass-remarks-output=- -disable-output %s \
; RUN:   | FileCheck %s --check-prefix=MAXF3

target triple = "aarch64-unknown-linux-gnu"

; CHECK-LABEL: Function: single_access{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @single_access(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %b = load i8, ptr %p, align 1
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: gap{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @gap(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p2, align 1
  %b = add i8 %x, %y
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: negative_offset{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @negative_offset(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %pm1 = getelementptr inbounds i8, ptr %p, i64 -1
  %x = load i8, ptr %pm1, align 1
  %y = load i8, ptr %p, align 1
  %b = add i8 %x, %y
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: mixed_sizes{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @mixed_sizes(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z16 = load i16, ptr %p2, align 1
  %z = trunc i16 %z16 to i8
  %a = add i8 %x, %y
  %b = add i8 %a, %z
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: misaligned{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @misaligned(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p3 = getelementptr inbounds i8, ptr %p, i64 3
  %x = load i16, ptr %p, align 1
  %y = load i16, ptr %p3, align 1
  %a = add i16 %x, %y
  %b = trunc i16 %a to i8
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: scalable_access{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @scalable_access(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %v = load <vscale x 16 x i8>, ptr %p, align 1
  %b = extractelement <vscale x 16 x i8> %v, i64 0
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: zero_size{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @zero_size(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %e = load {}, ptr %p, align 1
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %b = add i8 %x, %y
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: stride_out_of_range{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @stride_out_of_range(ptr noalias %d, ptr noalias %s, i64 %n, i2 %st2) {
entry:
  %st = sext i2 %st2 to i64
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %b = add i8 %x, %y
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: non_symbolic_step{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @non_symbolic_step(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st0) {
entry:
  %st = shl i64 %st0, 1
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  %a = add i8 %x, %y
  %b = add i8 %a, %z
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: conflicting_spans{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @conflicting_spans(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %q = phi ptr [ %d, %entry ], [ %q.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  %a = add i8 %x, %y
  %q1 = getelementptr inbounds i8, ptr %q, i64 1
  store i8 %a, ptr %q, align 1
  store i8 %z, ptr %q1, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %q.next = getelementptr inbounds i8, ptr %q, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: stride_ruled_out_by_guard{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @stride_ruled_out_by_guard(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  %c = icmp eq i64 %st, 4
  br i1 %c, label %loop, label %exit
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  %a = add i8 %x, %y
  %b = add i8 %a, %z
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: stride_at_least_trip_count{{$}}
; CHECK:         - String: pointer induction with a non-constant step could not be vectorized
define void @stride_at_least_trip_count(ptr noalias %d, ptr noalias %s, i8 %st8) {
entry:
  %o = or i8 %st8, 2
  %st = zext i8 %o to i64
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %i2 = shl i64 %i, 1
  %q = getelementptr inbounds i8, ptr %d, i64 %i2
  %q1 = getelementptr inbounds i8, ptr %q, i64 1
  store i8 %x, ptr %q, align 1
  store i8 %y, ptr %q1, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, 2
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: load_and_store{{$}}
; CHECK:         - String: accesses with a speculated stride are not vectorized as interleave groups
define void @load_and_store(ptr %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %x = load i8, ptr %p, align 1
  %a = add i8 %x, 1
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  store i8 %a, ptr %p1, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: dependence_inside_group{{$}}
; CHECK:         - String: accesses with a speculated stride are not vectorized as interleave groups
define void @dependence_inside_group(ptr %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  store i8 %x, ptr %p2, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  store i8 %y, ptr %p, align 1
  store i8 %z, ptr %p1, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

; CHECK-LABEL: Function: tail_folded{{$}}
; CHECK:         - String: accesses with a speculated stride are not vectorized as interleave groups
define void @tail_folded(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  %a = add i8 %x, %y
  %b = add i8 %a, %z
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop, !llvm.loop !0
exit:
  ret void
}

; CHECK-LABEL: Function: interleave_only{{$}}
; CHECK:       Name: Vectorized
; VF1-LABEL: Function: interleave_only{{$}}
; VF1:         - String: accesses with a speculated stride are not vectorized as interleave groups
; MAXF2-LABEL: Function: interleave_only{{$}}
; MAXF2:         - String: pointer induction with a non-constant step could not be vectorized
; MAXF3-LABEL: Function: interleave_only{{$}}
; MAXF3:       Name: Vectorized
define void @interleave_only(ptr noalias %d, ptr noalias %s, i64 %n, i64 %st) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %p = phi ptr [ %s, %entry ], [ %p.next, %loop ]
  %p1 = getelementptr inbounds i8, ptr %p, i64 1
  %p2 = getelementptr inbounds i8, ptr %p, i64 2
  %x = load i8, ptr %p, align 1
  %y = load i8, ptr %p1, align 1
  %z = load i8, ptr %p2, align 1
  %a = add i8 %x, %y
  %b = add i8 %a, %z
  %q = getelementptr inbounds i8, ptr %d, i64 %i
  store i8 %b, ptr %q, align 1
  %p.next = getelementptr inbounds i8, ptr %p, i64 %st
  %i.next = add i64 %i, 1
  %ec = icmp eq i64 %i.next, %n
  br i1 %ec, label %exit, label %loop
exit:
  ret void
}

!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.vectorize.predicate.enable"}
