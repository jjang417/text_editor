#!/bin/sh
# Walk the PCIe extended capability chain over raw ECAM and dump a DVSEC.
#
# Why raw ECAM instead of setpci/lspci: when Linux sizes a device at
# cfg_size=256 (see the "kernel sees" line printed per device below), it
# refuses every offset >= 0x100 and returns ffffffff WITHOUT emitting a TLP.
# The whole extended capability space, DVSECs included, becomes invisible to
# the standard tools. busybox devmem on the ECAM window bypasses that gate.
#
# Nothing is hardcoded: the ECAM base comes from the ACPI MCFG table, the
# capability offset comes from walking the chain, and the register offsets
# inside the capability come from the DVSEC layout itself.
#
# Usage: walk_dvsec_ecam.sh [BDF] [DVSEC_ID]
#          BDF       default: every NVIDIA (0x10de) device
#          DVSEC_ID  default: 3   (PDI / device specific static info)
# Env:     ECAM_BASE=0x...  skip MCFG parsing and force the base
#
# Run as root.

BDF_ARG="$1"
WANT_ID="${2:-3}"
MCFG=/sys/firmware/acpi/tables/MCFG

# PCIe extended capability ID for DVSEC.
CAP_ID_DVSEC=0x23

# Spec-required DVSEC length per designated ID (Confluence PCIEGEN6/2546647042).
# Used only to flag a mismatch; 0 means "no expectation encoded here".
spec_len_for_id() {
    case "$1" in
        0) echo 0x1c ;;
        1) echo 0x10 ;;
        2) echo 0x14 ;;
        3) echo 0x14 ;;
        *) echo 0 ;;
    esac
}

rd32() {   # rd32 <addr> -> decimal, or empty on failure
    v=$(busybox devmem "$1" 32 2>/dev/null) || return 1
    [ -n "$v" ] || return 1
    echo $(( v ))
}

# Resolve the ECAM base for a PCI segment+bus out of the ACPI MCFG table.
# MCFG layout: 36-byte ACPI header, 8 reserved, then 16-byte allocations of
# { u64 base, u16 segment, u8 start_bus, u8 end_bus, u32 reserved }.
ecam_base() {
    seg_want=$1 bus_want=$2
    [ -n "$ECAM_BASE" ] && { echo $(( ECAM_BASE )); return 0; }
    [ -r "$MCFG" ] || return 1

    # Byte-slurp into B0..Bn. -v so identical lines are not collapsed.
    i=0
    for byte in $(od -An -v -tx1 -j 44 "$MCFG" 2>/dev/null); do
        eval "B$i=0x$byte"
        i=$(( i + 1 ))
    done
    [ "$i" -ge 16 ] || return 1

    rec=0
    while [ $(( rec + 16 )) -le "$i" ]; do
        base=0
        for k in 7 6 5 4 3 2 1 0; do
            eval "v=\$B$(( rec + k ))"
            base=$(( base * 256 + v ))
        done
        eval "s_lo=\$B$(( rec + 8 ))"; eval "s_hi=\$B$(( rec + 9 ))"
        eval "sb=\$B$(( rec + 10 ))";  eval "eb=\$B$(( rec + 11 ))"
        # test(1) only understands decimal, so normalise before comparing.
        seg=$(( s_hi * 256 + s_lo ))
        sb=$(( sb )); eb=$(( eb ))
        if [ "$seg" -eq "$seg_want" ] && [ "$bus_want" -ge "$sb" ] && [ "$bus_want" -le "$eb" ]; then
            echo "$base"
            return 0
        fi
        rec=$(( rec + 16 ))
    done
    return 1
}

dump_dvsec() {   # dump_dvsec <cfg_base> <cap_off> <len> <dvsec_id>
    cfg=$1 cap=$2 len=$3 did=$4

    # Dump the declared extent, plus 2 dwords past it. The overrun is
    # deliberate: a too-short declared length is exactly the defect we are
    # looking for, and PDI high can fall outside it.
    ndw=$(( (len + 3) / 4 + 2 ))
    dw=0
    while [ "$dw" -lt "$ndw" ]; do
        off=$(( cap + dw * 4 ))
        addr=$(printf '0x%x' $(( cfg + off )))
        val=$(busybox devmem "$addr" 32 2>/dev/null)

        note=''
        case $(( dw * 4 )) in
            0)  note='cap header' ;;
            4)  note='DVSEC hdr1  (vendor/rev/length)' ;;
            8)  note='DVSEC hdr2  (designated ID)' ;;
            12) [ "$did" -eq 3 ] && note='PDI low' ;;
            16) [ "$did" -eq 3 ] && note='PDI high' ;;
        esac
        [ $(( dw * 4 )) -ge "$len" ] && note="${note:+$note }<-- BEYOND declared length"

        printf '      +%#04x  %s  %-14s  %s\n' $(( dw * 4 )) "$addr" "$val" "$note"
        dw=$(( dw + 1 ))
    done
}

probe_bdf() {
    bdf=$1
    dom=0x$(echo "$bdf" | cut -d: -f1)
    bus=0x$(echo "$bdf" | cut -d: -f2)
    dev=0x$(echo "$bdf" | cut -d: -f3 | cut -d. -f1)
    fn=$(echo "$bdf" | cut -d. -f2)
    dom=$(( dom )); bus=$(( bus )); dev=$(( dev )); fn=$(( fn ))

    base=$(ecam_base "$dom" "$bus") || {
        echo "  $bdf : no MCFG allocation for segment $dom bus $bus (set ECAM_BASE=)"
        return 1
    }
    cfg=$(( base + (bus << 20) + (dev << 15) + (fn << 12) ))

    cfgsz=$(stat -c%s "/sys/bus/pci/devices/$bdf/config" 2>/dev/null)
    printf '%s   ECAM %#x   (kernel sees %s bytes of config space' "$bdf" "$cfg" "${cfgsz:-?}"
    [ "${cfgsz:-0}" -le 256 ] && printf ' -- setpci/lspci CANNOT reach ext cfg'
    printf ')\n'

    # Walk the chain. 0x100 is the only fixed offset: PCIe puts the first
    # extended capability header there by definition.
    off=0x100
    off=$(( off ))
    hops=0
    found=0
    seen_ids=''
    while [ "$off" -ne 0 ] && [ "$hops" -lt 64 ]; do
        hdr=$(rd32 $(printf '0x%x' $(( cfg + off )))) || break
        if [ "$hdr" -eq 4294967295 ] || [ "$hdr" -eq 0 ]; then
            [ "$hops" -eq 0 ] && echo "  no extended capabilities at 0x100 (read $(printf '%#010x' $hdr)) -- wrong ECAM base, or none present"
            break
        fi

        cap_id=$(( hdr & 0xFFFF ))
        next=$(( (hdr >> 20) & 0xFFF ))

        if [ "$cap_id" -eq $(( CAP_ID_DVSEC )) ]; then
            h1=$(rd32 $(printf '0x%x' $(( cfg + off + 4 ))))
            h2=$(rd32 $(printf '0x%x' $(( cfg + off + 8 ))))
            vend=$(( h1 & 0xFFFF ))
            rev=$(( (h1 >> 16) & 0xF ))
            len=$(( (h1 >> 20) & 0xFFF ))
            did=$(( h2 & 0xFFFF ))
            seen_ids="$seen_ids $did"

            if [ "$did" -eq "$WANT_ID" ]; then
                found=1
                want=$(spec_len_for_id "$did")
                want=$(( want ))
                printf '  DVSEC ID %d found at cap offset %#05x\n' "$did" "$off"
                printf '    vendor %#06x  rev %d  length %#05x' "$vend" "$rev" "$len"
                if [ "$want" -ne 0 ] && [ "$len" -ne "$want" ]; then
                    printf '   <-- MISMATCH, spec requires %#05x\n' "$want"
                else
                    printf '\n'
                fi
                dump_dvsec "$cfg" "$off" "$len" "$did"
                if [ "$did" -eq 3 ]; then
                    lo=$(busybox devmem $(printf '0x%x' $(( cfg + off + 12 ))) 32 2>/dev/null)
                    hi=$(busybox devmem $(printf '0x%x' $(( cfg + off + 16 ))) 32 2>/dev/null)
                    printf '    PDI = %s:%s' "$hi" "$lo"
                    if [ "$(( lo ))" -eq 0 ] && [ "$(( hi ))" -eq 3735928559 ]; then
                        printf '   <-- unpopulated (0 / 0xDEADBEEF filler)\n'
                    else
                        printf '\n'
                    fi
                fi
            fi
        fi

        off=$next
        hops=$(( hops + 1 ))
    done

    [ "$found" -eq 0 ] && \
        printf '  DVSEC ID %s NOT found after %d capabilities (DVSEC IDs seen:%s)\n' \
            "$WANT_ID" "$hops" "${seen_ids:- none}"
    echo
}

[ "$(id -u)" -eq 0 ] || { echo "must run as root (raw ECAM access)"; exit 1; }
command -v busybox >/dev/null 2>&1 || { echo "busybox not found"; exit 1; }

if [ -n "$BDF_ARG" ]; then
    probe_bdf "$BDF_ARG"
else
    for d in /sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        probe_bdf "$(basename "$d")"
    done
fi
