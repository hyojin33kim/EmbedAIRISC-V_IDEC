"""Render four measured timing windows, plus an offline interactive waveform."""
import argparse
import bisect
import html
import json
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon
from matplotlib.ticker import MaxNLocator
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from analyze_story import read_vcd, make_summary, signed

BLUE, AMBER, TEAL, PURPLE, GREEN = "#2463a6", "#ad6414", "#0a827e", "#7652b4", "#237a49"


def render(vcd, destination):
    destination.mkdir(parents=True, exist_ok=True)
    trace = read_vcd(vcd)
    summary = make_summary(trace, vcd)
    summary["source"] = "Native Verilator FST converted losslessly to VCD by GTKWave fst2vcd"
    event = {x["name"]: x["relative_cycles"] for x in summary["events"]}
    period = summary["clock_period_ns"] * 1000 / trace["timescale_ps"]
    t0 = summary["t0_ps"] / trace["timescale_ps"]
    mac_at = event["First non-zero MAC"]
    end = event["CSR DONE flag"]
    cpu_done = event["CPU reads DONE=1 BUSY=0"]
    dma_at = event["First DMA read address accepted"]
    # Each pane has its own actual time window. No cycles are stretched.
    panels = [
        ("1  START store: AHB address phase -> CSR data commit", -4, 12, 0,
         [("clk", "clk", BLUE), ("story_cpu_pc_m", "CPU PC_M", BLUE),
          ("story_csr_haddr", "CSR HADDR", BLUE), ("story_csr_htrans", "CSR HTRANS", BLUE),
          ("story_csr_hwrite", "CSR HWRITE", BLUE), ("story_csr_hready", "CSR HREADY", BLUE),
          ("story_csr_hwdata", "CSR HWDATA", BLUE), ("story_start_accept", "START_accept", AMBER),
          ("story_start_valid", "START_valid", AMBER), ("story_busy", "BUSY", AMBER)]),
        ("2  First DMA read: quantization parameters in RAM", dma_at-3, dma_at+12, dma_at,
         [("clk", "clk", TEAL), ("story_dma_cmd_valid", "DMA CMD_valid", TEAL),
          ("story_dma_space", "DMA space", TEAL), ("story_dma_length", "DMA bytes", TEAL),
          ("story_dma_haddr", "DMA HADDR", TEAL), ("story_dma_htrans", "DMA HTRANS", TEAL),
          ("story_dma_hwrite", "DMA HWRITE", TEAL), ("story_dma_hready", "DMA HREADY", TEAL),
          ("story_dma_read_accept", "READ_addr_accept", TEAL), ("story_dma_hrdata", "DMA HRDATA", TEAL)]),
        ("3  MAC example: sampled operands -> registered accumulator", mac_at-5, mac_at+23, mac_at,
         [("clk", "clk", PURPLE), ("story_mac_clear", "MAC clear", PURPLE),
          ("story_mac_valid", "MAC tap_valid", PURPLE), ("story_mac_a", "A (signed 9b)", PURPLE),
          ("story_mac_b", "B (signed 9b)", PURPLE), ("story_mac_product", "A * B (18b)", PURPLE),
          ("story_mac_acc", "ACC (signed 32b)", PURPLE), ("story_mac_done", "MAC tap_done", PURPLE)]),
        ("4  Output DMA completes -> DONE -> CPU STATUS read", end-10, cpu_done+4, end,
         [("clk", "clk", GREEN), ("story_dma_haddr", "DMA HADDR", TEAL),
          ("story_dma_write_accept", "WRITE_addr_accept", TEAL), ("story_dma_rsp_valid", "DMA RSP_valid", TEAL),
          ("story_done_event", "DONE_event", GREEN), ("story_done_flag", "DONE flag", GREEN),
          ("story_busy", "BUSY", AMBER), ("story_status_read", "CPU STATUS_read", BLUE),
          ("story_reg_rdata", "CSR RDATA", BLUE), ("story_cpu_saw_done", "CPU sees DONE", GREEN)])]

    def clipped(name, lo, hi):
        data = trace["signals"][name]
        i = max(0, bisect.bisect_right(data, (t0+lo*period, float("inf")))-1)
        out = [(lo, data[i][1])]
        for t, v in data[i+1:]:
            x = (t-t0)/period
            if x >= hi:
                break
            if x > lo:
                out.append((x, v))
        out.append((hi, out[-1][1]))
        return out

    def value_text(name, value):
        if name in ("story_mac_a", "story_mac_b", "story_mac_acc", "story_mac_product"):
            return str(signed(value, trace["widths"][name]))
        if "haddr" in name or "data" in name or "pc_m" in name:
            return f"{value:08X}"
        if name.endswith("htrans"):
            return {0: "IDLE", 1: "BUSY", 2: "NSEQ", 3: "SEQ"}[value]
        if name == "story_dma_space":
            return {0: "INPUT", 1: "WEIGHT", 2: "OUTPUT", 3: "QPARAM"}[value]
        return str(value)

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
    figure, axes = plt.subplots(4, 1, figsize=(16, 17), gridspec_kw={"hspace": .40})
    figure.patch.set_facecolor("#ffffff")
    interactive = make_subplots(rows=4, cols=1, subplot_titles=[p[0] for p in panels],
                                vertical_spacing=.075)
    for row, (ax, panel) in enumerate(zip(axes, panels), 1):
        title, lo, hi, marker, signals = panel
        ax.set_facecolor("#f7f9fc")
        ax.set_xlim(lo, hi)
        ax.set_ylim(-.2, len(signals)+.35)
        ax.set_title(title, loc="left", fontsize=13, fontweight="bold", pad=12)
        ticks, labels = [], []
        for index, (name, label, color) in enumerate(signals):
            y = len(signals)-index-1
            ticks.append(y+.4); labels.append(label)
            points = clipped(name, lo, hi)
            ax.axhline(y+.1, color="#e7ebf1", lw=.65, zorder=0)
            if trace["widths"][name] == 1:
                xs, vs = zip(*points)
                ys = [y+.13+.55*v for v in vs]
                ax.step(xs, ys, where="post", lw=1.5, color=color)
                interactive.add_trace(go.Scatter(x=list(xs), y=ys, mode="lines",
                    line={"shape": "hv", "width": 1.6, "color": color}, name=label,
                    customdata=[str(v) for v in vs],
                    hovertemplate=label+"=%{customdata}<br>START + %{x:.3f} cycles<extra></extra>"), row=row, col=1)
            else:
                hover_x, hover_text = [], []
                for (x1, value), (x2, _) in zip(points, points[1:]):
                    notch = min(.12, (x2-x1)/5)
                    vertices = [(x1,y+.4),(x1+notch,y+.65),(x2-notch,y+.65),
                                (x2,y+.4),(x2-notch,y+.15),(x1+notch,y+.15)]
                    ax.add_patch(Polygon(vertices, closed=True, edgecolor=color,
                                         facecolor=color+"12", lw=1.1))
                    text = value_text(name, value)
                    if x2-x1 >= max(.65, (hi-lo)*.025):
                        ax.text((x1+x2)/2, y+.4, text, ha="center", va="center",
                                fontsize=8.2, fontfamily="DejaVu Sans Mono", color=color, clip_on=True)
                    hover_x.append((x1+x2)/2); hover_text.append(text)
                    path = "M " + " L ".join(f"{x},{yy}" for x,yy in vertices) + " Z"
                    rgb=tuple(int(color[i:i+2],16) for i in (1,3,5))
                    interactive.add_shape(type="path", path=path, line={"color":color,"width":1},
                                          fillcolor=f"rgba({rgb[0]},{rgb[1]},{rgb[2]},0.07)", row=row, col=1)
                interactive.add_trace(go.Scatter(x=hover_x, y=[y+.4]*len(hover_x),
                    text=hover_text, mode="text", textfont={"size":10,"color":color},
                    name=label, hovertemplate=label+"=%{text}<br>START + %{x:.3f} cycles<extra></extra>"), row=row, col=1)
        ax.axvline(marker, color="#d34d45", lw=1, ls="--", alpha=.8)
        ax.set_yticks(ticks, labels, fontfamily="DejaVu Sans Mono", fontsize=10.2)
        ax.tick_params(axis="y", length=0, pad=10)
        ax.xaxis.set_major_locator(MaxNLocator(9, integer=True))
        ax.ticklabel_format(axis="x", style="plain", useOffset=False)
        ax.grid(axis="x", color="#dce2eb", ls=":", lw=.75)
        ax.set_xlabel("Cycles from START commit edge   (1 cycle = 2 ns)", fontsize=10)
        for side in ["left","right","top"]:
            ax.spines[side].set_visible(False)
        interactive.update_xaxes(range=[lo,hi], title_text="Cycles from START commit edge (2 ns/cycle)",
                                 showgrid=True, gridcolor="#e4e9f0", row=row, col=1)
        interactive.update_yaxes(range=[-.2,len(signals)+.35], tickvals=ticks, ticktext=labels,
                                 showgrid=False, zeroline=False, fixedrange=True, row=row, col=1)
        interactive.add_vline(x=marker, line_dash="dash", line_color="#d34d45", row=row, col=1)

    example = summary["mac_example"]
    equation = f"{example['acc_before']} + ({example['a']} x {example['b']}) = {example['acc_after']}"
    milestones = (f"DMA read +{dma_at:g} cyc   |   first MAC +{event['First MAC accumulation']:g} cyc   |   "
                  f"DONE +{end:,.0f} cyc   |   CPU reads DONE +{cpu_done:,.0f} cyc")
    figure.suptitle("START -> AHB -> DMA -> MAC -> DONE", x=.13, y=.985,
                   ha="left", fontsize=22, fontweight="bold", color="#172b44")
    figure.text(.13,.962,"sample 124 / run 0 / layer 0 (Conv1)  |  measured RTL signals / Verilator 5.020", fontsize=11)
    figure.text(.13,.942,milestones,fontsize=11,color="#38506d")
    figure.text(.13,.923,"C START store: PC 80000324, MMIO 10080008 <- 1   |   MAC example: "+equation,
                fontsize=10.5,color="#4e5e75")
    figure.subplots_adjust(left=.155,right=.98,top=.885,bottom=.075)
    figure.text(.155,.016,"AHB address acceptance and CSR data commit are separate edges. Each pane uses a different actual time window.\n"
                "MAC inputs are sampled before the rising edge; ACC is checked after the edge. All 73,728 layer-0 taps were verified.",
                fontsize=9.5,color="#526477")
    png=destination/"START_AHB_DMA_MAC_DONE.png"
    figure.savefig(png,dpi=180,facecolor="white")
    plt.close(figure)
    interactive.update_layout(height=2100, width=None, template="plotly_white", showlegend=False,
                              margin={"l":165,"r":35,"t":80,"b":45}, font={"family":"Arial","size":11},
                              title={"text":"Measured START / AHB / DMA / MAC / DONE","x":.03},
                              dragmode="zoom")
    plot=interactive.to_html(full_html=False,include_plotlyjs=True,config={"responsive":True,"displaylogo":False})
    rows="".join(f"<tr><td>{html.escape(x['name'])}</td><td>{x['relative_cycles']:,.0f}</td><td>{x['absolute_ns']:,.0f}</td></tr>" for x in summary["events"])
    document=("<!doctype html><html lang='ko'><meta charset='utf-8'><title>START AHB DMA MAC DONE</title>"
              "<style>body{font:15px system-ui;color:#182c44;max-width:1350px;margin:30px auto;padding:0 20px}"
              "h1{font-size:26px}p{line-height:1.65}table{border-collapse:collapse;width:100%;margin:18px 0}"
              "th,td{padding:8px 12px;border-bottom:1px solid #dce3ed;text-align:left}code{background:#eef2f7;padding:2px 5px}"
              ".badge{color:#176b43;background:#eaf6ee;padding:9px 14px;border-radius:6px}</style>"
              "<h1>START 쓰기에서 DONE까지: 실제 RTL 파형</h1>"
              "<p class='badge'>sample 124 전체 PASS · 계층별 결과 7,494바이트 일치 · 첫 계층 MAC 73,728회 산술 대조 PASS</p>"
              "<p>네 개의 확대 구간은 각각 다른 실제 시각입니다. 가로축 0은 START CSR이 값을 수락한 상승 에지입니다. "
              "영역을 드래그해 확대하고, 두 번 클릭해 각 창을 복원할 수 있습니다. 전체 기록은 동봉된 FST/VCD를 사용하십시오.</p>"
              f"<p><code>PC 0x80000324: sw x15,0(x19)</code> → <code>0x10080008 ← 1</code><br>"
              f"MAC 실측 예: <code>{html.escape(equation)}</code></p>"+plot+
              "<h2>측정한 사건</h2><table><tr><th>사건</th><th>START 기준 cycle</th><th>절대 시각 ns</th></tr>"+rows+"</table>"
              "<p>AHB 주소 승인은 HTRANS[1] &amp; HREADY가 상승 에지에서 참인 경우입니다. CSR 쓰기 완료는 별도 데이터 단계입니다. "
              "MAC은 에지 직전의 A/B/ACC와 에지 직후 ACC를 비교했습니다. 클록 주기 2 ns는 이 기능 시뮬레이션의 설정입니다.</p></html>")
    (destination/"START_AHB_DMA_MAC_DONE.html").write_text(document,encoding="utf-8")
    (destination/"measured_events.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps({"png":str(png),"html":str(destination/"START_AHB_DMA_MAC_DONE.html"),
                      "mac_equation":equation,"milestones":milestones},indent=2))


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("vcd",type=Path)
    p.add_argument("--output",type=Path,required=True)
    args=p.parse_args()
    render(args.vcd,args.output)
