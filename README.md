# gVisor-Pi5
Getting gVisor running on my Raspberry Pi5

## Current Setup
My current working baseline is:
- Debian 13 on ARM64
- Kernel ```rpi-v8``` with 4 KiB pages
- Docker runtime ```runsc```
- Ubuntu 24.04 containers running successfully under gVisor

Check whether the Tailscale nodes are online <br/>
Lists the tailnet devices and their status.
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
  sh -c 'echo "gVisor OK"; uname -rm'
```

Check Docker’s ```default runtime```:
```
sudo docker info --format 'Default runtime: {{.DefaultRuntime}}'
```

Check the runtime configuration:
```
sudo cat /etc/docker/daemon.json
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

While that shell is open, use a **second SSH session** to run ```sudo docker ps``` and see it listed. Type ```exit``` to stop it.
