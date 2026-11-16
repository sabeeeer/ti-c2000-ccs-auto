# Repository instructions

## Scope and source

- The source of truth is `%USERPROFILE%\.codebuddy\skills\ti-c2000-ccs-auto`. Edit it, not the installed Codex copy. After changes, run `tools/sync_platform_copies.ps1 -DryRun`, review `PRUNE`, then synchronize.
- This repository is a skill, not a CCS project. Offline review must not contact a target. For a real project, read its `AGENTS.md`, then run the installed `scripts/check_project_entry.ps1 -ProjectPath <project>` and proceed only on exit 0 plus `RESULT: OK`.
- Keep every PowerShell script at `#requires -Version 7.0`. Never report success without `RESULT: OK` and exit 0. Each operational entry must print `SKILL   : ti-c2000-ccs-auto@<version>`.

## Architecture

- Keep `SKILL.md` a short router: two RUN modes (SingleStep default, Iterate only by explicit request), two READ modes (ReadOnly default, LoadRead only with explicit approval), and three shared primary classes: (1) device/CCS/probe/peripheral/linker, (2) TI libraries/algorithms, (3) debugging experience. Error is a separate offline lookup mode, not another target mode.
- Except for class 1 device/probe adapters, generic reading, validation, timing, session and error logic must not assume a chip, boot mode, PC value, fixed address, host installation or emulator model. The generic RAM gate uses the pinned `.map`, RAM updater and advancing `gRamProofTick`; never fall back to PC or a fixed Flash base. Read `references/ram-proof-firmware.md` before integrating firmware.
- Preserve DSP28335 and F28379D references, all TI library entries including DCL/DMC and SolarLib v1.2, and the accumulated debug cases. New device or peripheral setup goes to class 1; new library to class 2; new measured failures from any chip/module go to class 3 and the catalog.
- Project AI entry documents (`AGENTS.md`, `CODEBUDDY.md`, `CLAUDE.md`) must be identical, point to this skill, and exist before code work. `tools/init_project_entry.ps1` creates them without overwriting existing different instructions. Never copy skill scripts into a CCS project.

## Hardware and data rules

- No download without the user's explicit yes and `-ConfirmLoad`; Iterate also requires the user's request for repeated loads and `-UserApproved`. Build-only is hardware-free. ReadOnly never builds, loads, reconnects, resets or halts. `-NoProbeCheck`, `-AllowUnverified` and `-NoHeartbeat` cannot bypass a trusted ReadOnly proof.
- LoadRead uses the retained service to load once, then the same ReadOnly gate; leave the session running after reading. Stop is a disruptive operation that may make a probe disappear temporarily. Verify it completed and the probe is usable before a new load. Do not hide a forced kill or failed disconnect behind `RESULT: OK`.
- Read preflight must tell the user probe and target connection, live session, exact `.out` SHA256 and source freshness, RAM/Flash evidence, firmware identity and its limitations, application heartbeat, and successful download count. Do not mistake `connect()` returning normally, a live PID, symbol lookup, `runAsynch()` or `isHalted()==false` for proof of a running application.
- Read postflight must validate identity, heartbeat, sample completeness, finite values and requested ranges. Frozen arrays additionally need a completed flag and unchanged sequence across transfer. A failed proof must clear stale success artifacts and refuse the data. DMA board tests remain deferred until firmware initialization and ping-pong freezing are ready.
- Keep at least 5000 ms between `loadProgram` attempts and 400 ms between repeated read requests; settle and verify probe readiness before reconnecting. These minima live in `references/firmware-contract.json`. When changing a symbol or limit, edit that file first, run `tools/audit_fw_contract.ps1`, fix every reported script and rerun it.
- Preserve reset failure → valid-link halt fallback → load. A refused reset alone is not a fatal `-1138`; only actual `-1138` evidence should use that diagnosis. Verify `target.isConnected(true)` after connecting. A stale selected `.out` must be rejected before any download.
- On failure, use `scripts/ti_c2000_error.ps1` and `references/error-index.json` first, then add evidence-grounded new cases to class 3. Do not retry blindly.

## Verification

- Run offline parser, contract, JS identifier, dead-parameter and meaningful tests after edits. `tests/test_e2e_readonly.ps1` contacts a board and must not run during offline review. If setup logic changes, run `tests/test_setup_failure.ps1`.
- Keep historical field observations and the general workflow rule distinct. Label offline checks, source inference and on-board measurements separately. Do not claim that all C2000 targets reset on DSS disconnect.
