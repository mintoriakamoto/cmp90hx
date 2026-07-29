# Gen2 compatibility review

Reviewed upstream source: `amoghmunikote/cmpunlocker`, branch `Gen2`, commit
`746d9f78643399cc1aff2475977e674057390658`.

The Gen2-only delta after the common ancestor with `clanker/driver-port` is a
PCIe Gen2 enable/retrain implementation for the CMP 170HX (GA100).  It adds
GA100 register writes, a `RmForceEnableGen2` driver option, and a BAR0
retraining service.  It must not be copied to the CMP90HX 220d/1555 driver
port: this project supports only 580.159.03 and only compute-selector writes.

Applicable reliability lesson adopted by this project: do not probe the
temporary candidate with `nvidia-smi`. The service first preflights the stock
driver, opens only the target candidate node, then performs two PCIe `bus`
resets across the exact CMP90HX group before restoring the vendor runtime
driver. No FLR, BAR0 user-space write, or GA100 Gen2 path is used.
