# Horizon / task length — measurement plan

**Now:** the task-length axis is named in the coding report (`Task#horizon`, default `:short`);
`horizon.covered` / `horizon.gaps` state that only `short` is exercised and `medium`/`long` are
unmeasured. So today the axis has one bucket and the gap is explicit.

**Unknown:** competence over longer horizons — durability and correctness as tasks grow from
minutes to hours (METR's lesson). Nothing measures it.

**Measure (real model):**
1. Author `:medium` tasks (multi-step, tens of minutes) and run them with a real model; report the
   solve-rate per horizon class, never blended.
2. The genuine long end is the **8-hour physical fault soak (P8)** — a `:long` task by nature —
   which needs the physical rig (see [12b](12-physical.md)). It is the honest home for the
   long-horizon durability claim.
3. Report each horizon bucket separately with its interval; a blended cross-horizon rate is a
   mixing artifact.

**Prereqs:** medium-horizon task authoring (offline) + real provider; long-horizon needs hardware
(P8).

**Done:** a real solve-rate per horizon bucket with intervals, `medium` no longer a gap; `long`
either measured via the soak or recorded as hardware-pending.
