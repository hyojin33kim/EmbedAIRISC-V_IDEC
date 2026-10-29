"""Extract measured START/AHB/DMA/MAC/DONE events from the native story VCD."""
import argparse
import bisect
import hashlib
import json
import re
from pathlib import Path


def signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def read_vcd(path):
    names, widths, changes, values = {}, {}, {}, {}
    events = {k: [] for k in ["start_address", "start_commit", "start_handshake",
                              "dma_read", "dma_write", "dma_command", "dma_response",
                              "mac", "done_event", "done_flag", "cpu_done_read"]}
    mac_checks = 0
    ticks = 0
    scale_ps = 1
    updates = {}

    def val(state, name):
        return state.get(names.get(name), 0)

    def flush(time, pending):
        nonlocal mac_checks
        if not pending:
            return
        before = values.copy()
        for code, value in pending.items():
            if code not in values or values[code] != value:
                changes[code].append((time, value))
                values[code] = value
        edge = val(before, "clk") == 0 and val(values, "clk") == 1
        if not edge:
            return
        v = lambda name: val(before, "story_" + name)
        after = lambda name: val(values, "story_" + name)
        if (v("csr_hsel") and v("csr_htrans") & 2 and v("csr_hwrite")
                and v("csr_hready") and v("csr_haddr") == 0x10080008):
            events["start_address"].append({"t": time, "address": v("csr_haddr"),
                                             "pc_m": v("cpu_pc_m")})
        if v("start_accept"):
            assert v("reg_commit") and v("reg_write") and v("reg_offset") == 8
            assert v("reg_wdata") == 1
            events["start_commit"].append({"t": time, "data": 1})
        if v("start_valid") and v("start_ready"):
            events["start_handshake"].append({"t": time})
        for kind, signal in [("dma_read", "dma_read_accept"), ("dma_write", "dma_write_accept")]:
            if v(signal):
                events[kind].append({"t": time, "address": v("dma_haddr")})
        if v("dma_cmd_valid") and v("dma_cmd_ready"):
            events["dma_command"].append({"t": time, "space": v("dma_space"),
                                           "bytes": v("dma_length")})
        if v("dma_rsp_valid") and v("dma_rsp_ready"):
            events["dma_response"].append({"t": time})
        if v("mac_valid"):
            a, b = signed(v("mac_a"), 9), signed(v("mac_b"), 9)
            product = signed(v("mac_product"), 18)
            previous, current = signed(v("mac_acc"), 32), signed(after("mac_acc"), 32)
            assert product == a * b, (time, "product", a, b, product)
            assert after("mac_acc") == (v("mac_acc") + product) & 0xffffffff, (time, "accumulator")
            assert after("mac_done") == 1 and not v("mac_clear")
            mac_checks += 1
            events["mac"].append({"t": time, "a": a, "b": b, "product": product,
                                    "acc_before": previous, "acc_after": current})
        for kind in ["done_event", "done_flag"]:
            if not v(kind) and after(kind):
                events[kind].append({"t": time})
        if v("cpu_saw_done"):
            assert v("reg_rdata") == 2
            events["cpu_done_read"].append({"t": time, "status": v("reg_rdata")})

    with Path(path).open() as stream:
        for line in stream:
            if "$timescale" in line:
                match = re.search(r"(\d+)\s*(fs|ps|ns|us|ms|s)", line)
                if match:
                    scale_ps = int(match[1]) * {"fs": .001, "ps": 1, "ns": 1000,
                                               "us": 1e6, "ms": 1e9, "s": 1e12}[match[2]]
            if "$var " in line:
                parts = line.split()
                width, code, name = int(parts[2]), parts[3], parts[4]
                if name.startswith("story_") or name in ("clk", "reset", "reset_ext"):
                    names[name], widths[name] = code, width
                    changes.setdefault(code, [])
            if "$enddefinitions" in line:
                break
        wanted = set(names.values())
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if line[0] == "#":
                flush(ticks, updates)
                updates = {}
                ticks = int(line[1:])
            elif line[0] in "01":
                code = line[1:]
                if code in wanted:
                    updates[code] = int(line[0])
            elif line[0] in "bB":
                bits, code = line[1:].split()
                if code in wanted:
                    if "x" in bits.lower() or "z" in bits.lower():
                        raise ValueError("Unknown value in observed signal: " + code)
                    updates[code] = int(bits, 2)
        flush(ticks, updates)
    data = {name: changes[code] for name, code in names.items()}
    return {"signals": data, "widths": widths, "events": events,
            "timescale_ps": scale_ps, "checked_mac_taps": mac_checks}


def make_summary(trace, vcd):
    e, scale = trace["events"], trace["timescale_ps"]
    assert len(e["start_commit"]) == 1 and len(e["done_flag"]) == 1
    t0 = e["start_commit"][0]["t"]
    done = e["done_flag"][0]["t"]
    clock = trace["signals"]["clk"]
    rises = [t for t, v in clock[:20] if v == 1]
    period = rises[1] - rises[0]
    first_nonzero = next(row for row in e["mac"] if row["product"] != 0)
    points = [
        ("START address accepted", e["start_address"][0]),
        ("START CSR commit", e["start_commit"][0]),
        ("Controller command handshake", e["start_handshake"][0]),
        ("First DMA read address accepted", e["dma_read"][0]),
        ("First MAC accumulation", e["mac"][0]),
        ("First non-zero MAC", first_nonzero),
        ("First output DMA write address", e["dma_write"][0]),
        ("Last output DMA write address", e["dma_write"][-1]),
        ("Controller DONE event", e["done_event"][0]),
        ("CSR DONE flag", e["done_flag"][0]),
        ("CPU reads DONE=1 BUSY=0", e["cpu_done_read"][0]),
    ]
    out = {"sample": 124, "inference_run": 0, "layer": 0,
           "source": "Native Verilator VCD; no illustrative timing",
           "vcd_sha256": hashlib.sha256(Path(vcd).read_bytes()).hexdigest(),
           "clock_period_ns": period * scale / 1000,
           "t0_ps": t0 * scale, "start_to_done_cycles": (done - t0) / period,
           "start_to_done_ns": (done - t0) * scale / 1000,
           "checked_mac_taps": trace["checked_mac_taps"],
           "dma_read_addresses": len(e["dma_read"]),
           "dma_write_addresses": len(e["dma_write"]),
           "mac_example": first_nonzero,
           "events": [{"name": name, **row, "relative_cycles": (row["t"] - t0) / period,
                       "absolute_ns": row["t"] * scale / 1000} for name, row in points],
           "dma_commands": e["dma_command"],
           "definitions": {"AHB_accept": "HTRANS[1] && HREADY at rising edge (address phase)",
                           "CSR_commit": "reg_commit && reg_write && offset=0x008 && data=1 at rising edge",
                           "MAC_check": "pre-edge A*B and ACC; post-edge ACC=ACC_before+A*B",
                           "CPU_done_read": "accepted CSR data-phase read STATUS=0x00000002"}}
    # The RTL schedules all nine taps, including zero-padded positions.
    # The C kernel skips those positions; both produce identical sums.
    assert trace["checked_mac_taps"] == 8 * 32 * 32 * 9
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("vcd", type=Path)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    trace = read_vcd(args.vcd)
    summary = make_summary(trace, args.vcd)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
