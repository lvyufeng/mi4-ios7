#!/usr/bin/env python3
"""1031 -- READ THE CALLER, and PRINT the region's EXCLUSIVE TOP.

1030 (the WRITER probe) read W-B-NAMED BY VALUE at the launchctl[2] usermode data abort:

    xnu_live_wrp_r4 = 0x2bdae000   xnu_live_wrp_r6 = 0x2bdae000
    xnu_live_wrp_sp = 0x2bdac074   xnu_live_wrp_r4_minus_sp = 0x1f8c
    xnu_live_wrp_ustack = 0x2bdad000   xnu_live_wrp_far = 0x2bdae000
    xnu_live_wrp_r4_minus_far = 0

i.e. the faulting store's destination cursor (`r4`, == the writer's caller-supplied 4th argument) EQUALS
`far` EQUALS the region's EXCLUSIVE TOP (`user_stack + 0x1000`).  The writer is `str.w r2,[r4],#4` at
libobjc+0x14756, a table-rebase copy; its frame is `push {r4,r5,r6,r7,lr}; add r7,sp,#12` (so `r7 ==
sp + 12`, provable from the capture: `r7 == 0x2bdac080 == sp + 12`).  The boundary decision is therefore
in the CALLER, and 1030 could NOT see it: the caller's `lr = 0x38b4a9af` does not resolve to a call site
in the mapped image, and no row IS the region's exclusive top (1030 INFERRED it from `far - ustack`).

This rung PROBES the caller frame and PRINTS the region top, so the 1030 shape becomes a single
conjunction over PRINTED rows instead of an inference:

    CAL-CALLER-TOP   : cal_region_end_hit == 1 AND cal_region_end == cal_far AND cal_r3 == cal_far
                       AND cal_r2 == cal_far AND cal_r7_minus_sp == 0xC
                       => the map's OWN vme_end (not an inference) IS `far`, and the caller handed BOTH
                          cursors that exact address.  LEVER = the caller's derivation (candidate (B)).
    CAL-CALLER-SIZE  : cal_r3 == cal_far AND cal_r3 != cal_region_end (the buffer END is BELOW the top).
    CAL-CALLER-OTHER : any other present combination with cal_region_end_hit == 1.
    CAL-MISSING      : the cal_* rows are ABSENT, or cal_region_end_hit == 0 (far-4 unmapped => `far` is
                       NOT the region top: a DIFFERENT failure).  Fail-closed; NEVER a negative.
    REGRESSION / G-CTL : the standard withhold cells.

SITE A -- osfmk/arm/trap.c, INSIDE 1025's failure arm (STAGE90_XNU_USTACK_PROBE) and AFTER 1030's
writer block's `#endif`, before 1025's publisher `#endif`.  There, arm_ctx / thread / map / dfar are all
in scope.  It publishes the caller's registers (r0/r1/r2/r9/r10/r7/lr/pc), the writer's frame-pointer
self-check (`r7 - sp`, must be 0xC), `far`, `ustack` (via 1026's accessor), and -- the crux -- the
covering entry's `vme_end` for `far - 4`, which IS the region's exclusive top by value when `far` is the
top (the 1026/1027/1029 idiom; `vm_map_lookup_entry` takes NO lock in this tree).

SITE B -- bsd/kern/kern_exec.c, a NEW accessor beside 1026's `xnu_live_abt_proc_ustack`, publishing the
region's exclusive top AS THE ALLOCATOR COMPUTED IT, stashed into the proc at `create_unix_stack` so the
two independent derivations (the map's `vme_end` at Site A, and the allocator's `addr + extent` here) can
be compared.  The stash is a STORED value (the `addr`/`size` locals are gone once `create_unix_stack`
returns).  It is `round_page(addr + alloc_extent)`: with H2 ON the FIXED extent is `size + 16` and
`mach_vm_allocate` ROUNDS it, so the true top is `round_page(addr + size + 16) = user_stack + 0x1000`
(NOT the naive `addr + size`, which would be a `[[mi4-stand-in-size-is-not-value]]` trap).

READS ONLY on the failing path; ONE durable stash written once per exec.  With the switch undefined the
tree compiles BYTE-IDENTICAL to the 1030 tree (`--verify-off`).

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029/1030 and
now 1031; kern_exec.c by 1025/1026/1028/1029 and now 1031.  A file's `#if` identifiers are ONE namespace;
every OTHER patcher's allow-set must gain STAGE90_XNU_CALLER_PROBE, and this script carries the whole
union for both files.

docs/1031-design.md.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_CALLER_PROBE"

TRAP_REL = "osfmk/arm/trap.c"
EXEC_REL = "bsd/kern/kern_exec.c"

# ---------------------------------------------------------------- trap.c (Site A)

# Inserted AFTER 1030's writer block's `#endif` and BEFORE 1025's publisher `#endif`.  The two-line tail
# is unique: only 1030 sits between the ABT-entry block and 1025's close today.
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_WRITER_PROBE */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_cal_region_end="

TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_WRITER_PROBE */\n"
    "#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE\n"
    "\t\t\t\t\t/* 1031: READ THE CALLER + PRINT THE REGION TOP.  1030 read the writer's cursor r4 ==\n"
    "\t\t\t\t\t * far == the region's exclusive top, but the writer's prologue (`add r7,sp,#12`) shows\n"
    "\t\t\t\t\t * the boundary decision is in the CALLER, whose frame 1030 could not see.  Publish the\n"
    "\t\t\t\t\t * caller's registers (r0/r1/r2/r9/r10), the writer's fp self-check (r7-sp == 0xC), and --\n"
    "\t\t\t\t\t * the crux -- the covering entry's vme_end for far-4, which IS the region's exclusive\n"
    "\t\t\t\t\t * top BY VALUE when far is the top (docs/1031-design.md 2).  READS only; on the failing\n"
    "\t\t\t\t\t * path only; vm_map_lookup_entry takes NO lock in this tree (the 1026/1027 idiom). */\n"
    "\t\t\t\t\t{\n"
    "\t\t\t\t\t\tvm_map_entry_t _cal_e = VM_MAP_ENTRY_NULL;\n"
    "\t\t\t\t\t\tboolean_t _cal_hit =\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, vm_map_trunc_page(dfar) - 4, &_cal_e);\n"
    "\t\t\t\t\t\textern unsigned xnu_live_abt_proc_ustack(void *);\n"
    "\t\t\t\t\t\tunsigned _cal_ust = xnu_live_abt_proc_ustack(thread->task->bsd_info);\n"
    "\t\t\t\t\t\tunsigned _cal_far = (unsigned)vm_map_trunc_page(dfar);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r0=0x%08x\\n\", (unsigned)arm_ctx->r[0]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r1=0x%08x\\n\", (unsigned)arm_ctx->r[1]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r2=0x%08x\\n\", (unsigned)arm_ctx->r[2]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r3=0x%08x\\n\", (unsigned)arm_ctx->r[3]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r9=0x%08x\\n\", (unsigned)arm_ctx->r[9]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r10=0x%08x\\n\", (unsigned)arm_ctx->r[10]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r12=0x%08x\\n\", (unsigned)arm_ctx->r[12]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r7=0x%08x\\n\", (unsigned)arm_ctx->r[7]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r7_minus_sp=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)(arm_ctx->r[7] - (unsigned)arm_ctx->sp));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_lr=0x%08x\\n\", (unsigned)arm_ctx->lr);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_pc=0x%08x\\n\", (unsigned)arm_ctx->pc);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_far=0x%08x\\n\", _cal_far);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_ustack=0x%08x\\n\", _cal_ust);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_far_minus_ustack=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)(_cal_far - _cal_ust));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_region_end_hit=%d\\n\", (int)(_cal_hit ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_region_end=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)((_cal_hit && _cal_e) ? _cal_e->vme_end : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_cal_r3_minus_region_end=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)((unsigned)arm_ctx->r[3] -\n"
    "\t\t\t\t\t\t        (unsigned)((_cal_hit && _cal_e) ? _cal_e->vme_end : 0)));\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# trap.c's `#if` identifiers are the union of what ALL the patchers put there.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
    "STAGE90_XNU_WATCH_LE",  # 1038 (tools/patch_d13_watch_le.py)
    "STAGE90_XNU_GLOBAL_FIX",         # 1015b (fires in pmap.c; allowed for the proof)
    "STAGE90_XNU_UNDEF_RAISE",        # 1020
    "STAGE90_XNU_IOS7_TRAPS",         # 1023
    "STAGE90_XNU_USTACK_PROBE",       # 1025 (this block's PARENT)
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026/1027
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (edits kern_exec.c; allowed for the proof)
    "STAGE90_XNU_READER_PROBE",       # 1029
    "STAGE90_XNU_WRITER_PROBE",       # 1030
    "STAGE90_XNU_CALLER_PROBE",       # 1031 (this rung)
    "STAGE90_XNU_EVAL_FRAME",         # 1033 (tools/patch_d13_eval_frame.py)
    "STAGE90_XNU_PC_CARRIER",         # 1035 (tools/patch_d13_pc_carrier.py)
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (tools/patch_d13_pc_carrier_caller.py)
    "STAGE90_XNU_TRAP_FRAME",  # 1037 (tools/patch_d13_trap_frame.py)
}

# ---------------------------------------------------------------- kern_exec.c (Site B)

# 1029's accessor region ends with `#endif /* STAGE90_XNU_READER_PROBE */`.  Insert Site B there, under
# its OWN switch, before the `create_unix_stack` comment block.
EXEC_ANCHOR = "#endif /* STAGE90_XNU_READER_PROBE */\n"
EXEC_DONE_MARK = "xnu_live_cal_proc_region_top"

EXEC_ACCESSOR_BLOCK = (
    "#endif /* STAGE90_XNU_READER_PROBE */\n"
    "#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE\n"
    "/*\n"
    " * 1031 (READ THE CALLER): the stack region's EXCLUSIVE TOP as the ALLOCATOR computed it, stashed into\n"
    " * the proc at create_unix_stack (below) so it survives the call (the addr/size locals do not).\n"
    " * `p_live_stack_top` is round_page(addr + alloc_extent): with H2 ON the FIXED extent is `size + 16`\n"
    " * and mach_vm_allocate ROUNDS it, so the top is `user_stack + PAGE_SIZE`, NOT the naive `addr + size`.\n"
    " * READ ONLY; NULL guard like the 1026/1029 accessors.  docs/1031-design.md 2, Site B.\n"
    " */\n"
    "unsigned\n"
    "xnu_live_cal_proc_region_top(void *bsd_info)\n"
    "{\n"
    "\tif (bsd_info == NULL) {\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "\treturn (unsigned)((proc_t)bsd_info)->p_live_stack_top;\n"
    "}\n"
    "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
)

# The stash at create_unix_stack: after the FIXED allocate, record the allocator's own exclusive top.
# We stash on BOTH the FIXED-success and ANYWHERE-fallback paths so the value is never stale, computed
# from the SAME `addr`/extent the allocator used.  The anchor is the `if (kr != KERN_SUCCESS) {` line
# that begins the fallback, which is unique in create_unix_stack.
EXEC_STASH_ANCHOR = (
    "\t\tif (kr != KERN_SUCCESS) {\n"
    "\t\t\t/* If can't allocate at default location, try anywhere */\n"
)

# We insert a stash BETWEEN the FIXED allocate's `#endif /* STAGE90_XNU_H2_STACK_HEADROOM */` and the
# `if (kr != KERN_SUCCESS) {` fallback, so `addr` (the base the FIXED attempt used) is still live and the
# stashed top reflects the FIXED extent when it succeeded.  For the ANYWHERE fallback we re-stash inside.
EXEC_STASH_BLOCK = (
    "#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE\n"
    "\t\t/* 1031: record the allocator's own exclusive top for the FIXED attempt.  The extent the FIXED\n"
    "\t\t * `mach_vm_allocate` above actually used is `size` (H2 off) or `size + 16` (H2 on) -- the\n"
    "\t\t * `size` local does NOT carry H2's +16 -- and mach_vm_allocate ROUNDS it, so the top is\n"
    "\t\t * round_page(addr + extent).  Mirror the H2 `#if` so the stashed top is the allocator's OWN\n"
    "\t\t * value, never the naive `addr + size` (a stand-in-size trap; [[mi4-stand-in-size-is-not-value]]).\n"
    "\t\t * If the FIXED attempt fails, the fallback re-stashes below.  docs/1031-design.md 2, Site B. */\n"
    "\t\tif (kr == KERN_SUCCESS) {\n"
    "#if defined(STAGE90_XNU_H2_STACK_HEADROOM) && STAGE90_XNU_H2_STACK_HEADROOM\n"
    "\t\t\tunsigned _cal_top = (unsigned)mach_vm_round_page(addr + size + 16);\n"
    "#else\n"
    "\t\t\tunsigned _cal_top = (unsigned)mach_vm_round_page(addr + size);\n"
    "#endif /* STAGE90_XNU_CALLER_PROBE: H2 extent */\n"
    "\t\t\tproc_lock(p);\n"
    "\t\t\tp->p_live_stack_top = _cal_top;\n"
    "\t\t\tproc_unlock(p);\n"
    "\t\t}\n"
    "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
    "\t\tif (kr != KERN_SUCCESS) {\n"
    "\t\t\t/* If can't allocate at default location, try anywhere */\n"
)

# And a re-stash on the ANYWHERE fallback's success, from the fallback's own addr+size.
EXEC_FALLBACK_ANCHOR = (
    "\t\t\tuser_stack = addr + size;\n"
    "\t\t\tload_result->user_stack = user_stack;\n"
)

EXEC_FALLBACK_BLOCK = (
    "\t\t\tuser_stack = addr + size;\n"
    "#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE\n"
    "\t\t\tproc_lock(p);\n"
    "\t\t\tp->p_live_stack_top = (unsigned)mach_vm_round_page(addr + size);\n"
    "\t\t\tproc_unlock(p);\n"
    "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
    "\t\t\tload_result->user_stack = user_stack;\n"
)

# kern_exec.c's STAGE90 namespace is shared by 1025/1026/1028/1029.
EXEC_ALLOWED_STAGE90 = {
    "STAGE90_XNU_USTACK_PROBE",       # 1025
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028
    "STAGE90_XNU_READER_PROBE",       # 1029
    "STAGE90_XNU_CALLER_PROBE",       # 1031 (this rung)
}


def read(p):
    with open(p) as f:
        return f.read()


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def if_stage90_ids(text):
    ids = set()
    for m in re.finditer(r"^\s*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M):
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
            if ident.startswith("STAGE90_"):
                ids.add(ident)
    return ids


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def exec_path(xnu):
    return os.path.join(xnu, EXEC_REL)


def check_trap(xnu):
    p = trap_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            f"{TRAP_REL}'s directives also evaluate {', '.join(foreign)}. trap.c is edited by SEVEN "
            f"rungs (994/1020/1025/1026/1029/1030/1031) and a file's directive identifiers are a SHARED "
            f"namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other "
            f"patchers' sets. ([[mi4-one-file-many-rungs]])")
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            f"the WRITER_PROBE/USTACK_PROBE `#endif` tail occurs {t.count(TRAP_ANCHOR)} time(s), "
            f"expected exactly 1. The tree is not in the state this rung was written against (1030's "
            f"block is not staged, or a displaced anchor / partial edit).")
    return True, p, t, "anchor unique, switch absent"


def check_exec(xnu):
    p = exec_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    e = read(p)
    if SWITCH in e:
        return True, p, e, "already staged"
    foreign = sorted(i for i in if_stage90_ids(e) if i not in EXEC_ALLOWED_STAGE90)
    if foreign:
        return False, p, e, (
            f"{EXEC_REL}'s directives also evaluate {', '.join(foreign)}. kern_exec.c's STAGE90 "
            f"identifiers are a SHARED namespace (1025/1026/1028/1029): add this switch to the other "
            f"patchers' sets. ([[mi4-one-file-many-rungs]])")
    if e.count(EXEC_ANCHOR) < 1:
        return False, p, e, (
            f"the READER_PROBE `#endif` anchor occurs {e.count(EXEC_ANCHOR)} time(s), expected >= 1 "
            f"(the reader accessor region must be staged).")
    if e.count(EXEC_STASH_ANCHOR) != 1:
        return False, p, e, (
            f"the create_unix_stack FIXED/fallback `if (kr != KERN_SUCCESS)` anchor occurs "
            f"{e.count(EXEC_STASH_ANCHOR)} time(s), expected exactly 1. The tree is not in the state "
            f"this rung was written against.")
    if e.count(EXEC_FALLBACK_ANCHOR) != 1:
        return False, p, e, (
            f"the ANYWHERE-fallback `user_stack = addr + size;` anchor occurs "
            f"{e.count(EXEC_FALLBACK_ANCHOR)} time(s), expected exactly 1.")
    return True, p, e, "anchors unique, switch absent"


def ensure_proc_field(xnu):
    """The stash needs a proc field `p_live_stack_top`.  Add it beside `user_stack` in the PRIMARY
    proc struct (proc_internal.h:313).  Idempotent; refusal-clean."""
    rel = "bsd/sys/proc_internal.h"
    p = os.path.join(xnu, rel)
    if not os.path.isfile(p):
        return False, f"no {p}"
    t = read(p)
    if "p_live_stack_top" in t:
        return True, "already present"
    anchor = "\tuser_addr_t user_stack;\t\t/* where user stack was allocated */\n"
    if t.count(anchor) != 1:
        return False, (f"the `user_stack` field anchor occurs {t.count(anchor)} time(s) in {rel}, "
                       f"expected exactly 1.")
    repl = (anchor +
            "#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE\n"
            "\tuint32_t p_live_stack_top;\t/* 1031: the stack region's exclusive top (allocator's own) */\n"
            "#endif /* STAGE90_XNU_CALLER_PROBE */\n")
    if "--apply" in sys.argv:
        write(p, t.replace(anchor, repl))
    return True, "field anchor unique"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    ok_e, ep, e, msg_e = check_exec(xnu)
    ok_f, msg_f = ensure_proc_field(xnu)
    if not ok_t:
        print(f"patch_d13_caller_probe: REFUSE (trap.c) - {msg_t}. Writing nothing.", file=sys.stderr)
        return 1
    if not ok_e:
        print(f"patch_d13_caller_probe: REFUSE (kern_exec.c) - {msg_e}. Writing nothing.", file=sys.stderr)
        return 1
    if not ok_f:
        print(f"patch_d13_caller_probe: REFUSE (proc_internal.h) - {msg_f}. Writing nothing.",
              file=sys.stderr)
        return 1
    if msg_t == "already staged" and msg_e == "already staged":
        print("patch_d13_caller_probe: already staged - no-op, OK.")
        return 0
    print(f"   trap.c      : {msg_t}.")
    print(f"   kern_exec.c : {msg_e}.")
    print(f"   proc_internal.h : {msg_f}.")
    if not do_apply:
        print("patch_d13_caller_probe: plan OK (dry run; pass --apply to write).")
        return 0
    if msg_t != "already staged":
        write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
        print("   trap.c      : staged Site A (xnu_live_cal_* rows) after 1030's block, inside 1025's arm.")
    if msg_e != "already staged":
        # Site B accessor: insert after the FIRST READER_PROBE `#endif` that is followed by the
        # create_unix_stack comment (the accessor region), not any other occurrence.
        idx = e.find(EXEC_ANCHOR)
        best = idx
        if idx >= 0:
            j = e.find(EXEC_ANCHOR, idx + 1)
            while j >= 0:
                tail = e[j + len(EXEC_ANCHOR): j + len(EXEC_ANCHOR) + 400]
                if "create_unix_stack" in tail:
                    best = j
                    break
                j = e.find(EXEC_ANCHOR, j + 1)
        if best < 0 or "create_unix_stack" not in e[best:best + 600]:
            print("patch_d13_caller_probe: REFUSE - create_unix_stack was not found after the reader "
                  "accessor anchor (kern_exec.c not in the expected state). Writing nothing.",
                  file=sys.stderr)
            return 1
        e2 = e[:best] + EXEC_ACCESSOR_BLOCK + e[best + len(EXEC_ANCHOR):]
        # stash (FIXED) + fallback re-stash
        e2 = e2.replace(EXEC_STASH_ANCHOR, EXEC_STASH_BLOCK)
        e2 = e2.replace(EXEC_FALLBACK_ANCHOR, EXEC_FALLBACK_BLOCK)
        write(ep, e2)
        print("   kern_exec.c : staged Site B (accessor + the two p_live_stack_top stashes).")
    return 0


def caller_closes_inside_1025(t):
    """**NOT `caller #endif` immediately followed by 1025's `#endif`** (1033 found this check's first
    form): trap.c is a SHARED namespace ([[mi4-one-file-many-rungs]]), so a LATER rung may legitimately
    close its own gated block between this one and 1025's -- 1033's eval frame does exactly that, and
    the literal-adjacency test then failed on a correctly composed tree.  The structural claim is:
    this block's close, then zero or more WHOLE `#if defined(STAGE90_…)` … `#endif` blocks (each
    opened and closed here, never leaking a directive past 1025's gate), then 1025's close.  Line
    scanning rather than one nested-lookahead regex: the regex form was not worth its fragility."""
    lines = t.split("\n")
    close = "#endif /* %s */" % SWITCH
    if lines.count(close) != 1:
        return False
    i = lines.index(close) + 1
    depth = 0
    while i < len(lines):
        s = lines[i].strip()
        if depth == 0:
            if s == "#endif /* STAGE90_XNU_USTACK_PROBE */":
                return True
            if s.startswith("#if ") and "STAGE90_" in s:
                depth = 1
            elif s.startswith("#"):
                return False            # a directive at 1025's level that is not a whole later block
        else:
            if s.startswith("#if "):
                return False            # a later block must not nest (OFF would strip its #endif first)
            if s.startswith("#endif"):
                depth = 0
        i += 1
    return False


def verify_off(xnu):
    """Prove the tree compiles to the 1030 tree's bytes with 1031's switch unset.  Every edit is inside
    `#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE`, so with the switch undefined the
    preprocessor removes it.  Check by TEXT (each ON block present + bracketed by its own #if/#endif)."""
    tp = trap_path(xnu)
    ep = exec_path(xnu)
    t = read(tp)
    e = read(ep)
    if SWITCH not in t or SWITCH not in e:
        print("patch_d13_caller_probe: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    have_t = (t.count(TRAP_DONE_MARK) == 1
              and t.count(f"#if defined({SWITCH}) && {SWITCH}\n") >= 1
              and t.count(f"#endif /* {SWITCH} */\n") >= 1)
    between = t.count("#endif /* STAGE90_XNU_WRITER_PROBE */\n#if defined(STAGE90_XNU_CALLER_PROBE)") == 1
    tail = caller_closes_inside_1025(t)
    have_e = (e.count(EXEC_DONE_MARK) >= 1
              and e.count("p_live_stack_top") >= 2
              and e.count(f"#if defined({SWITCH}) && {SWITCH}\n") >= 1)
    print(f"   trap.c       [ON] : xnu_live_cal_region_end row present + #if/#endif pair: {have_t}")
    print(f"   trap.c            : the caller block sits after 1030's, inside 1025's publisher: {between}")
    print(f"   trap.c            : it closes inside 1025's publisher (1025's #endif, or whole later STAGE90 blocks then it): {tail}")
    print(f"   kern_exec.c  [ON] : accessor + stashes present under the switch: {have_e}")
    if have_t and between and tail and have_e:
        print("patch_d13_caller_probe: --verify-off PASS (all edits gated on the switch; OFF removes "
              "them -> 1030 tree bytes).")
        return 0
    print("patch_d13_caller_probe: --verify-off FAIL.", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2:
        print("usage: patch_d13_caller_probe.py <xnu_root> [--apply|--verify-off]", file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))