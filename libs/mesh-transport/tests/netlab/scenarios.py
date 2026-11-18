"""Linux side run: MESH_NETLAB_BIN=/absolute/path/netlab python3 scenarios.py OUTPUT_DIR.
Build the binary with cargo build --example netlab for the Linux host. Requires
unshare and ip, with user/network namespaces enabled; changes no host network rules.
MESH_SCENARIOS can select chain,soft,flap,native-baseline,native (all by default).
The first three use acceptance.py. Native modes are observations, not quantitative
acceptance: their successful exit alone does not prove path choice or timing.

The checker retains the frozen 2026-11-17 budgets: 5000 ms cold chain connect,
2540 ms first impaired soft request, 6000 ms both-end convergence, 200 ms warm
p95 (at least 10 samples), no flap switches. Keep failures and compare actual
selected QUIC paths, never the Router preference in SAMPLE. Each scenario verifies
35 x 64 KiB on the original stream. Separate five-node side coverage lives in
../chain.rs with its frozen 5000 ms recovery budget.
"""
import os, subprocess, pathlib, shutil, json, sys

binary=pathlib.Path(os.environ['MESH_NETLAB_BIN']).resolve(strict=True)
scripts=pathlib.Path(__file__).resolve().parent
output=pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True,exist_ok=False)
outcomes=[]
for scenario in os.environ.get('MESH_SCENARIOS','chain,soft,flap,native-baseline,native').split(','):
    if scenario not in ('chain','soft','flap','native-baseline','native'):
        raise ValueError('unknown scenario: '+scenario)
    directory=output/scenario; directory.mkdir()
    shutil.copy2(binary,directory/'netlab'); (directory/'netlab').chmod(0o755)
    for file in ['run.py','acceptance.py']: shutil.copy2(scripts/file,directory/file)
    with (directory/'netlab.log').open('w') as log:
        run=subprocess.run([sys.executable,'run.py'],cwd=directory,env={**os.environ,'MESH_SCENARIO':scenario},stdout=log,stderr=subprocess.STDOUT)
    acceptance=None
    if run.returncode==0 and not scenario.startswith('native'):
        with (directory/'acceptance.json').open('w') as report:
            acceptance=subprocess.run([sys.executable,'acceptance.py','result.json'],cwd=directory,stdout=report).returncode
    outcomes.append({'scenario':scenario,'run_exit':run.returncode,'acceptance_exit':acceptance})
    print(json.dumps(outcomes[-1]),flush=True)
(output/'outcomes.json').write_text(json.dumps(outcomes,indent=2))
raise SystemExit(0 if all(x['run_exit']==0 and (x['scenario'].startswith('native') or x['acceptance_exit']==0) for x in outcomes) else 1)
