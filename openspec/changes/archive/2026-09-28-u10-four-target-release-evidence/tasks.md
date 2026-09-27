## 1. Full CI target execution

- [x] 1.1 Fix the child-runner closure and add a regression test that executes a real target-check script through the Full lane.

## 2. Artifact evidence

- [x] 2.1 Implement bounded PE and ELF target/ABI/runtime-dependency checks with wrong-target fault cases.
- [x] 2.2 Implement firmware ELF, vector-table, capacity, and Intel HEX checks with malformed-image fault cases.
- [x] 2.3 Gate staged and actual-installed release smoke on those checks and add them to the verification report.

## 3. Verify and finalize

- [x] 3.1 Run default and Full CI plus installed-EXE validation; sync specs, archive, and commit only this change.
