#!/usr/bin/env python3
import argparse, csv, json, statistics
from pathlib import Path
import run_lut_storage_benchmark as base
PREP="res://benchmark/tools/prepare_lut_manifest_benchmark.gd"
CASE="res://benchmark/tests/benchmark_lut_manifest_case.gd"
def parse():
    p=argparse.ArgumentParser(); p.add_argument("--godot",default="godot"); p.add_argument("--project",default="."); p.add_argument("--repeats",type=int,default=12); p.add_argument("--generate",action="store_true"); p.add_argument("--headless",action="store_true"); p.add_argument("--output",default="benchmark/results/lut_storage_manifest_benchmark/latest"); return p.parse_args()
def marked(text,prefix):
    for line in reversed(text.splitlines()):
        if line.startswith(prefix): return json.loads(line[len(prefix):])
    raise RuntimeError("missing result marker")
def run_manifest_prep(a):
    c=base.run_command(base.godot_command(a,PREP));
    if c.returncode: raise RuntimeError("manifest prep failed")
    return marked(c.stdout,"LUT_MANIFEST_PREP_RESULT ")
def run_manifest(a,kind):
    c=base.run_command(base.godot_command(a,CASE,[f"--kind={kind}"]));
    if c.returncode: raise RuntimeError("manifest case failed")
    return marked(c.stdout,"LUT_STORAGE_BENCHMARK_RESULT ")
def center(v): return float(statistics.median(v))
def spread(v):
    m=statistics.median(v); return float(statistics.median(abs(x-m) for x in v))
def main():
    a=parse();
    if a.repeats<3: raise SystemExit("--repeats must be at least 3")
    rows=[]; commands=[]
    try:
        base.ensure_raw_luts(a); direct_prep=base.prepare(a); manifest_prep=run_manifest_prep(a)
        cases=[("fast","raw"),("fast","direct"),("fast","manifest"),("cinematic","raw"),("cinematic","direct"),("cinematic","manifest")]
        for rep in range(a.repeats):
            n=rep%len(cases); order=cases[n:]+cases[:n]
            if rep%2: order=list(reversed(order))
            for oi,(kind,mode) in enumerate(order):
                if mode=="manifest": result=run_manifest(a,kind); cmd=base.godot_command(a,CASE,[f"--kind={kind}"])
                else: result=base.run_case(a,kind,mode); cmd=base.godot_command(a,base.CASE_SCRIPT,[f"--kind={kind}",f"--mode={mode}"])
                result["repeat"]=rep; result["order_index"]=oi; rows.append(result); commands.append(" ".join(cmd))
        groups={}
        for kind in ("fast","cinematic"):
            groups[kind]={}
            for mode in ("raw","direct","manifest"):
                selected=[r for r in rows if r["kind"]==kind and r["mode"]==mode]; g={"samples":len(selected)}
                for metric in ("resource_load_us","validation_us","texture_build_us","ready_us"):
                    vals=[float(r[metric]) for r in selected]; g[metric+"_median"]=center(vals); g[metric+"_mad"]=spread(vals)
                groups[kind][mode]=g
            r=groups[kind]["raw"]["ready_us_median"]; d=groups[kind]["direct"]["ready_us_median"]; m=groups[kind]["manifest"]["ready_us_median"]
            raw_size=float(direct_prep[kind]["raw_res_bytes"]); direct_size=float(direct_prep[kind]["direct_res_bytes"]); manifest_bytes=float(manifest_prep[kind]["manifest_res_bytes"]); total=direct_size+manifest_bytes
            groups[kind]["comparison"]={"direct_ready_over_raw_ready":d/r,"manifest_ready_over_raw_ready":m/r,"manifest_ready_over_direct_ready":m/d,"direct_size_over_raw_size":direct_size/raw_size,"manifest_total_size_over_raw_size":total/raw_size,"manifest_metadata_bytes":int(manifest_bytes),"manifest_total_bytes":int(total)}
        summary={"schema":"marschner_lut_storage_manifest_benchmark_v1","repeats_per_kind_mode":a.repeats,"groups":groups,"preparation":{"direct":direct_prep,"manifest":manifest_prep},"filesystem_cache_note":"fresh Godot processes; OS filesystem cache not flushed"}
        out=Path(a.output); out.mkdir(parents=True,exist_ok=True); (out/"summary.json").write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n"); (out/"commands.txt").write_text("\n".join(commands)+"\n")
        fields=["repeat","order_index","kind","mode","resource_load_us","validation_us","texture_build_us","ready_us","size_x","size_y","size_z","format","contract","godot_version","os"]
        with (out/"samples.csv").open("w",newline="") as f:
            w=csv.DictWriter(f,fieldnames=fields,extrasaction="ignore"); w.writeheader(); w.writerows(rows)
        print(json.dumps(groups,indent=2,sort_keys=True)); print("LUT_STORAGE_MANIFEST_BENCHMARK_OK"); return 0
    finally:
        base.run_command(base.godot_command(a,PREP,["--cleanup"])); base.cleanup(a)
if __name__=="__main__": raise SystemExit(main())
