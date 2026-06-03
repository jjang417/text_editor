# TB600 → TCX10 → devproc-GPU: Architecture Design

Status: design baseline.

## 1. Context

TB500 already exposes the GPU at BDF `0001:01:00.0`, behind a PCI
bridge at `0001:00:00.0`. The bridge function is currently modelled
**inside SCSIM itself** (an integrated bridge in the PCIe RC/hub
model), with commlib_adapter providing a single endpoint bound to the
GPU's BDF. The PCIe RC routes by BDF upstream of the adapter, so what
arrives at devproc-GPU is cfg-offset-only — the convention confirmed
by the TB500 `gpu_chiplet.cpp` trace (vendor id read shows up as
`read at 0x0`, not `0x10000`).

```
   TB500 SCSIM  ───── commlib (adapter bound to GPU's BDF) ─────►  devproc-GPU
   (PCIe RC + integrated bridge does BDF routing internally)
```

TB600 keeps the **same wire protocol** on the north side but moves the
bridge function out of SCSIM and into a separate commlib process —
DevProc (`mellanox/dgx/devproc/`), repurposed as TCX10. ConnectX-10
becomes a real Type-1 PCI-PCI bridge living in DevProc; SCSIM's PCIe
model now routes downstream TLPs to DevProc via a south server, and
DevProc forwards them onward to devproc-GPU via the same north adapter
TB500 used.

```
   TB600 SCSIM ─── commlib ─── TCX10 (Type-1)  ─── commlib ─── devproc-GPU
                  (south)      (bridge in       (north via
                                DevProc)         libcommlib_adapter.so)
```

What's identical between TB500 and TB600:

  * GPU's BDF: `0001:01:00.0`
  * Bridge BDF: `0001:00:00.0`
  * Wire format from bridge → GPU adapter: cfg-offset-only, BDF stripped
  * devproc-GPU is unchanged

What changes:

  * The bridge model moves from inside SCSIM to DevProc.
  * SCSIM's PCIe RC sends two streams south now (one to DevProc for
    the bridge + downstream, one to whatever owns CX10's own NIC
    state), instead of routing internally.
  * The new `/root/commlib_adapter/` client library is what DevProc
    uses on the north side to reach devproc-GPU.

In practice the TB500 `gpu_chiplet.cpp` log is the ground-truth
reference for what devproc-GPU should see in TB600: identical
sequence of cfg accesses, identical address values.

## 2. What TB600 sees in `lspci`

```
0001:00:00.0 PCI bridge: Mellanox Technologies MT2910 PCIe Bridge
                  [primary=0, secondary=1, subordinate=1]
0001:01:00.0 3D controller: NVIDIA Corporation Device <id>
                  [behind 00:00.0]
```

CX10's HEADER_TYPE is `0x01`, BIOS allocates a secondary bus during
enumeration, and the GPU's vendor/device id come straight from
devproc-GPU's config-space shadow (forwarded transparently by TCX10).

## 2a. Target GPU BAR layout (reference)

The GPU functional model in `/root/devproc_gpu/devproc/` simulates a
GR152-class NVIDIA device (`vendor=0x10de`, `device=0x353f`). What it
advertises to TB600 via the cfg tunnel:

### PF (physical function) BARs

| BAR | Base address    | Size  | Type                       | Notes                                 |
|-----|-----------------|-------|----------------------------|---------------------------------------|
| 0   | `0x800100000000` | 256 MB | 64-bit, **prefetchable**  | Driver registers + MSI-X table/PBA    |
| 2   | `0x800110000000` | 256 MB | 64-bit, **prefetchable**  | Resizable BAR (up to 256 PB supported) |
| 4   | `0x800510000000` |  32 MB | 64-bit, **prefetchable**  |                                       |
| ROM | `0x800040000000` |   2 KB | Expansion ROM              |                                       |

All three BARs are **64-bit prefetchable**; zero non-prefetchable BARs.
The base addresses sit at `0x80_xxxx_xxxx_xxxx` — well above the 4 GB
mark — so the bridge **must** support 64-bit prefetchable windows
(`pref_*_upper32`) for any TLP to be routable.

### Other PCI capabilities surfaced

| Cap         | Offset | Notes                                                     |
|-------------|--------|-----------------------------------------------------------|
| Express     | `0x40` | Endpoint, v2, FLIT mode supported                         |
| MSI-X       | `0x7c` | 12 vectors, table @ BAR0+`0xb90000`, PBA @ BAR0+`0xba0000` |
| Power Mgmt  | `0x88` |                                                           |
| Vendor      | `0x90` | NVIDIA-specific                                           |
| Vendor      | `0xa4` | NVIDIA-specific                                           |
| AER         | `0x148` | Advanced Error Reporting                                 |
| LTR         | `0x190` | Latency Tolerance Reporting                              |
| Resizable BAR | `0x198` | BAR2 supports up to 256 PB                             |
| ARI         | `0x2f8` |                                                          |
| SR-IOV      | `0x300` | 63 VFs supported (PF + 63 VFs)                           |
| PASID       | `0x3b0` | Max width 14 bits                                        |
| ATS         | `0x3a8` |                                                          |

### SR-IOV BARs (per-VF, when SR-IOV enabled)

| BAR | Base address    | Type                       |
|-----|-----------------|----------------------------|
| 0   | `0x800590000000` | 64-bit, **prefetchable**  |
| 2   | `0x800120000000` | 64-bit, **prefetchable**  |
| 4   | `0x800512000000` | 64-bit, **prefetchable**  |

VF count default 0; SR-IOV is not enabled in current TB600 launches,
so VF BARs don't matter for the MVP. If enabled later, the bridge
window must grow to also cover the VF BARs' address range.

### Implication for the bridge window

To cover all three PF BARs the bridge memory window has to span at
least `0x800100000000..0x80051FFFFFFF` — about 5 GB. The bridge
forwards everything in that range to devproc-GPU; the gaps between
BARs (`0x800120000000..0x80050FFFFFFF`, etc.) get forwarded too but
devproc-GPU decodes only matching BAR addresses and ignores the rest.
That's how real PCI-PCI bridges behave.

If SR-IOV is enabled later, the window has to grow to also cover
`0x800590000000..0x800592FBFFFF` for the VF aperture.

### Interrupt mode

The GPU advertises MSI-X with 12 vectors, but `EnableMSI=0` in the
current SCSIM launch keeps the driver in INTx-style mode (lspci shows
`MSI-X: Enable-`). This matches commlib_adapter's INTx-style
per-instance coalescing (the IRQ design in §5e). If a future launch
flips MSI-X on, we'd need vector-aware IRQ forwarding through the
adapter; out of scope for the MVP.

## 3. Architecture

### 3a. System topology — three processes, two commlib hops

```
 ┌────────────────────────────────────────────────────────────────────────────────┐
 │                      Process A: TB600 SCSIM (SystemC sim)                      │
 │                                                                                │
 │   ┌────────────────────────────────────────────────────────────────────┐       │
 │   │  Linux guest VM:  CPU + RM driver + userspace                      │       │
 │   │                                                                    │       │
 │   │     lspci sees:                                                    │       │
 │   │       0001:00:00.0 PCI bridge  (Mellanox CX10 PCIe Bridge)         │       │
 │   │       0001:01:00.0 3D controller (NVIDIA, behind 00:00.0)          │       │
 │   └─────────────────────────┬──────────────────────────────────────────┘       │
 │                             │  PCIe TLPs (config / MMIO / DMA / IRQ)           │
 │                             ▼                                                  │
 │   ┌─────────────────────────────────────────────────────────────────────┐      │
 │   │  SCSIM PCIe RC -> Hub -> EP slot -> south commlib client            │      │
 │   │     payload offset encodes BDF + cfg offset per pcie.h MASK_PCI_*:  │      │
 │   │       bits[27:24]=cfg_off[11:8]  bits[23:16]=bus                    │      │
 │   │       bits[15:11]=device         bits[10:8]=function                │      │
 │   │       bits [7:0]=cfg_off[7:0]                                       │      │
 │   └─────────────────────────┬───────────────────────────────────────────┘      │
 └─────────────────────────────┼──────────────────────────────────────────────────┘
                               │
                               │  commlib (south, posix-mq or rabbitmq)
                               │  (MLX5_DEVPROC_1, VMM_GPU_PLUGIN_0)
                               ▼
 ┌────────────────────────────────────────────────────────────────────────────────┐
 │                      Process B: DevProc = TCX10                                │
 │                      (mellanox/dgx/devproc/)                                   │
 │                                                                                │
 │   south server  ─►  decode by BDF (primary vs secondary..subordinate)          │
 │                       │                                                        │
 │            ┌──────────┴──────────┐                                             │
 │            │                     │                                             │
 │    local mlx5 NIC          libcommlib_adapter.so                               │
 │    (libmlx.so)             (north client, dlopen'd)                            │
 │                                                                                │
 │   inbound from north (sysmem DMA, IRQ) ─► south PCIEConnection upstream        │
 │      tag: dfid = 0xff (DMA), interrupt_id = 0xff (IRQ)                         │
 └─────────────────────────────────────────────────────────┬──────────────────────┘
                                                          │
                                                          │  commlib (north)
                                                          │  (NVGPU_DEVPROC_1,
                                                          │   VMM_GPU_PLUGIN_0)
                                                          ▼
                                  ┌──────────────────────────────────────────────────┐
                                  │  Process C: devproc-GPU (functional model)       │
                                  │  /root/devproc_gpu/devproc/                      │
                                  │                                                  │
                                  │  Owns GPU PCI cfg shadow, MMIO regs, IRQ engine. │
                                  │  Initiates sysmem DMA + interrupts upstream.     │
                                  └──────────────────────────────────────────────────┘
```

DevProc is the bridge node. The **south side** retains the existing
commlib server pattern (talks to TB600's PCIe model). The **north
side** opens a new commlib client via
`/root/commlib_adapter/libcommlib_adapter.so` to the remote
devproc-GPU process. Both legs use commlib transport; devproc-GPU can
live on the same machine (posix-mq) or across the network
(rabbitmq).

### 3b. TCX10 internals — routing decision

```
                          TCX10 (DevProc process)
                ┌───────────────────────────────────────────┐
                │                                           │
   TB600 ──────►│  south PCIE_callbacks_t (existing server) │
   (commlib     │            │                              │
    south)      │            ▼                              │
                │   ┌──────────────────────────┐            │
                │   │ tb600_bus_from_offset    │            │
                │   │   = (offset >> 16) & 0xff│            │
                │   └──┬───────────┬───────────┘            │
                │      │           │                        │
                │  busn==primary   busn ∈ [sec..sub]        │
                │      │           │                        │
                │      ▼           ▼                        │
                │   local        libcommlib_adapter.so      │──── commlib ────► devproc-GPU
                │   mlx5         dlopen'd, lazy-open        │
                │   backend      ▲                          │
                │      │         │ inbound GPU              │
                │      │         │ sysmem cb / IRQ cb       │
                │      │         │                          │
                │      ▼         ▼                          │
                │    south PCIEConnection                   │
                │    PCIESysmemRead/Write (dfid=0xff)       │
                │    PCIEAssertInterrupt (irq_id=0xff)      │
                └───────────────────────────────────────────┘
```

### 3c. SCSIM-side wrapper modification

DevProc's BDF-based routing relies on SCSIM packing the bus number
into the south payload's `offset` field. SCSIM's existing NIC wrapper
(`nic_pcie_commlib_intf::PCIRead` / `PCIWrite`) currently **drops**
the BDF when calling its backend — that's correct for the standalone
NIC case but means DevProc never sees which bus a TLP targets.

The smallest viable change is a single OR in each function:

```scsim/nic_pcie_commlib_intf.cpp
// nic_pcie_commlib_intf::PCIRead — before:
//     nic_this_ptr->NicConfigRead(addr.Offset);
// after:
uint32_t packed = addr.Offset | (((uint32_t)addr.Bus) << 16);
nic_this_ptr->NicConfigRead(packed);

// nic_pcie_commlib_intf::PCIWrite — before:
//     nic_this_ptr->NicConfigWrite(addr.Offset, data_word);
// after:
uint32_t packed = addr.Offset | (((uint32_t)addr.Bus) << 16);
nic_this_ptr->NicConfigWrite(packed, data_word);
```

`bits[23:16]` of the packed value carry the target bus (per the
existing `MASK_PCI_BUS` convention from `pcie.h`). DevProc's already-
written `tb600_bus_from_offset()` extracts those bits and routes via
`tb600_bus_is_downstream()`.

**Backward compatibility**: this change is a no-op in non-bridge
configurations. CX10's own cfg has `addr.Bus = 0`, so `packed ==
addr.Offset` and the existing NIC behavior is preserved bit-for-bit.
The bridge case (`addr.Bus = secondary..subordinate`) is the only one
that produces a non-zero upper byte.

**Master-abort path unchanged**: the existing
`if (addr.Device != 0 || addr.Function != 0) → 0xFFFFFFFF` check at
the top of the function still fires for non-existent BDFs (e.g., BIOS
probing `01:01.0` during enumeration); only Bus 0 / Bus 1 device 0
function 0 reach the packing code.

**No change to libcommlib_adapter, the commlib protocol, or
devproc-GPU**: the wrapper passes `packed` into `NicConfigRead`,
which calls `pcie_config_read(handle, packed, ...)`, which sets
`PCIE_payload_t.cpu_access.offset = packed`. DevProc strips the bus
bits before forwarding to devproc-GPU, so devproc-GPU keeps seeing
the offset-only form it sees today on TB500.

End-to-end summary of the patch:

| Layer | Lines changed | Direction |
|---|---|---|
| SCSIM `nic_pcie_commlib_intf::PCIRead`  | +1 | south wire now carries bus |
| SCSIM `nic_pcie_commlib_intf::PCIWrite` | +1 | south wire now carries bus |
| libcommlib_adapter.so                   |  0 | passes `packed` verbatim as `offset` |
| commlib protocol                        |  0 | same `PCIE_payload_t` format |
| DevProc                                 |  0 | already extracts bus from bits[23:16] |
| devproc-GPU                             |  0 | DevProc strips bus before north forward |

## 4. Design decisions (locked in)

| # | Question | Choice | What it means in code |
|---|---|---|---|
| 1 | TB600 sees CX10 as | **Type-1 PCI-PCI bridge** | HEADER_TYPE = 0x01, primary/secondary/subordinate bus + memory base/limit registers at standard offsets 0x18..0x27. RM driver sees both CX10 (bridge) and GPU (downstream endpoint) in `lspci`. |
| 2 | Window register location | **Standard Type-1 mem_base/mem_limit (offsets 0x20/0x22)** | BIOS programs the bridge window during PCI enumeration like any other PCI-PCI bridge. No vendor cap needed for this. |
| 3 | GPU config-space access | **Native PCI config TLP routing by bus number** | TB600's BIOS just issues config TLPs to the GPU's BDF; TCX10 forwards them through `pcie_config_read/write`. No indirect addr/data tunnel. |
| 4 | DMA origin tag | **dfid = 0xff sentinel in PCIE_payload_t.dev_access** | Distinguishes GPU-origin DMA from CX10-NIC DMA. No commlib header change. |
| 5 | IRQ routing | **interrupt_id = 0xff sentinel; INTx-style level semantics** | libcommlib_adapter coalesces vectors internally; assert/deassert pair surfaces "any pending / drained". Matches EnableMSI=0 in current launches. |
| 6 | Linkage | **dlopen at runtime** | Path supplied via `--commlib-adapter-lib`. |
| 7 | Lifecycle | **Lazy north-client open** | First downstream TLP triggers `get_commslib_pcie_handle`. |

### Why Type-1 (vs the vendor-cap approach we explored)

A vendor-cap "single endpoint with bridge semantics" works (we built it
in the parked N1–N6 series at `/tmp/patches/tb600_bridge/`) but hides
the GPU from `lspci` and forces the RM driver to use a non-standard
indirect cfg path. Type-1 makes the GPU a first-class PCI device:
standard enumeration, standard config access, the existing RM driver
binds against the GPU's BDF without a special-case window walk.

## 5. Data-flow paths

### 5a. TB600 → CX10 local register (existing, unchanged)

```
TB600 CPU MMIO/cfg at CX10's BDF
   │
   ▼ commlib payload to DevProc (south server)
ProcessConfigRead/Write or ProcessMMIORead/Write
   │
   │  busn == primary_bus  ->  not in downstream range
   ▼
tb600_offset_strip_bdf(offset)   <- defensive: mask bus/dev/fn bits so
                                    libmlx.so always sees a clean offset,
                                    whether the SCSIM wrapper packed any
                                    bus bits or not. Bits[27:24] (ext cfg
                                    upper nibble) and bits[7:0] (low byte)
                                    survive.
   │
   ▼
mlx5_pci_config_access / mlx5_mmio_bar_access
   │
   ▼
Local CX10 NIC state in libmlx.so
```

### 5b. TB600 → GPU PCI config (new path: native PCI TLP forwarding)

```
TB600 BIOS issues config read at GPU BDF (secondary_bus:00.0)
   │
   ▼ commlib payload, offset encodes BDF + cfg offset per
     pcie.h MASK_PCI_* (bits[23:16] = bus, bits[27:24] = cfg_off[11:8],
     bits[7:0] = cfg_off[7:0], dev/fn at bits[15:8])
DevProc ProcessConfigRead
   │
   │  busn = tb600_bus_from_offset(offset) = (offset >> 16) & 0xff
   │  tb600_bus_is_downstream(busn) -> true
   ▼
tb600_north_init_once()  (opens north client on first hit)
   │
   ▼
libcommlib_adapter.so:
   pcie_config_read(handle,
                    tb600_offset_strip_bdf(offset),     // offset & 0x0F0000FF
                    &value)
   │
   ▼ commlib (north)
devproc-GPU's MASK_PCI_ADDR rebuilds the 12-bit cfg offset and returns
the value
```

### 5c. TB600 → GPU MMIO (new path: bridge window routing)

```
TB600 CPU MMIO at physical address X
   │
   ▼ commlib payload to DevProc
ProcessMMIORead/Write
   │
   │  tb600_addr_in_gpu_window(X) ?
   │  mem_base<<20 <= X <= (mem_limit<<20)|0xFFFFF
   ▼ yes
tb600_north_init_once()
   │
   ▼
libcommlib_adapter.so:
   pcie_mmio_write(handle, X, data, width)        // absolute address
   │
   ▼ commlib (north)
devproc-GPU MMIO handler
   decodes X against its own BAR layout (BARs were programmed
   by BIOS via the config tunnel, so devproc-GPU knows where
   each BAR lives in physical memory space)
```

The bridge does not translate the address. This matches real PCIe
PCI-PCI bridge behaviour — the bridge forwards a memory TLP with the
address field unchanged.

### 5d. GPU DMA → TB600 (inbound)

```
devproc-GPU initiates DMA write to host address Y
   │
   ▼ commlib payload to DevProc north client
libcommlib_adapter.so fires gpu_sysmem_write_callback(instance, Y, buf, len)
   │
   ▼
tb600_gpu_sysmem_write_cb
   builds PCIE_payload_t.dev_access with dfid = 0xff (GPU origin)
   chunks 4 bytes at a time
   │
   ▼ south PCIEConnection->PCIESysmemWrite()
TB600 sees DMA at addr Y, requester = "GPU sub-identity"
```

### 5e. GPU IRQ → TB600 (inbound)

```
devproc-GPU asserts interrupt
   │
   ▼ commlib (north)
libcommlib_adapter coalesces per-instance pending bits, fires
gpu_irq_assert_callback(instance) on quiet->pending transition
   │
   ▼
tb600_gpu_irq_assert_cb
   builds PCIE_payload_t.interrupt with interrupt_id = 0xff
   │
   ▼ south PCIEConnection->PCIEAssertInterrupt()
TB600 CPU sees IRQ, driver polls GPU to find what fired
```

### 5f. How DevProc learns the GPU MMIO window

`tb600_addr_in_gpu_window()` reads six cached fields:

  * non-prefetchable window: `mem_base`, `mem_limit`
  * prefetchable window: `pref_mem_base`, `pref_mem_limit`
    plus `pref_base_upper32`, `pref_limit_upper32` for 64-bit

All come from **observing host BIOS writes to CX10's standard Type-1
bridge registers** at config offsets `0x20`/`0x22` (non-pref),
`0x24`/`0x26` (pref low), and `0x28`/`0x2C` (pref upper-32 for 64-bit).

#### Register encoding (PCI 3.0 §3.2.5.6)

Each 16-bit window register stores **address bits [31:20] in its bits
[15:4]**; the low 4 bits are reserved, with bit 0 of the prefetchable
base register repurposed as the "64-bit capable" indicator. So the
correct decode is:

```c
decoded_base = (uint64_t)(raw & 0xfff0) << 16;            /* address [31:0] */
decoded_top  = ((uint64_t)(raw & 0xfff0) << 16) | 0xfffff;
```

For the 64-bit prefetchable case, the upper 32 bits come from the
upper-32 registers:

```c
if (pref_mem_base & 0x1) {                                /* 64-bit cap */
    decoded_base |= (uint64_t)pref_base_upper32  << 32;
    decoded_top  |= (uint64_t)pref_limit_upper32 << 32;
}
```

#### Why we need the prefetchable window for real GPUs

Real GR152-class NVIDIA GPUs (the ones devproc-GPU models) expose
**three 64-bit prefetchable BARs** at addresses well above 4 GB:

```
Region 0: Memory at 800100000000 (64-bit, prefetchable) [size=256M]
Region 2: Memory at 800110000000 (64-bit, prefetchable) [size=256M]
Region 4: Memory at 800510000000 (64-bit, prefetchable) [size=32M]
```

Zero non-prefetchable BARs. BIOS therefore won't program the
non-prefetchable window — it'll only program the 64-bit prefetchable
window pair. Without prefetchable support in
`tb600_addr_in_gpu_window()`, the bridge is non-functional for this
GPU.

#### Enumeration flow

```
TB600 BIOS during PCI enumeration of CX10:
  1. Reads HEADER_TYPE = 0x01 (Type-1 bridge), proceeds downstream.
  2. Discovers the GPU on the secondary bus; reads BAR sizes via
     the cfg tunnel (path 5b).
  3. Allocates host address space (e.g. all three pref BARs at
     0x800100000000..0x800517FFFFFF).
  4. Computes the prefetchable window covering the union:
        pref_base_upper32  = 0x00008001     // bits [63:32] of base
        pref_mem_base      = 0x0001         // bits [15:4]=0x000, bit 0=1 (64-bit cap)
        pref_limit_upper32 = 0x00008005     // bits [63:32] of limit
        pref_mem_limit     = 0x1FF1         // bits [15:4]=0x1FF, bit 0=1
  5. Writes the four registers (typically as two 4-byte dword writes):
        offset 0x24..0x27  <- (pref_mem_base    | pref_mem_limit << 16)
        offset 0x28..0x2B  <- pref_base_upper32
        offset 0x2C..0x2F  <- pref_limit_upper32
                                          │
                                          ▼ commlib (south)
                                ProcessConfigWrite in DevProc
                                          │
                                          ├─► libmlx.so config-space shadow
                                          │
                                          └─► tb600_observe_bridge_cfg_write
                                              caches all four pref-window fields
```

`tb600_observe_bridge_cfg_write()` handles any write width BIOS
chooses (byte / word / dword) by scanning the affected
`[addr, addr+len)` range and picking the right slice for each register.

After step 5, `tb600_addr_in_gpu_window(X)`:

```c
/* non-pref window (mostly unused for Grace GPUs) */
if (mem_limit >= mem_base && mem_limit > 0) {
    base = (uint64_t)(mem_base  & 0xfff0) << 16;
    top  = ((uint64_t)(mem_limit & 0xfff0) << 16) | 0xfffff;
    if (X in [base..top]) return true;
}
/* 64-bit prefetchable window (used by Grace GPUs) */
if (pref_mem_limit >= pref_mem_base) {
    base = (uint64_t)(pref_mem_base  & 0xfff0) << 16;
    top  = ((uint64_t)(pref_mem_limit & 0xfff0) << 16) | 0xfffff;
    if (pref_mem_base & 0x1) {                  /* 64-bit cap */
        base |= (uint64_t)pref_base_upper32  << 32;
        top  |= (uint64_t)pref_limit_upper32 << 32;
    }
    if (X in [base..top]) return true;
}
return false;
```

#### Why a cache instead of re-reading the libmlx.so shadow per TLP

Every MMIO TLP from TB600 needs the window check. Calling
`mlx5_do_pci_config_access()` four to six times per TLP would mean
that many function-pointer hops into another `.so` on the hot path.
Caching reduces the check to a handful of register loads. The cache
stays consistent because every host write to the relevant offsets
passes through `ProcessConfigWrite`, which updates the cache before
returning.

#### Writable masks

`mlx5_pci_config_bridge_init()` (in `mlx5_pci_config.c`) sets up:

```c
mlx_pci_config_set_word(pci_s->wmask + MLX5_PCI_MEMORY_BASE,         0xfff0);
mlx_pci_config_set_word(pci_s->wmask + MLX5_PCI_MEMORY_LIMIT,        0xfff0);
mlx_pci_config_set_word(pci_s->wmask + MLX5_PCI_PREF_MEMORY_BASE,    0xfff0);
mlx_pci_config_set_word(pci_s->wmask + MLX5_PCI_PREF_MEMORY_LIMIT,   0xfff0);
mlx_pci_config_set_dword(pci_s->wmask + MLX5_PCI_PREF_BASE_UPPER32,  0xffffffff);
mlx_pci_config_set_dword(pci_s->wmask + MLX5_PCI_PREF_LIMIT_UPPER32, 0xffffffff);
```

`0xfff0` is "bits [15:4] writable, [3:0] read-only" per spec for the
16-bit window registers; the upper-32 pair is fully writable. With
this, BIOS sees standard PCI-PCI bridge semantics and programs the
window like any third-party bridge.

## 6. Code-change footprint

| Layer | Files | Approx lines |
|---|---|---|
| CX10 bridge variant (Type-1 header + register layout) | `mlx5_pci_ids.h`, `mlx5_pci_config.[ch]`, `mlx5_config.[ch]`, `mlx5.h`, `mlx5_config_defaults.c`, `mlnx_infra/simx-qemu.cfg` | +176 |
| DevProc: dlopen / CLI / bridge-state cache | `mellanox/dgx/devproc/DevProc.[ch]` | +268 |
| DevProc: BDF + window routing in Process* | `mellanox/dgx/devproc/DevProc.cpp` | +66 |
| DevProc: GPU DMA upstream | `mellanox/dgx/devproc/DevProc.cpp` | +47 |
| DevProc: GPU IRQ upstream | `mellanox/dgx/devproc/DevProc.cpp` | +27 |
| Design + flow-chart docs | `mellanox/dgx/devproc/docs/TB600_BRIDGE_*.md` | +625 |

## 7. Configuration

```
DevProc \
   --client-id      MLX5_DEVPROC_1  --component-id     VMM_GPU_PLUGIN_0  \
   --gpu-client-id  NVGPU_DEVPROC_1 --gpu-component-id VMM_GPU_PLUGIN_0  \
   --gpu-instance-num 0                                                  \
   --commlib-adapter-lib /root/commlib_adapter/libcommlib_adapter.so
```

simx-qemu.cfg per-device section needs `bridge = true` to flip
device_id from CONNECTX10 (0x1027) to CONNECTX10_BRIDGE (0x2102) so
the Type-1 register layout fires at SimX init.

## 8. Smoke test

1. Launch devproc-GPU separately
2. Launch DevProc with the flags above and `bridge=true` in simx-qemu.cfg
3. Launch TB600 SCSIM
4. From the guest:
   ```
   lspci -tv
     -[0001:00]-+-00.0  Mellanox Technologies MT2910 PCIe Bridge
                  └─[01]-+-00.0  NVIDIA Corporation Device <id>

   setpci -s 01:00.0 VENDOR_ID         # round-trips through pcie_config_read to devproc-GPU
   setpci -s 01:00.0 COMMAND=0x6       # enable Memory + Bus Master
   ```
5. Map GPU BAR0, write/read → devproc-GPU's MMIO handler sees the access
6. Have devproc-GPU emit a DMA write to a guest-physical address → byte lands in TB600 RAM
7. Have devproc-GPU emit an IRQ → TB600's GPU driver IRQ handler fires

## 9. Open issues / future work

- **MSI-X vector granularity**: if launches flip to `EnableMSI=1`,
  libcommlib_adapter's per-instance assert callback loses the vector
  number. Either extend the library, or open a second south server
  bound to the GPU's BDF. Tracked but out of scope for the MVP.
- **Multiple GPUs per bridge**: today one north client per DevProc.
  Multi-GPU would mean multiple `(gpu_client_id, gpu_component_id,
  instance_num)` tuples and per-device bus-number ranges.
- **GPU hot-plug**: not modeled. Bridge sec_bus/sub_bus are programmed
  once at BIOS enumeration time.
- **Alternative (parked) design**: vendor-cap "hidden GPU" approach
  preserved in `/tmp/patches/tb600_bridge/` if needed for comparison.
