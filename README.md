# gVisor-Pi5
Getting gVisor running on my Raspberry Pi5

## Current Setup
My current working baseline is:
- Debian 13 on ```ARM64```
- The Docker runtime ```runsc```
- Kernel ```rpi-v8``` with **[4 KiB pages](https://forums.raspberrypi.com/viewtopic.php?t=393687)**
- Ubuntu 24.04 containers running successfully under gVisor

Check whether the Tailscale nodes are online <br/>
Listing the tailnet devices and their status.
```
tailscale status
```
Got a fixed IP for this device for Kubecon:
```
ssh nigeldouglas@100.115.36.12
```
Rename the Pi’s hostname to ```gvisor``` <br/>
(This never worked):
```
sudo hostnamectl set-hostname gvisor
```
This did work, however:
```
sudo hostnamectl set-hostname gvisor && \
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1 gvisor/' /etc/hosts && \
exec bash
```
Check the changes:
```
hostnamectl
hostname
cat /etc/hosts
```
Apparently, ```cloud-init``` manages ```/etc/hosts```, so it may regenerate the file later. <br/>
To ensure these changes persist, I ran the below:
```
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1 gvisor/' /etc/cloud/templates/hosts.debian.tmpl
```

<img width="1011" height="208" alt="Screenshot 2026-10-24 at 17 05 40" src="https://github.com/user-attachments/assets/a2500278-094c-490d-a797-9c0ebe025059" />

## How gVisor differs from Edera and Kata Containers

We have all been using Docker for over a decade as a way of compartmentalising web apps. <br/>
However, containers don't really contain - especially not for AI agents. 

The below article covers the terminology of Linux Kernel, Hypervisor, KVM, VMM, (µ)VMs, and more.<br/>
https://edera.dev/stories/why-xen-architecture-beats-kvm-for-agent-isolation-cve-2026-99999

<img width="1028" height="712" alt="gvisor" src="https://github.com/user-attachments/assets/d0e8c440-f194-4301-8aab-8d813c1f9696" />

<img width="1020" height="779" alt="gvisor2" src="https://github.com/user-attachments/assets/64f04277-0ef8-4611-bb01-9e0e771d9741" />

What’s different from the Kata version

- **The hypervisor moves under the host kernel** <br/>
KVM is a module inside the host Linux kernel, so in the original it lived in the yellow band.  <br/>
Xen is type-1: it boots first and sits directly on the hardware. <br/>
The host kernel becomes dom0, a privileged guest VM sitting beside the zones, not under them. <br/>
On Xen, the hypervisor owns all physical memory and hands it to domains as dom0 instructs, and neither dom0 nor the zones can touch memory that wasn’t explicitly granted to them.
- **No VMM with fake devices.**<br/>
Kata’s escape path ran through a VMM emulating hardware (the “fake devices” box). <br/>
Edera’s zones are paravirtualized: they talk to the hypervisor through hypercalls instead of executing privileged CPU instructions <br/>
I/O goes over shared-memory rings to backend drivers in dom0.
- **No nested virtualisation needed** <br/>
Edera was built not to require hardware virtualisation because it’s often unavailable across clouds and instance types.  <br/>
Where the CPU does support it, Xen offers PVH (PV with hardware assistance).
- **One zone per pod (not per container)** <br/>
In Kubernetes, Edera plugs in through RuntimeClass and isolates per pod.
- **Rust control plane** <br/>
Edera starts from Xen but rebuilds most of the components in Rust; Xen’s core is still the C hypervisor.
- **Backends can leave dom0** <br/>
Edera supports driver zones, which provide services to other zones, so the dom0 backend redbox can be moved into its own VM


One simplification to know about: in this diagram, the Docker and gVisor columns sit on a plain host Linux kernel, while the Edera column has Xen underneath. On a real Edera node, the whole machine boots under Xen with Linux as dom0. Also, Edera has a planned KVM backend; zones currently run on Xen, so the KVM version of this picture may become relevant later. 


## Check that gVisor is installed and working

Show the ```version``` of gVisor installed:
```
sudo runsc --version
```

Confirm Docker knows about the ```runsc``` runtime
```
sudo docker info --format '{{json .Runtimes}}' | python3 -m json.tool
```

Run a fresh ```Ubuntu 20.04``` test container under gVisor
```
sudo docker run --rm --runtime=runsc ubuntu:24.04 \
  sh -c 'echo "gVisor workload tested SUCCESSFULLY"; uname -rm'
```

Check Docker’s ```default runtime```:
```
sudo docker info --format 'Default runtime: {{.DefaultRuntime}}' | grep runc
```

Check the runtime config to make sure path set to ```/usr/bin/runsc```:
```
sudo cat /etc/docker/daemon.json | grep /usr/bin/runsc
```

## List running workloads
Running containers only
```
sudo docker ps
```
All containers, including stopped ones
```
sudo docker ps -a
```
Compact list of running containers
```
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}'
```
Live CPU and memory usage
```
sudo docker stats
```

If you want to see which runtime a particular container uses:
```
sudo docker inspect --format \
  'Name={{.Name}} Runtime={{.HostConfig.Runtime}} Status={{.State.Status}}' \
  CONTAINER_NAME
```

Replace ```CONTAINER_NAME``` with a name from ```docker ps```.<br/> 
A container created with ```--runtime=runsc``` should show ```Runtime=runsc```.
<br/><br/>
For a quick interactive workload to practise with:
```
sudo docker run --rm -it --runtime=runsc \
  --name gvisor-shell ubuntu:24.04 bash
```
Confirm that the container is running on a different kernel to the host:
```
uname -r
```
- Docker: ```4.19.0-gvisor```
- RPI5: ```6.18.50+rpt-rpi-v8```

While that shell is open, use a **second SSH session** to run ```sudo docker ps``` and see it listed. Type ```exit``` to stop it.

## Demonstrate gVisor Isolation
These checks demonstrate that the container is running under gVisor and has a separate process view. <br/>
They are useful sanity checks, not a complete proof that every security boundary is unbreakable.
<br/><br/>
Comparing the ```host``` kernel
```
uname -r
```
and the ```container``` kernel reported by gVisor:
```
sudo docker run --rm --runtime=runsc ubuntu:24.04 uname -r
```

You should see different results:
- **Host**: ```6.18.50+rpt-rpi-v8```
- **Container**: ```4.19.0-gvisor```

The container sees gVisor’s implemented Linux-compatible kernel interface rather than simply reporting the host kernel version.

### Compare process views
On the host, check the process count:
```
ps -e --no-headers | wc -l
```

Inside a fresh gVisor container, check ```PID 1``` and the container process list:
```
sudo docker run --rm --runtime=runsc ubuntu:24.04 sh -c '
  cat /proc/1/comm
  ps -ef
'
```
The container should have its own container-scoped process view. <br/>
Exact process counts will vary, and process isolation is also provided by Docker’s namespaces.

### Inspect security-related process settings
This reports process security fields exposed inside the container:
```
sudo docker run --rm --runtime=runsc ubuntu:24.04 sh -c '
  grep -E "^(Name|Pid|PPid|NoNewPrivs|Seccomp):" /proc/self/status
'
```

The ```Seccomp: 2``` field, if shown, means seccomp filtering is active for that process. <br/>
It is a useful signal but does not, by itself, establish that all gVisor protections are active or correctly configured.
<br/><br/>
I should investigate ```NoNewPrivs: 0``` and ```Seccomp: 0``` if present. <br/>
The ```Seccomp: 0``` means that the process represented by ```/proc/self/status``` is not currently using seccomp filtering <br/>
This was reported by the ```procfs``` interface. It does not, by itself, prove that gVisor (```runsc```) is not providing isolation.<br/>
However, my output initially started with:
```
Name:   grep
Pid:    2
PPid:   1
```
The command runs ```sh -c```, which launches ```grep```. <br/>
Because grep reads ```/proc/self/status```, output describes ```grep``` process, not necessarily the shell or other processes in the container.

| Result | Interpretation |
| :---------------- | :---------------- |
| ```Seccomp: 0``` | No seccomp filter is reported for that process |
| ```Seccomp: 2``` | A seccomp filter is active for that process |
| ```NoNewPrivs: 0``` | The process ```no_new_privs``` flag **is not** set |
| ```NoNewPrivs: 1``` | The process ```no_new_privs``` flag **is** set |

Neither ```NoNewPrivs: 0``` nor ```Seccomp: 0``` alone proves that gVisor isolation is absent. <br/>
gVisor provides a userspace-kernel, and its security properties are not adequately measured by these 2 fields alone.
<br/><br/>
**One important caveat**: gVisor's sandboxing model differs from ordinary Docker containers using the standard Linux runtime.<br/>
Dont assume that a process inside gVisor must show ```Seccomp: 2``` for gVisor's isolation to be working correctly.

### Confirm the actual runtime of a long-running container
```
sudo docker run -d --runtime=runsc --name isolation-demo \
  ubuntu:24.04 sleep 600
```

Inspect its runtime:
```
sudo docker inspect --format \
  'Runtime={{.HostConfig.Runtime}} Status={{.State.Status}}' \
  isolation-demo
```

**Expected**: ```runtime=runsc Status=running```


Clean it up afterwards:
```
sudo docker rm -f isolation-demo
```

**Important distinction**: gVisor provides an additional **[userspace-kernel sandbox](https://agent-sandbox.sigs.k8s.io/docs/use-cases/gvisor-isolation/#:~:text=Linux%20kernel%20in%20userspace)**. <br/>
Docker ```namespaces```, ```capabilities```, ```mounts```, and ```network``` settings still matter. <br/>
These commands demonstrate the config and some isolation properties. They are not a substitute for a security assessment.

### Host OS and kernel
My expected key values are ```Debian 13```, ```aarch64```, and a page size of ```4096``` bytes.<br/> 
I keep the page size for compatibility with my current gVisor build, as it used to cause issues.
```
cat /etc/os-release
uname -a
uname -m
free -h
df -h /
getconf PAGE_SIZE
```

Docker version:
```
sudo docker version
```
gVisor version:
```
sudo runsc --version
```
Registered Docker runtimes
```
sudo docker info --format '{{json .Runtimes}}' | python3 -m json.tool
```
Docker service status check:
```
sudo systemctl is-active docker
```
Check the status of Tailscale:
```
sudo systemctl is-active tailscaled
```

### Identify the gVisor platform
gVisor is a **sandboxing runtime**, not a traditional hardware-backed VMM like KVM. <br/>
My installed runtime was previously reported as using the ```systrap``` platform.
```
sudo runsc --help 2>&1 | grep -i -A2 platform
```
To inspect the configured runtime and version together:
```
sudo runsc --version
sudo docker info --format 'Runtimes: {{json .Runtimes}}'
```
The runtime version tells you which gVisor release is installed. <br/>
The platform option tells you how gVisor implements its sandbox on the host.

## Running Kubernetes on the Pi5

I'm going to add **[containerd](https://gvisor.dev/docs/user_guide/containerd/quick_start/)** + **the gVisor containerd shim**, then let Kubernetes use ```containerd``` as its CRI runtime. <br/>
Kubernetes expects a CRI-compatible runtime, while Docker requires the extra ```cri-dockerd``` adapter. <br/>
gVisor explicitly supports ```ARM64``` and ```Linux 5.6+```, so my Pi & kernel combination is actually a very good fit.

| Component | MyPi5 | Kubernetes/gVisor |
| :-------- | :---- | :---------------- |
| CPU | ARM64 / Pi 5 | ✅ gVisor supports ARM64 |
| Kernel | 6.18.50 | ✅ comfortably meets gVisor's 5.6+ requirement |
| RAM | 8 GB | ✅ quite reasonable for a single-node lab |
| Storage | 29 GB, ~20 GB free | ⚠️ workable, but I'd eventually add bigger MicroSD |
| cgroup v2 | likely | ✅ preferred |
| Docker | ```29.9.2``` | Not ideal as Kubernetes runtime |
| gVisor | runsc 20261019 | ✅ excellent starting point |
| gVisor Docker runtime | **working** | proves ```runsc``` itself works |
| containerd | bundled with Docker, but not necessarily configured for CRI | main piece to add |

I should be aiming for this design:
```
Kubernetes
      │
    CRI
      │
 containerd
   │       │
 runc    runsc
          │
       gVisor
```
As this is much more preferable to the below (original) implementation with Docker alone:
```
Kubernetes
    │
cri-dockerd
    │
 Docker
    │
  runsc
```
I am trying to avoid adding an unnecessary compatibility layer with Docker. <br/>
Kubernetes removed its old direct Docker integration. Docker now needs ```cri-dockerd``` to satisfy CRI.<br/>
```containerd``` is clearly the cleaner route.

## Preflight Check script
Download the script:
```
curl -fsSL https://raw.githubusercontent.com/ndouglas-edera/gVisor-Pi5/refs/heads/main/k8s-gvisor-check.sh -o k8s-gvisor-check.sh
chmod +x k8s-gvisor-check.sh
```

Run the script and save the report as ```k8s-gvisor-report.txt```
```
sudo ./k8s-gvisor-check.sh 2>&1 | tee k8s-gvisor-report.txt
```

On my MacBook, I can move the files from the Pi5 to my local Desktop directory and check the file:
```
scp nigeldouglas@100.115.36.12:~/k8s-gvisor-report.txt ~/Desktop/
ls -lh ~/Desktop/k8s-gvisor-report.txt
```

## Installing CRIctl
I need ```critctl``` to debug Kubernetes nodes: <br/>
https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
```
CRICTL_VERSION=v1.37.0
curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-arm64.tar.gz"
sudo tar -C /usr/local/bin -xzf "crictl-${CRICTL_VERSION}-linux-arm64.tar.gz"
rm "crictl-${CRICTL_VERSION}-linux-arm64.tar.gz"
crictl --version
```

Error - ```Unimplemented desc = unknown service runtime.v1.RuntimeService```
```
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info
```
That means ```containerd``` was not currently serving the **CRI v1 RuntimeService** at the socket I was testing. <br/>
Kubernetes cannot use that endpoint successfully yet, so I cannot deploy Kubernetes or change the gVisor runtime configuration just yet.
<br/><br/>
Fixed the CRI issues:
```
sudo cp -a /etc/containerd/config.toml /etc/containerd/config.toml.bak &&
sudo sed -i 's/^[[:space:]]*disabled_plugins[[:space:]]*=[[:space:]]*\["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml &&
sudo containerd config dump >/dev/null &&
sudo systemctl restart containerd &&
sudo systemctl is-active containerd
```
Verify CRI is working
```
sudo ctr plugins ls | grep -i cri
```
Then test the CRI endpoint:
```
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info
```
gVisor shim found:
```
sudo runsc --version
sudo test -x /usr/bin/containerd-shim-runsc-v1 && echo "gVisor shim found" || echo "gVisor shim missing"
```

## gVisor on Kubernetes
Register the gVisor ```RuntimeClass```:
```
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
```

Tells Kubernetes to use ```runsc``` containerd runtime handler for Pods specifying ```runtimeClassName: gvisor```.<br/>
*It does not change the runtime used by other Pods.*
```
kubectl get runtimeclass gvisor
```

Launch a test Pod under gVisor
```
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-smoke
spec:
  runtimeClassName: gvisor
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Hello from the gVisor sandbox'; uname -a; sleep 3600"]
EOF
```

Verify the ```Sandbox```
```
kubectl get pod gvisor-smoke -o wide
kubectl get pod gvisor-smoke -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl logs gvisor-smoke
kubectl exec gvisor-smoke -- uname -a
```
If the pod does not start:
```
kubectl describe pod gvisor-smoke
sudo journalctl -u containerd -n 80 --no-pager
```

<br/><br/>
Instant shutdown of my Raspberry Pi sitting at home
```
sudo shutdown -h now
```
