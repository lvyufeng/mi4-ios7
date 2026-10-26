#!/usr/bin/env python3
"""1041 -- publish the vm_map entry that HOLDS the faulting pc, so an address can be resolved.

WHY.  `launchd[1]` faults at `pc = 0x000b30a4`. That value is real (the dump is `%08x`, no truncation)
but it is outside launchd's own `__TEXT` (0x1000..0x21000), so a slide was applied - and the capture
does not say which. Every slide in `[0x920a4, 0xb121d]` puts the pc inside `__TEXT`, sixteen
page-aligned values fit, and all of them disassemble without an undefined instruction. Picking one
would be inventing evidence.

The vm_map entry that contains the pc IS the image's text segment on armv7. Printing its start and end
turns the ambiguity into arithmetic: `pc - lo` is the offset, and `lo` is the base.

WHERE.  Inside the register dump that already prints `dyld_all_image_info_addr`
(`dyld_all_image_info_size);` at ~line 836), which runs on the same path. Read-only: one
`vm_map_lookup_entry` and five printfs, no state touched.

    tools/add_1041_image_base.py <trap.c>     # idempotent; refuses if the anchor is missing
"""
import sys

MARKER = "xnu_live_img_pc_lo="
ANCHOR = "all_image_info_size);"

BLOCK = '''
                    /* 1041: WHICH IMAGE.  A pc alone cannot be resolved: launchd faults at
                     * 0x000b30a4 and every slide in [0x920a4, 0xb121d] puts it inside `__TEXT`, so
                     * without the image base the address is ambiguous. The vm_map entry that HOLDS
                     * the pc is that base. READ ONLY. */
                    {
                        vm_map_entry_t _ib_e = VM_MAP_ENTRY_NULL;
                        vm_map_t _ib_m = get_task_map(thread->task);
                        boolean_t _ib_hit = (_ib_m != VM_MAP_NULL) ?
                            vm_map_lookup_entry(_ib_m, (vm_offset_t)vm_map_trunc_page(arm_ctx->pc),
                                                &_ib_e) : FALSE;
                        printf("xnu_live_img_pc_map=0x%08x\\n", (unsigned)(uintptr_t)_ib_m);
                        printf("xnu_live_img_pc_hit=%d\\n", (int)(_ib_hit ? 1 : 0));
                        printf("xnu_live_img_pc_lo=0x%08x\\n",
                               (unsigned)((_ib_hit && _ib_e) ? (uintptr_t)_ib_e->vme_start : 0U));
                        printf("xnu_live_img_pc_hi=0x%08x\\n",
                               (unsigned)((_ib_hit && _ib_e) ? (uintptr_t)_ib_e->vme_end : 0U));
                        printf("xnu_live_img_pc_off=0x%08x\\n",
                               (unsigned)((_ib_hit && _ib_e)
                                   ? (arm_ctx->pc - (uintptr_t)_ib_e->vme_start) : 0U));
                    }'''


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    text = open(path).read()
    if MARKER in text:
        print("already present: %s" % MARKER)
        return 0
    lines = text.split("\n")
    k = next((i for i, l in enumerate(lines)
              if ANCHOR in l and "printf" not in l), None)
    if k is None:
        print("REFUSING: no `%s` row - this is not the trap.c this script was written for" % ANCHOR)
        return 1
    lines[k + 1:k + 1] = BLOCK.split("\n")
    open(path, "w").write("\n".join(lines))
    print("1041: image-base probe inserted after line %d" % (k + 1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
