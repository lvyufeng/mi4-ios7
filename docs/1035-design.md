1035 — THE pc-CARRIER RUNG: read the DEVICE's bytes at the faulting pc (instrument only)
2026-10-19. Plan: records/1035-carrier-by-pc-read.txt. Forensics behind it: records/1034-design-errata.txt.
Switch: STAGE90_XNU_PC_CARRIER=1 (POOL-only). Patcher: tools/patch_d13_pc_carrier.py. Build: scripts/build_1035.sh.

0. CELL
   launchctl[2] data-aborts (dfsr 7, far 0x10) at pc 0x3819d474. 1033 published the raw frame; 1034's
   forensics found the two candidate file locations disagree (the walk at pc-0x577000, a table at pc
   itself) and every register in the frame fits the walk. The device's own bytes at pc decide it; this
   rung reads them from the task map, four faults, pid 2 only, and prints the XOR against the host's
   word for each candidate.  Zero XOR = the whole reading.  Unreadable page prints  _ok=0 (a row that
   cannot say its conjunct is not a reading — the 1026 lesson).
1. CELLS: P1 xor_walk==0 (walk; fix = count class) · P2 xor_table==0 (pc is data) · P3 neither (a
   different cache was served) · P4 near2_ok==0 (pc page not in the task map).
2. COST: 6 guarded copyins, 4 times, failing path only. No fix, no cache bytes, no count change.
3. RISK: the host words are baked at build; build_1035.sh's step greps trap.o for `xnu_live_pcc_pc=`.
