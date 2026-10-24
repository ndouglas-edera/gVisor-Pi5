# gVisor-Pi5
Getting gVisor running on my Raspberry Pi5

# Current Setup
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
