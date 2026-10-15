"""Writes the deploy workflows into every sibling repository from templates/ (one source, no drift).

    python3 scripts/generate-workflows.py [--check]

--check exits 1 if any repository's generated workflow differs from the template (run it in CI).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = ROOT.parent
TEMPLATES = ROOT / "templates"
SERVICES = ["auth-service", "product-service", "inventory-service", "order-service", "payment-service", "notification-service", "saga-orchestrator"]

def render(name: str, service: str) -> str:
    return (TEMPLATES / name).read_text().replace("__SERVICE__", service).replace("__HAS_MIGRATIONS__", "true")

def targets():
    for s in SERVICES:
        repo = WORKSPACE / f"ecommerce-{s}"
        yield repo, {"deploy.yml": render("deploy.yml", s), "deploy-environment.yml": render("deploy-job.yml", s)}
    repo = WORKSPACE / "ecommerce-frontend"
    yield repo, {"deploy.yml": render("deploy.yml", "frontend"), "deploy-environment.yml": (TEMPLATES / "deploy-frontend-job.yml").read_text()}

def with_workflow_call(ci: str) -> str:
    """deploy.yml runs each repository's own CI first, as a reusable workflow."""
    if "workflow_call:" in ci:
        return ci
    return re.sub(r"^on:\n", "on:\n  workflow_call:\n", ci, count=1, flags=re.M)

check = "--check" in sys.argv
stale = []
for repo, files in targets():
    wf = repo / ".github" / "workflows"
    files["ci.yml"] = with_workflow_call((wf / "ci.yml").read_text())
    for name, content in files.items():
        path = wf / name
        current = path.read_text() if path.exists() else None
        if current == content:
            continue
        if check:
            stale.append(str(path.relative_to(WORKSPACE)))
        else:
            path.write_text(content)
            print(f"wrote {path.relative_to(WORKSPACE)}")
if stale:
    print("stale generated workflows:\n  " + "\n  ".join(stale))
    sys.exit(1)
