#!/usr/bin/env python3
"""CKA Lab Web UI — manage KVM lab from the browser."""

import glob
import json
import os
import subprocess
import threading

from flask import Flask, jsonify, request, render_template_string

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
KEY_FILE   = os.path.join(SCRIPT_DIR, "cka-lab-key")
BASE_DIR   = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "base-images"))
K8S_IMAGE       = os.path.join(BASE_DIR, "ubuntu-22.04-cka-k8s.qcow2")
K8S_PREV_IMAGE  = os.path.join(BASE_DIR, "ubuntu-22.04-cka-k8s-prev.qcow2")
BASE_IMAGE      = os.path.join(BASE_DIR, "ubuntu-22.04-cka-base.qcow2")

CONTROL_IP = "192.168.100.10"
SSH_BASE   = ["ssh", "-i", KEY_FILE, "-o", "StrictHostKeyChecking=no",
              "-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]

TASKS = [
    {
        "id": "01", "name": "Broken Node",
        "desc": "Fix a NotReady worker node caused by kubelet misconfiguration.",
        "scenario": "The kubelet on <b>cka-worker-01</b> has been pointed at a wrong API server address in its kubeconfig. The node appears <b>NotReady</b> in the cluster.",
        "objective": "Diagnose why the kubelet on <b>cka-worker-01</b> cannot reach the API server and restore the node to <b>Ready</b>.",
        "hints": [
            "Check node status: <code>kubectl get nodes</code>",
            "On worker-01, check kubelet logs: <code>journalctl -u kubelet -n 50</code>",
            "The kubelet kubeconfig is <code>/etc/kubernetes/kubelet.conf</code> — check the <code>server:</code> line",
            "The control plane is at <code>https://192.168.100.10:6443</code>",
            "After fixing: <code>sudo systemctl restart kubelet</code>",
        ],
        "verify": "kubectl get nodes — cka-worker-01 must show Ready",
    },
    {
        "id": "02", "name": "etcd Backup",
        "desc": "Snapshot the etcd database to a file on the control plane.",
        "scenario": "No changes have been made to the cluster. You need to take a point-in-time backup of <b>etcd</b> before a risky change.",
        "objective": "Create an etcd snapshot at <b>/opt/etcd-backup.db</b> on the control plane node.",
        "hints": [
            "etcd runs as a static pod; find its certs: <code>sudo ls /etc/kubernetes/pki/etcd/</code>",
            "Install etcdctl if needed: download it from <code>github.com/etcd-io/etcd/releases</code> (the task text has the exact commands)",
            "Snapshot command: <code>sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \\\n  --endpoints=https://127.0.0.1:2379 \\\n  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\\n  --cert=/etc/kubernetes/pki/etcd/server.crt \\\n  --key=/etc/kubernetes/pki/etcd/server.key</code>",
            "Verify: <code>sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db</code> (with the same cert flags)",
        ],
        "verify": "etcdctl snapshot status /opt/etcd-backup.db — must show hash, revision, total keys",
    },
    {
        "id": "03", "name": "NetworkPolicy",
        "desc": "Restrict ingress to the backend pod: frontend-only, port 80.",
        "scenario": "Two pods are running in namespace <b>netpol-lab</b>: <code>frontend</code> (label <code>app=frontend</code>) and <code>backend</code> (label <code>app=backend</code>). Currently there are no network restrictions.",
        "objective": "Create a <b>NetworkPolicy</b> named <code>allow-frontend-to-backend</code> in namespace <b>netpol-lab</b> that allows ingress to <code>backend</code> only from pods with label <code>app=frontend</code>, and only on <b>port 80</b>. All other ingress to backend must be denied.",
        "hints": [
            "Check pods and labels: <code>kubectl get pods -n netpol-lab --show-labels</code>",
            "<code>spec.podSelector</code> targets <code>app=backend</code>; the ingress rule needs a <code>podSelector</code> for <code>app=frontend</code> plus <code>ports: [port: 80]</code>",
            "Once a pod is selected by a NetworkPolicy, any ingress not explicitly allowed is denied",
        ],
        "verify": "NetworkPolicy allow-frontend-to-backend targets app=backend and contains a port-80 rule",
    },
    {
        "id": "04", "name": "PV & PVC",
        "desc": "Create a PersistentVolume, claim it, and mount it in a Pod.",
        "scenario": "Namespace <b>storage-lab</b> needs a statically provisioned volume backed by the node's local filesystem.",
        "objective": "Create: (1) a <b>PersistentVolume</b> named <code>task-pv</code> — <code>storageClassName: manual</code>, hostPath <code>/mnt/task-data</code>, capacity <b>1Gi</b>, accessMode <b>ReadWriteOnce</b>. (2) a <b>PersistentVolumeClaim</b> named <code>task-pvc</code> in <b>storage-lab</b> — <code>storageClassName: manual</code>, requesting <b>1Gi</b> RWO. (3) a <b>Pod</b> named <code>task-pod</code> using image <code>nginx:stable</code> that mounts the PVC at <code>/usr/share/nginx/html</code>.",
        "hints": [
            "Matching <code>storageClassName: manual</code> on both PV and PVC gives a static bind",
            "PV hostPath type: <code>DirectoryOrCreate</code> to auto-create the dir",
            "Verify binding: <code>kubectl get pv; kubectl get pvc -n storage-lab</code> — both should show <code>Bound</code>",
        ],
        "verify": "PVC task-pvc Bound; pod task-pod Running and mounting task-pvc",
    },
    {
        "id": "05", "name": "RBAC",
        "desc": "Create a ServiceAccount with read-only access to pods cluster-wide.",
        "scenario": "A new monitoring component needs to list and get pods across all namespaces, but must have no other permissions.",
        "objective": "(1) create <b>ServiceAccount</b> <code>pod-reader-sa</code> in namespace <b>rbac-lab</b>. (2) create <b>ClusterRole</b> <code>pod-reader</code> allowing <code>get</code>, <code>list</code>, <code>watch</code> on <code>pods</code>. (3) create <b>ClusterRoleBinding</b> <code>pod-reader-binding</code> that binds the role to the ServiceAccount.",
        "hints": [
            "Quick SA create: <code>kubectl create serviceaccount pod-reader-sa -n rbac-lab</code>",
            "Quick ClusterRole: <code>kubectl create clusterrole pod-reader --verb=get,list,watch --resource=pods</code>",
            "Quick binding: <code>kubectl create clusterrolebinding pod-reader-binding --clusterrole=pod-reader --serviceaccount=rbac-lab:pod-reader-sa</code>",
            "Test: <code>kubectl auth can-i list pods --as=system:serviceaccount:rbac-lab:pod-reader-sa</code>",
        ],
        "verify": "kubectl auth can-i list pods --as=system:serviceaccount:rbac-lab:pod-reader-sa → yes",
    },
    {
        "id": "06", "name": "Ingress",
        "desc": "Route HTTP traffic to two services via path-based Ingress rules.",
        "scenario": "Two Deployments with ClusterIP Services are deployed in namespace <b>ingress-lab</b>: <code>app1</code> and <code>app2</code> (both port 80). No ingress controller is installed — only the Ingress object is verified.",
        "objective": "Create an <b>Ingress</b> named <code>lab-ingress</code> in namespace <b>ingress-lab</b> that routes: <code>/app1</code> → <code>app1:80</code> and <code>/app2</code> → <code>app2:80</code>, using <code>pathType: Prefix</code>.",
        "hints": [
            "Check services: <code>kubectl get svc -n ingress-lab</code>",
            "No IngressClass is required (use default or omit)",
            "Scaffold it: <code>kubectl create ingress lab-ingress -n ingress-lab --rule=\"/app1*=app1:80\" --rule=\"/app2*=app2:80\" --dry-run=client -o yaml</code> (trailing <code>*</code> gives pathType Prefix)",
        ],
        "verify": "Ingress lab-ingress has /app1 → app1 and /app2 → app2 paths",
    },
    {
        "id": "07", "name": "Cluster Upgrade",
        "desc": "Upgrade the control-plane node one minor version (1.33 → 1.34).",
        "scenario": "The cluster is running <b>v1.33.x</b> (the prev image). Upgrade it one MINOR version to <b>1.34</b>, just like the CKA exam.",
        "objective": "Switch the apt repo to v1.34, then upgrade <b>cka-control</b> to the latest <b>1.34.x</b> using <code>kubeadm upgrade</code>. Then upgrade kubelet and kubectl on the control plane.",
        "hints": [
            "Switch repo (pkgs.k8s.io is one repo per minor): <code>sudo sed -i 's#/v1.33/#/v1.34/#' /etc/apt/sources.list.d/kubernetes.list</code> then refresh the keyring and <code>sudo apt-get update</code>",
            "Find available versions: <code>sudo apt-cache madison kubeadm | grep 1.34</code>",
            "Unhold, upgrade, rehold: <code>sudo apt-mark unhold kubeadm && sudo apt-get install -y --allow-change-held-packages kubeadm=1.34.X-1.1 && sudo apt-mark hold kubeadm</code>",
            "Plan: <code>sudo kubeadm upgrade plan</code>",
            "Apply: <code>sudo kubeadm upgrade apply v1.34.X</code>",
            "Upgrade kubelet: <code>sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y --allow-change-held-packages kubelet=1.34.X-1.1 kubectl=1.34.X-1.1</code> then <code>sudo systemctl daemon-reload && sudo systemctl restart kubelet</code>",
        ],
        "verify": "kubectl get nodes — cka-control shows v1.34.x",
    },
    {
        "id": "08", "name": "Drain Node",
        "desc": "Safely evict all workloads from a node and bring it back.",
        "scenario": "You need to perform maintenance on <b>cka-worker-02</b>: safely evict its workloads, then return the node to service.",
        "objective": "(1) <b>Drain</b> <code>cka-worker-02</code> — evict all pods, ignore DaemonSets. (2) Verify the node shows <code>SchedulingDisabled</code>. (3) <b>Uncordon</b> the node and verify it returns to <code>Ready</code>.",
        "hints": [
            "Drain: <code>kubectl drain cka-worker-02 --ignore-daemonsets --delete-emptydir-data --force</code>",
            "Node should show <code>Ready,SchedulingDisabled</code>: <code>kubectl get nodes</code>",
            "Uncordon: <code>kubectl uncordon cka-worker-02</code>",
        ],
        "verify": "kubectl get nodes — cka-worker-02 Ready (uncordoned)",
    },
    {
        "id": "09", "name": "Deployment",
        "desc": "Create a Deployment, expose it as a Service, then scale it.",
        "scenario": "A new web application must be deployed in namespace <b>workload-lab</b> and exposed internally.",
        "objective": "(1) Create namespace <b>workload-lab</b>. (2) Create <b>Deployment</b> <code>web</code>: image <code>nginx:1.25</code>, <b>3 replicas</b>. (3) Expose it as a <b>ClusterIP Service</b> named <code>web-svc</code> on port <b>80</b>. (4) <b>Scale</b> the Deployment to <b>5 replicas</b>.",
        "hints": [
            "Create ns: <code>kubectl create namespace workload-lab</code>",
            "Create: <code>kubectl create deployment web --image=nginx:1.25 --replicas=3 -n workload-lab</code>",
            "Expose: <code>kubectl expose deployment web --name=web-svc --port=80 --target-port=80 -n workload-lab</code>",
            "Scale: <code>kubectl scale deployment web --replicas=5 -n workload-lab</code>",
        ],
        "verify": "Deployment web READY 5/5 with image nginx:1.25; Service web-svc exists",
    },
    {
        "id": "10", "name": "Broken Pod",
        "desc": "Diagnose and fix a pod stuck in ImagePullBackOff.",
        "scenario": "A pod named <code>broken-pod</code> in namespace <b>troubleshoot-lab</b> is in <b>ImagePullBackOff</b> state — it references a non-existent image tag.",
        "objective": "Identify the incorrect image tag, fix it so the pod uses <code>nginx:stable</code>, and confirm the pod reaches <b>Running</b> state.",
        "hints": [
            "Inspect: <code>kubectl describe pod broken-pod -n troubleshoot-lab</code> — look at Events and Image",
            "Events: <code>kubectl get events -n troubleshoot-lab</code>",
            "Fix image: <code>kubectl set image pod/broken-pod app=nginx:stable -n troubleshoot-lab</code> (container name is <code>app</code>), or delete and recreate the pod",
            "Watch: <code>kubectl get pod broken-pod -n troubleshoot-lab -w</code>",
        ],
        "verify": "kubectl get pod broken-pod -n troubleshoot-lab — STATUS=Running",
    },
]

# ---------------------------------------------------------------------------
# Job state  (single job at a time)
# ---------------------------------------------------------------------------
_lock        = threading.Lock()
_running     = False
_job_name    = ""
_output: list[dict] = []   # {"type": "step"|"line"|"error"|"done", "text": "..."}


def _emit(msg: dict):
    _output.append(msg)


def start_job(name: str, steps: list[tuple]) -> tuple[bool, str]:
    """steps = [(label, cmd_list, env_dict), ...]"""
    global _running, _job_name, _output
    with _lock:
        if _running:
            return False, "A job is already running"
        _running  = True
        _job_name = name
        _output   = []

    def _worker():
        global _running
        success = True
        try:
            for label, cmd, extra_env in steps:
                _emit({"type": "step", "text": f"\n{'━'*52}\n  {label}\n{'━'*52}\n"})
                env = os.environ.copy()
                env.update(extra_env)
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, cwd=SCRIPT_DIR, env=env, bufsize=1
                )
                for line in proc.stdout:
                    _emit({"type": "line", "text": line})
                proc.wait()
                if proc.returncode != 0:
                    _emit({"type": "error",
                           "text": f"\n✖  Command failed (exit {proc.returncode})\n"})
                    success = False
                    break
            _emit({"type": "done", "success": success,
                   "text": "\n✔  Done\n" if success else "\n✖  Job finished with errors\n"})
        except Exception as exc:
            _emit({"type": "error", "text": f"\n✖  Exception: {exc}\n"})
            _emit({"type": "done", "success": False, "text": ""})
        finally:
            _running = False

    threading.Thread(target=_worker, daemon=True).start()
    return True, "started"


# ---------------------------------------------------------------------------
# Cluster state helpers
# ---------------------------------------------------------------------------
def _run(cmd, timeout=6) -> str:
    return subprocess.check_output(cmd, text=True, timeout=timeout,
                                   stderr=subprocess.DEVNULL)


VIRSH = ["virsh", "--connect", "qemu:///system"]


def vm_states() -> list[dict]:
    try:
        raw = _run(VIRSH + ["list", "--all"])
    except Exception:
        return [{"name": n, "state": "unknown"} for n in
                ["cka-control", "cka-worker-01", "cka-worker-02"]]
    result = []
    for name in ["cka-control", "cka-worker-01", "cka-worker-02"]:
        state = "absent"
        for line in raw.splitlines():
            if name in line:
                state = "running" if "running" in line else "off" if "shut off" in line else "other"
                break
        result.append({"name": name, "state": state})
    return result


def network_active() -> bool:
    try:
        out = _run(VIRSH + ["net-list"])
        return "cka-lab" in out and "active" in out
    except Exception:
        return False


def k8s_state() -> dict | None:
    try:
        nodes_raw = _run(SSH_BASE + [f"ubuntu@{CONTROL_IP}",
                                     "kubectl get nodes --no-headers"])
        nodes = []
        for line in nodes_raw.strip().splitlines():
            p = line.split()
            if len(p) >= 5:
                nodes.append({"name": p[0], "status": p[1],
                               "role": p[2], "version": p[4]})
    except Exception:
        return None

    try:
        pods_raw = _run(SSH_BASE + [f"ubuntu@{CONTROL_IP}",
                                    "kubectl get pods -A --no-headers"], timeout=10)
        lines = [l for l in pods_raw.strip().splitlines() if l]
        total     = len(lines)
        not_ready = sum(1 for l in lines
                        if not any(s in l for s in ("Running", "Completed")))
    except Exception:
        total = not_ready = 0

    return {"nodes": nodes, "pods_total": total, "pods_not_ready": not_ready}


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------
app = Flask(__name__)


@app.route("/")
def index():
    return render_template_string(HTML)


@app.route("/api/status")
def api_status():
    vms = vm_states()
    control_up = any(v["name"] == "cka-control" and v["state"] == "running"
                     for v in vms)
    return jsonify({
        "vms":     vms,
        "network": network_active(),
        "k8s":     k8s_state() if control_up else None,
        "images":  {"k8s":      os.path.exists(K8S_IMAGE),
                    "k8s_prev": os.path.exists(K8S_PREV_IMAGE),
                    "base":     os.path.exists(BASE_IMAGE)},
        "job":     {"running": _running, "name": _job_name},
        "tasks":   TASKS,
    })


@app.route("/api/job")
def api_job():
    since = int(request.args.get("since", 0))
    return jsonify({
        "running": _running,
        "name":    _job_name,
        "lines":   _output[since:],
        "total":   len(_output),
    })


@app.route("/api/provision", methods=["POST"])
def api_provision():
    data  = request.get_json(silent=True) or {}
    image = data.get("image", "k8s")   # "k8s" or "base"

    if image == "base":
        vm_env = {"USE_BASE_IMAGE": "1"}
    elif image == "k8s-prev":
        vm_env = {"USE_K8S_PREV_IMAGE": "1"}
    else:
        vm_env = {}
    job_name = f"New cluster ({image} image)"

    steps = [
        ("Destroying existing cluster",  ["bash", "teardown.sh"],       {"YES": "1"}),
        ("Setting up network",           ["bash", "01-network.sh"],      {}),
        ("Generating cloud-init seeds",  ["bash", "02-cloud-init.sh"],   {}),
        ("Provisioning VMs",             ["bash", "03-vms.sh"],          vm_env),
        ("Installing Kubernetes",        ["bash", "04-kubernetes.sh"],   {}),
    ]
    ok, msg = start_job(job_name, steps)
    return (jsonify({"status": "started"}) if ok
            else (jsonify({"error": msg}), 409))


@app.route("/api/destroy", methods=["POST"])
def api_destroy():
    ok, msg = start_job("Destroy cluster",
                        [("Destroying cluster", ["bash", "teardown.sh"], {"YES": "1"})])
    return (jsonify({"status": "started"}) if ok
            else (jsonify({"error": msg}), 409))


@app.route("/api/task/<task_id>", methods=["POST"])
def api_task(task_id):
    matches = glob.glob(os.path.join(SCRIPT_DIR, f"lab-tasks/task-{task_id}*.sh"))
    if not matches:
        return jsonify({"error": f"Task {task_id} not found"}), 404
    script   = os.path.basename(matches[0])
    task_obj = next((t for t in TASKS if t["id"] == task_id), {"name": task_id})
    name     = f"Task {task_id}: {task_obj['name']}"
    ok, msg  = start_job(name,
                         [(f"Deploying {name}", ["bash", f"lab-tasks/{script}"], {})])
    return (jsonify({"status": "started"}) if ok
            else (jsonify({"error": msg}), 409))


# ---------------------------------------------------------------------------
# HTML  (single-page, no build step)
# ---------------------------------------------------------------------------
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CKA Lab</title>
<style>
  :root {
    --bg:       #0d1117;
    --surface:  #161b22;
    --card:     #1c2128;
    --border:   #30363d;
    --text:     #e6edf3;
    --muted:    #8b949e;
    --green:    #3fb950;
    --yellow:   #d29922;
    --red:      #f85149;
    --blue:     #58a6ff;
    --purple:   #bc8cff;
    --orange:   #ffa657;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  .hidden { display: none !important; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; font-size: 14px; min-height: 100vh; }

  /* ── Layout ── */
  header { background: var(--surface); border-bottom: 1px solid var(--border); padding: 12px 24px; display: flex; align-items: center; gap: 16px; position: sticky; top: 0; z-index: 10; }
  header h1 { font-size: 16px; font-weight: 600; letter-spacing: .5px; }
  header .sep { flex: 1; }
  .main { display: grid; grid-template-columns: 280px 1fr; gap: 20px; padding: 20px 24px; }

  /* ── Cards ── */
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
  .card-title { font-size: 11px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase; color: var(--muted); margin-bottom: 12px; }

  /* ── Status dots ── */
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; flex-shrink: 0; }
  .dot.green  { background: var(--green); box-shadow: 0 0 6px var(--green); }
  .dot.yellow { background: var(--yellow); }
  .dot.red    { background: var(--red); }
  .dot.gray   { background: var(--muted); }

  /* ── VM list ── */
  .vm-item { display: flex; align-items: center; padding: 6px 0; border-bottom: 1px solid var(--border); }
  .vm-item:last-child { border-bottom: none; }
  .vm-name { flex: 1; font-family: monospace; font-size: 13px; }
  .vm-state { font-size: 11px; color: var(--muted); }

  /* ── K8s nodes ── */
  .node-row { display: flex; align-items: center; gap: 8px; padding: 5px 0; font-family: monospace; font-size: 12px; border-bottom: 1px solid var(--border); }
  .node-row:last-child { border-bottom: none; }
  .node-name { flex: 1; }
  .badge { font-size: 10px; padding: 1px 6px; border-radius: 10px; background: var(--border); color: var(--muted); }
  .badge.cp  { background: #1f2d47; color: var(--blue); }
  .badge.ver { background: #1a2333; color: var(--purple); }

  /* ── Pods summary ── */
  .pods-line { margin-top: 10px; font-size: 12px; color: var(--muted); }
  .pods-line span { color: var(--green); }
  .pods-line span.warn { color: var(--yellow); }

  /* ── Actions ── */
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  button { cursor: pointer; border: none; border-radius: 6px; padding: 8px 16px; font-size: 13px; font-weight: 500; transition: opacity .15s, filter .15s; }
  button:hover:not(:disabled) { filter: brightness(1.15); }
  button:disabled { opacity: .4; cursor: not-allowed; }
  .btn-primary { background: var(--blue);   color: #0d1117; }
  .btn-success { background: var(--green);  color: #0d1117; }
  .btn-danger  { background: var(--red);    color: #fff; }
  .btn-ghost   { background: var(--border); color: var(--text); }

  /* ── Image picker ── */
  .image-select { background: var(--surface); border: 1px solid var(--border); color: var(--text); border-radius: 6px; padding: 7px 10px; font-size: 13px; }
  .image-select option { background: var(--surface); }

  /* ── Tasks grid ── */
  .tasks-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }
  .task-card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 14px; cursor: pointer; transition: border-color .15s, background .15s; display: flex; flex-direction: column; gap: 6px; }
  .task-card:hover:not(.disabled) { border-color: var(--blue); background: #1c2a3a; }
  .task-card.disabled { opacity: .4; cursor: not-allowed; }
  .task-card.active   { border-color: var(--orange); background: #1f1f0d; }
  .task-num  { font-size: 10px; font-weight: 700; letter-spacing: 1px; color: var(--muted); text-transform: uppercase; }
  .task-name { font-size: 13px; font-weight: 600; }
  .task-desc { font-size: 11px; color: var(--muted); line-height: 1.4; }

  /* ── Job bar ── */
  .job-bar { background: var(--surface); border-top: 1px solid var(--border); position: fixed; bottom: 0; left: 0; right: 0; z-index: 20; max-height: 320px; display: flex; flex-direction: column; transition: max-height .3s ease; }
  .job-bar.collapsed { max-height: 42px; }
  .job-header { display: flex; align-items: center; gap: 10px; padding: 10px 16px; cursor: pointer; border-bottom: 1px solid var(--border); flex-shrink: 0; }
  .job-header .job-title { flex: 1; font-size: 13px; font-weight: 500; }
  .spinner { width: 14px; height: 14px; border: 2px solid var(--border); border-top-color: var(--blue); border-radius: 50%; animation: spin .8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .job-log { flex: 1; overflow-y: auto; padding: 10px 16px; font-family: "SF Mono", "Fira Code", monospace; font-size: 12px; line-height: 1.6; background: var(--bg); white-space: pre-wrap; word-break: break-all; }
  .log-step  { color: var(--blue); font-weight: 600; }
  .log-line  { color: #adbac7; }
  .log-ok    { color: var(--green); }
  .log-warn  { color: var(--yellow); }
  .log-error { color: var(--red); font-weight: 600; }
  .log-done-ok  { color: var(--green); font-weight: 600; }
  .log-done-err { color: var(--red);   font-weight: 600; }

  /* ── Header pills ── */
  .pill { font-size: 11px; padding: 3px 10px; border-radius: 10px; font-weight: 500; }
  .pill.green  { background: #0d2619; color: var(--green); border: 1px solid #1a4728; }
  .pill.yellow { background: #201a00; color: var(--yellow); border: 1px solid #3d3300; }
  .pill.red    { background: #2d0b0b; color: var(--red);    border: 1px solid #5a1515; }
  .pill.gray   { background: var(--border); color: var(--muted); border: 1px solid transparent; }

  /* body padding for fixed bottom bar */
  body { padding-bottom: 50px; }
  body.job-open { padding-bottom: 330px; }

  /* ── Confirm overlay ── */
  .overlay { position: fixed; inset: 0; background: rgba(0,0,0,.6); z-index: 30; display: flex; align-items: center; justify-content: center; }
  .overlay.hidden { display: none; }
  .dialog { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 24px; max-width: 380px; width: 90%; }
  .dialog h2 { font-size: 15px; margin-bottom: 8px; }
  .dialog p  { color: var(--muted); font-size: 13px; margin-bottom: 20px; line-height: 1.5; }
  .dialog .btns { display: flex; gap: 10px; justify-content: flex-end; }

  /* ── Task detail modal ── */
  .task-modal { background: var(--card); border: 1px solid var(--border); border-radius: 12px; width: min(680px, 95vw); max-height: 85vh; display: flex; flex-direction: column; overflow: hidden; }
  .task-modal-header { padding: 20px 24px 16px; border-bottom: 1px solid var(--border); flex-shrink: 0; }
  .task-modal-header .task-num { font-size: 11px; font-weight: 700; letter-spacing: 1px; color: var(--muted); text-transform: uppercase; margin-bottom: 4px; }
  .task-modal-header h2 { font-size: 18px; font-weight: 600; }
  .task-modal-header p  { color: var(--muted); font-size: 13px; margin-top: 4px; }
  .task-modal-body { overflow-y: auto; padding: 20px 24px; display: flex; flex-direction: column; gap: 20px; }
  .task-section-title { font-size: 11px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase; color: var(--muted); margin-bottom: 8px; }
  .task-scenario { background: var(--surface); border-left: 3px solid var(--blue); border-radius: 0 6px 6px 0; padding: 12px 14px; font-size: 13px; line-height: 1.6; }
  .task-objective { background: var(--surface); border-left: 3px solid var(--green); border-radius: 0 6px 6px 0; padding: 12px 14px; font-size: 13px; line-height: 1.6; }
  .task-verify { background: var(--surface); border-left: 3px solid var(--purple); border-radius: 0 6px 6px 0; padding: 12px 14px; font-size: 13px; font-family: monospace; color: var(--purple); }
  .hints-list { display: flex; flex-direction: column; gap: 6px; }
  .hint-item { display: flex; gap: 10px; align-items: flex-start; font-size: 13px; line-height: 1.5; }
  .hint-item::before { content: "›"; color: var(--orange); font-weight: 700; flex-shrink: 0; margin-top: 1px; }
  .hint-item code, code { background: #0d1117; border: 1px solid var(--border); border-radius: 4px; padding: 1px 5px; font-family: "SF Mono","Fira Code",monospace; font-size: 12px; color: var(--orange); white-space: pre-wrap; word-break: break-all; }
  .task-modal-footer { padding: 16px 24px; border-top: 1px solid var(--border); display: flex; gap: 10px; justify-content: flex-end; flex-shrink: 0; }
  .no-cluster-warn { background: #201400; border: 1px solid #3d2800; border-radius: 6px; padding: 10px 14px; font-size: 12px; color: var(--yellow); }

  section h2 { font-size: 13px; font-weight: 600; color: var(--muted); margin-bottom: 12px; letter-spacing: .5px; }
</style>
</head>
<body>

<!-- Confirm dialog -->
<div class="overlay hidden" id="confirm-overlay">
  <div class="dialog">
    <h2 id="confirm-title">Are you sure?</h2>
    <p  id="confirm-body"></p>
    <div class="btns">
      <button class="btn-ghost" onclick="closeConfirm()">Cancel</button>
      <button class="btn-danger" id="confirm-ok">Confirm</button>
    </div>
  </div>
</div>

<!-- Task detail modal -->
<div class="overlay hidden" id="task-overlay" onclick="closeTask(event)">
  <div class="task-modal" onclick="event.stopPropagation()">
    <div class="task-modal-header">
      <div class="task-num" id="tm-num"></div>
      <h2 id="tm-name"></h2>
      <p  id="tm-desc"></p>
    </div>
    <div class="task-modal-body">
      <div id="tm-no-cluster" class="no-cluster-warn hidden">
        ⚠ No cluster is running. Start a cluster first, then deploy this task.
      </div>
      <div>
        <div class="task-section-title">Scenario</div>
        <div class="task-scenario" id="tm-scenario"></div>
      </div>
      <div>
        <div class="task-section-title">Objective</div>
        <div class="task-objective" id="tm-objective"></div>
      </div>
      <div id="tm-hints-section">
        <div class="task-section-title">Hints</div>
        <div class="hints-list" id="tm-hints"></div>
      </div>
      <div>
        <div class="task-section-title">Acceptance criteria</div>
        <div class="task-verify" id="tm-verify"></div>
      </div>
    </div>
    <div class="task-modal-footer">
      <button class="btn-ghost" onclick="closeTask()">Close</button>
      <button class="btn-primary" id="tm-deploy-btn" onclick="deployFromModal()">Deploy Task</button>
    </div>
  </div>
</div>

<!-- Header -->
<header>
  <h1>⎈ CKA Lab</h1>
  <div id="header-pills" style="display:flex;gap:8px;align-items:center;"></div>
  <div class="sep"></div>
  <div id="job-indicator" style="display:none;align-items:center;gap:8px;font-size:12px;color:var(--muted);">
    <div class="spinner"></div>
    <span id="job-indicator-name"></span>
  </div>
</header>

<!-- Main layout -->
<div class="main">

  <!-- Left: cluster state -->
  <div style="display:flex;flex-direction:column;gap:16px;">

    <!-- Actions -->
    <div class="card">
      <div class="card-title">Actions</div>
      <div style="display:flex;flex-direction:column;gap:10px;">
        <div class="actions">
          <select class="image-select" id="image-select">
            <option value="k8s">k8s latest</option>
            <option value="k8s-prev">k8s prev (upgrade practice)</option>
            <option value="base">base (clean Ubuntu)</option>
          </select>
          <button class="btn-success" id="btn-provision" onclick="doProvision()">New Cluster</button>
        </div>
        <div class="actions">
          <button class="btn-danger" id="btn-destroy" onclick="askDestroy()">Destroy</button>
        </div>
      </div>
    </div>

    <!-- VMs -->
    <div class="card">
      <div class="card-title">Virtual Machines</div>
      <div id="vm-list">Loading…</div>
    </div>

    <!-- K8s -->
    <div class="card" id="k8s-card">
      <div class="card-title">Kubernetes</div>
      <div id="k8s-info" style="color:var(--muted);font-size:12px;">Not running</div>
    </div>

    <!-- Images -->
    <div class="card">
      <div class="card-title">Base Images</div>
      <div id="images-info"></div>
    </div>

  </div>

  <!-- Right: tasks -->
  <div>
    <section>
      <h2>LAB TASKS</h2>
      <div class="tasks-grid" id="tasks-grid">Loading…</div>
    </section>
  </div>
</div>

<!-- Job bar -->
<div class="job-bar collapsed" id="job-bar">
  <div class="job-header" onclick="toggleLog()">
    <div id="job-bar-icon" style="color:var(--muted);">▸</div>
    <div class="job-title" id="job-bar-title">No active job</div>
    <div style="font-size:11px;color:var(--muted);" id="job-bar-hint">Click to expand</div>
  </div>
  <div class="job-log" id="job-log"></div>
</div>

<script>
// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let status = {};
let allTasks = {};   // id → task object, populated on first status poll
let logSince = 0;
let logExpanded = false;
let confirmCb = null;

// ---------------------------------------------------------------------------
// Confirm dialog
// ---------------------------------------------------------------------------
function askConfirm(title, body, cb) {
  document.getElementById("confirm-title").textContent = title;
  document.getElementById("confirm-body").textContent  = body;
  document.getElementById("confirm-ok").onclick = () => { closeConfirm(); cb(); };
  document.getElementById("confirm-overlay").classList.remove("hidden");
}
function closeConfirm() {
  document.getElementById("confirm-overlay").classList.add("hidden");
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
function doProvision() {
  const image = document.getElementById("image-select").value;
  const label = image === "k8s"      ? "k8s latest image (~5 min)"
              : image === "k8s-prev" ? "k8s prev image (~5 min, upgrade to latest after init)"
              :                        "base image (~20 min — k8s packages install after clone)";
  askConfirm(
    "Create new cluster?",
    `This will destroy the current cluster and provision a fresh one using the ${label}. Any running tasks will be lost.`,
    () => post("/api/provision", { image })
  );
}

function askDestroy() {
  askConfirm(
    "Destroy cluster?",
    "This will destroy all 3 VMs and the cka-lab network. Base images are NOT removed.",
    () => post("/api/destroy", {})
  );
}

// ---------------------------------------------------------------------------
// Task detail modal
// ---------------------------------------------------------------------------
let _activeTask = null;

function openTask(taskId, clusterReady) {
  const task = allTasks[taskId];
  if (!task) return;
  _activeTask = task;
  document.getElementById("tm-num").textContent      = `Task ${task.id}`;
  document.getElementById("tm-name").textContent     = task.name;
  document.getElementById("tm-desc").textContent     = task.desc;
  document.getElementById("tm-scenario").innerHTML   = task.scenario  || "";
  document.getElementById("tm-objective").innerHTML  = task.objective || "";
  document.getElementById("tm-verify").textContent   = task.verify    || "";

  const hints = task.hints || [];
  const hintsSection = document.getElementById("tm-hints-section");
  if (hints.length) {
    document.getElementById("tm-hints").innerHTML =
      hints.map(h => `<div class="hint-item"><span>${h}</span></div>`).join("");
    hintsSection.style.display = "";
  } else {
    hintsSection.style.display = "none";
  }

  const warn = document.getElementById("tm-no-cluster");
  if (!clusterReady) {
    warn.classList.remove("hidden");
  } else {
    warn.classList.add("hidden");
  }

  document.getElementById("task-overlay").classList.remove("hidden");
}

function closeTask(e) {
  if (e && e.target !== document.getElementById("task-overlay")) return;
  document.getElementById("task-overlay").classList.add("hidden");
  _activeTask = null;
}

function deployFromModal() {
  if (!_activeTask) return;
  if (!status.k8s) {
    alert("No cluster is running. Provision a cluster first.");
    return;
  }
  const id = _activeTask.id;
  closeTask();
  post(`/api/task/${id}`, {});
}

async function post(url, body) {
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(body)
    });
    const d = await r.json();
    if (d.error) showError(d.error);
    else {
      logSince = 0;
      document.getElementById("job-log").textContent = "";
      expandLog();
      pollStatus();
      pollLog();
    }
  } catch (e) { showError(String(e)); }
}

function showError(msg) {
  alert("Error: " + msg);
}

// ---------------------------------------------------------------------------
// Log panel
// ---------------------------------------------------------------------------
function toggleLog() {
  if (logExpanded) collapseLog(); else expandLog();
}
function expandLog() {
  logExpanded = true;
  document.getElementById("job-bar").classList.remove("collapsed");
  document.getElementById("job-bar-icon").textContent = "▾";
  document.body.classList.add("job-open");
}
function collapseLog() {
  logExpanded = false;
  document.getElementById("job-bar").classList.add("collapsed");
  document.getElementById("job-bar-icon").textContent = "▸";
  document.body.classList.remove("job-open");
}

function appendLog(lines) {
  const el  = document.getElementById("job-log");
  const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  lines.forEach(item => {
    const span = document.createElement("span");
    const t = item.text || "";
    if (item.type === "step") {
      span.className = "log-step"; span.textContent = t;
    } else if (item.type === "error") {
      span.className = "log-error"; span.textContent = t;
    } else if (item.type === "done") {
      span.className = item.success ? "log-done-ok" : "log-done-err";
      span.textContent = t;
    } else {
      // color-code common patterns
      const cls = t.match(/\[OK\]/)     ? "log-ok"
                : t.match(/\[WARN\]/)   ? "log-warn"
                : t.match(/\[ERROR\]/)  ? "log-error"
                : "log-line";
      span.className = cls; span.textContent = t;
    }
    el.appendChild(span);
  });
  if (atBottom) el.scrollTop = el.scrollHeight;
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------
async function pollLog() {
  try {
    const r = await fetch(`/api/job?since=${logSince}`);
    const d = await r.json();
    if (d.lines.length) appendLog(d.lines);
    logSince = d.total;
    if (d.running) setTimeout(pollLog, 600);
    else {
      // update UI one more time after job ends
      setTimeout(pollStatus, 800);
      document.getElementById("job-bar-hint").textContent = "Done — click to toggle";
    }
  } catch (e) {
    setTimeout(pollLog, 2000);
  }
}

async function pollStatus() {
  try {
    const r = await fetch("/api/status");
    status = await r.json();
    renderStatus();
    if (status.job && status.job.running) {
      setTimeout(pollStatus, 3000);
    } else {
      setTimeout(pollStatus, 5000);
    }
  } catch (e) {
    setTimeout(pollStatus, 5000);
  }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
function stateColor(s) {
  return s === "running" ? "green" : s === "off" ? "yellow" : "gray";
}

function renderStatus() {
  const jobRunning = status.job && status.job.running;

  // Header job indicator
  const ind = document.getElementById("job-indicator");
  if (jobRunning) {
    ind.style.display = "flex";
    document.getElementById("job-indicator-name").textContent = status.job.name;
    document.getElementById("job-bar-title").textContent = status.job.name;
  } else {
    ind.style.display = "none";
    if (!document.getElementById("job-bar-title").textContent.includes("Done")) {
      document.getElementById("job-bar-title").textContent = "Last job output";
    }
  }

  // Header pills
  const pills = document.getElementById("header-pills");
  if (status.vms) {
    const running = status.vms.filter(v => v.state === "running").length;
    const total   = status.vms.length;
    const vmColor = running === total ? "green" : running === 0 ? "gray" : "yellow";
    pills.innerHTML = `<span class="pill ${vmColor}">VMs ${running}/${total}</span>`;
    if (status.k8s) {
      const readyNodes = status.k8s.nodes.filter(n => n.status === "Ready").length;
      const nTotal     = status.k8s.nodes.length;
      const nColor     = readyNodes === nTotal ? "green" : readyNodes === 0 ? "red" : "yellow";
      pills.innerHTML += `<span class="pill ${nColor}">Nodes ${readyNodes}/${nTotal} Ready</span>`;
      if (status.k8s.pods_not_ready > 0) {
        pills.innerHTML += `<span class="pill yellow">⚠ ${status.k8s.pods_not_ready} pods pending</span>`;
      } else {
        pills.innerHTML += `<span class="pill green">Pods OK</span>`;
      }
    } else if (running > 0) {
      pills.innerHTML += `<span class="pill yellow">k8s not ready</span>`;
    }
  }

  // VMs
  const vmList = document.getElementById("vm-list");
  if (status.vms) {
    vmList.innerHTML = status.vms.map(v => `
      <div class="vm-item">
        <span class="dot ${stateColor(v.state)}"></span>
        <span class="vm-name">${v.name}</span>
        <span class="vm-state">${v.state}</span>
      </div>`).join("");
  }

  // K8s
  const k8sInfo = document.getElementById("k8s-info");
  if (status.k8s && status.k8s.nodes.length) {
    const nodes = status.k8s.nodes;
    k8sInfo.innerHTML = nodes.map(n => {
      const dot   = n.status === "Ready" ? "green" : "red";
      const badge = n.role.includes("control") ? `<span class="badge cp">control</span>` : "";
      return `<div class="node-row">
        <span class="dot ${dot}"></span>
        <span class="node-name">${n.name}</span>
        ${badge}
        <span class="badge ver">${n.version}</span>
      </div>`;
    }).join("");
    const pColor = status.k8s.pods_not_ready > 0 ? "warn" : "";
    k8sInfo.innerHTML += `<div class="pods-line">
      Pods: <span class="${pColor}">${status.k8s.pods_total - status.k8s.pods_not_ready}/${status.k8s.pods_total} running</span>
    </div>`;
  } else {
    k8sInfo.innerHTML = `<span style="color:var(--muted);font-size:12px;">Not running</span>`;
  }

  // Images
  const imagesEl = document.getElementById("images-info");
  if (status.images) {
    const img = status.images;
    const row = (dot, name, state, sub) =>
      `<div class="vm-item">
        <span class="dot ${dot}"></span>
        <span class="vm-name" style="font-size:12px;">${name}</span>
        <span class="vm-state" style="text-align:right;line-height:1.3;">${state}${sub ? `<br><span style="font-size:10px;color:var(--muted)">${sub}</span>` : ""}</span>
      </div>`;
    imagesEl.innerHTML =
      row(img.k8s      ? "green" : "gray", "cka-k8s.qcow2",      img.k8s      ? "ready" : "missing", "latest") +
      row(img.k8s_prev ? "green" : "gray", "cka-k8s-prev.qcow2", img.k8s_prev ? "ready" : "missing", "prev ver") +
      row(img.base     ? "green" : "gray", "cka-base.qcow2",      img.base     ? "ready" : "missing", "clean OS");

    const sel = document.getElementById("image-select");
    sel.options[0].disabled = !img.k8s;
    sel.options[1].disabled = !img.k8s_prev;
    sel.options[2].disabled = !img.base;
    if (sel.value === "k8s"      && !img.k8s)      sel.value = img.k8s_prev ? "k8s-prev" : "base";
    if (sel.value === "k8s-prev" && !img.k8s_prev) sel.value = img.k8s      ? "k8s"      : "base";
  }

  // Tasks
  const grid = document.getElementById("tasks-grid");
  if (status.tasks) {
    status.tasks.forEach(t => allTasks[t.id] = t);
    const disabled = jobRunning;
    grid.innerHTML = status.tasks.map(t => `
      <div class="task-card ${disabled ? "disabled" : ""}" data-task-id="${t.id}">
        <div class="task-num">Task ${t.id}</div>
        <div class="task-name">${t.name}</div>
        <div class="task-desc">${t.desc}</div>
      </div>`).join("");

    // read status.k8s live at click time so stale renders never lie
    grid.querySelectorAll(".task-card:not(.disabled)").forEach(el => {
      el.addEventListener("click", () => openTask(el.dataset.taskId, !!status.k8s));
    });
  }

  // Buttons
  document.getElementById("btn-provision").disabled = jobRunning;
  document.getElementById("btn-destroy").disabled   = jobRunning;
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
pollStatus();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=1922, debug=False, threaded=True)
