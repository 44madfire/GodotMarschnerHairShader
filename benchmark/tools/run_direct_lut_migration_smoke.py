#!/usr/bin/env python3
"""Materialize and verify direct ImageTexture3D production LUTs."""
import argparse, subprocess, sys
from pathlib import Path
FAST_RAW=Path("benchmark/resources/luts/unity_azimuthal_64.res")
CIN_RAW=Path("benchmark/resources/luts/cinematic_longitudinal_kernel_128x128x64.res")
FAST_GEN="res://benchmark/tools/generate_unity_hair_azimuthal_lut.gd"
CIN_GEN="res://benchmark/tools/generate_marschner_cinematic_longitudinal_lut.gd"
MATERIALIZE="res://benchmark/tools/materialize_direct_production_luts.gd"
INTEGRITY="res://benchmark/tests/test_direct_lut_resource_integrity.gd"
BINDING="res://benchmark/tests/test_direct_lut_binding.gd"
def parse():
 p=argparse.ArgumentParser(); p.add_argument("--godot",default="godot"); p.add_argument("--project",default="."); p.add_argument("--gpu-index",type=int); p.add_argument("--generate-raw",action="store_true"); p.add_argument("--skip-binding",action="store_true"); return p.parse_args()
def cmd(a,script,headless):
 out=[a.godot]; out += ["--headless"] if headless else ["--disable-vsync"]
 if not headless and a.gpu_index is not None: out += ["--gpu-index",str(a.gpu_index)]
 return out+["--path",str(Path(a.project)),"--script",script]
def run(a,script,headless,marker):
 c=cmd(a,script,headless); print("+"," ".join(c),flush=True); p=subprocess.run(c,text=True,capture_output=True)
 if p.stdout: print(p.stdout,end="")
 if p.stderr: print(p.stderr,end="",file=sys.stderr)
 if p.returncode or marker not in p.stdout: raise RuntimeError("failed: "+script)
def main():
 a=parse(); project=Path(a.project); missing=[]
 if not (project/FAST_RAW).exists(): missing.append((FAST_RAW,FAST_GEN,"UNITY_HAIR_AZIMUTHAL_LUT_GENERATION_OK"))
 if not (project/CIN_RAW).exists(): missing.append((CIN_RAW,CIN_GEN,"MARSCHNER_CINEMATIC_LONGITUDINAL_LUT_GENERATION_OK"))
 if missing and not a.generate_raw: raise RuntimeError("missing raw LUT source(s); rerun with --generate-raw")
 for _,script,marker in missing: run(a,script,True,marker)
 run(a,MATERIALIZE,True,"DIRECT_LUT_MATERIALIZATION_OK")
 run(a,INTEGRITY,True,"DIRECT_LUT_RESOURCE_INTEGRITY_OK")
 if not a.skip_binding: run(a,BINDING,False,"DIRECT_LUT_BINDING_OK")
 print("DIRECT_LUT_MIGRATION_SMOKE_OK"); return 0
if __name__=="__main__": raise SystemExit(main())
