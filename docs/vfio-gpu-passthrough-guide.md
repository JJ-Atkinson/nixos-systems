# VFIO GPU Passthrough Guide for NixOS

**System Configuration:**
- Motherboard: ASRock Z690 PG Velocita
- CPU: Intel Core i7-14700KF
- GPU: AMD Radeon RX 6700 XT (Navi 22) [1002:73df]
- Chipset: Intel Z690

---

## 1. VM Software Options for NixOS with VFIO Support

### Recommended: QEMU/KVM with libvirt

**Why this is the best choice:**
- Native to Linux with excellent performance
- Full VFIO support with mature implementation
- Comprehensive NixOS integration
- Active community and extensive documentation
- Already partially configured in your system

**Current state in your config:**
```nix
# /etc/nixos/modules/virtual-machines.nix
programs.virt-manager.enable = true;
users.groups.libvirtd.members = [ "jarrett" ];
virtualisation.libvirtd.enable = true;
virtualisation.spiceUSBRedirection.enable = true;
```

**Alternative options considered:**
- **Looking Glass** - Not a replacement but a complement (see section 6)
- **Xen** - More complex, less integrated with NixOS
- **VirtualBox** - Poor VFIO support, not recommended for GPU passthrough

---

## 2. USB Controller Identification and Topology

### Your USB Controllers

**Controller 1: Intel Alder Lake-S (00:14.0)**
- PCI ID: [8086:7ae0]
- Type: USB 3.2 Gen 2x2 XHCI
- Ports: Buses 1 & 2 (16 USB 2.0 ports + 9 USB 3.0 ports)
- **WARNING:** This is likely integrated with other chipset functions - may not be ideal for passthrough

**Controller 2: ASMedia ASM3042 (07:00.0)** ⭐ RECOMMENDED FOR PASSTHROUGH
- PCI ID: [1b21:3042]
- Type: USB 3.2 Gen 1 xHCI
- Ports: Buses 3 & 4 (2 ports each, USB 2.0 + USB 3.0)
- Location: PCIe slot (Root Port #1)
- **Advantages:**
  - Discrete controller on separate PCIe slot
  - Isolated from system-critical functions
  - Clean IOMMU grouping (expected)

### Current USB Device Distribution

**Bus 1 (Intel controller - USB 2.0):**
- Printer
- USB Hub with multiple HIDs (keyboard/mouse likely)
- Webcam (Video + Audio)
- Audio interface
- Bluetooth adapter

**Bus 2 (Intel controller - USB 3.0):**
- Two USB hubs

**Bus 3 & 4 (ASMedia controller):** ⭐
- Currently has one HID device (dual interface)
- **These ports should be used for VM-dedicated peripherals**

### Identifying Physical Ports

To map which physical ports belong to the ASMedia controller:

```bash
# Method 1: Trial and error
# Plug a USB device into each rear port and run:
lsusb -t

# Look for devices appearing under Bus 003 or Bus 004

# Method 2: Check while running
# Watch in real-time as you plug devices:
watch -n 0.5 'lsusb -t | grep -A 20 "Bus 003\|Bus 004"'
```

**Typical ASRock Z690 layout:**
- ASMedia ports are usually labeled differently (often red/blue) or marked as "VR Ready"
- Check your motherboard manual for exact locations

---

## 3. Motherboard BIOS Settings

### Required BIOS Settings for ASRock Z690 PG Velocita

**Access BIOS:** Press F2 or DEL during boot

#### Essential Settings:

1. **Enable Virtualization Technology**
   - Location: `Advanced → CPU Configuration`
   - Setting: `Intel Virtualization Technology` → **Enabled**
   - Setting: `Intel VT-d` → **Enabled**

2. **IOMMU Configuration** (Critical - currently DISABLED on your system)
   - Location: May be in `Advanced → Chipset Configuration` or `Advanced → North Bridge`
   - Setting: `VT-d` → **Enabled**
   - Some boards call this "IOMMU Support"

3. **Above 4G Decoding** (Important for large GPU memory)
   - Location: `Advanced → PCI Subsystem Settings` or `Advanced → PCIe Configuration`
   - Setting: `Above 4G Decoding` → **Enabled**
   - This allows the system to allocate PCIe resources above 4GB

4. **Resizable BAR** (Optional but recommended for AMD GPUs)
   - Location: `Advanced → PCI Subsystem Settings`
   - Setting: `Re-Size BAR Support` → **Enabled**
   - Note: May need to be disabled for passthrough depending on guest OS

5. **UEFI Boot Mode**
   - Location: `Boot → Boot Mode`
   - Setting: `UEFI` mode (not Legacy/CSM)
   - Your system is already UEFI (using systemd-boot)

6. **PCIe Link Speed** (Optional - for troubleshooting)
   - Location: `Advanced → PCIe Configuration`
   - Try: `Auto` first, if issues occur try forcing `Gen 3` or `Gen 4`

#### Optional but Helpful:

- **Disable CSM (Compatibility Support Module)**
  - Ensures pure UEFI operation

- **Enable SR-IOV** (if available)
  - Advanced feature for device virtualization

- **PCIe ACS Override** (if experiencing IOMMU grouping issues)
  - Not typically in BIOS, handled via kernel parameters

### After BIOS Changes

After enabling VT-d, verify IOMMU is working:

```bash
# Check kernel command line includes intel_iommu=on
cat /proc/cmdline

# Check IOMMU groups exist
ls /sys/kernel/iommu_groups/
```

---

## 4. VM Anti-Detection Strategies

Windows and some games/anti-cheat systems try to detect VMs. Here are strategies to hide virtualization:

### Level 1: Basic Hiding (KVM Features)

```nix
# In your VM configuration
virtualisation.libvirtd.qemu.verbatimConfig = ''
  user = "jarrett"
  group = "libvirtd"
'';
```

**In libvirt XML (via virt-manager or virsh edit):**

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>win11-gaming</name>

  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vpindex state='on'/>
      <runtime state='on'/>
      <synic state='on'/>
      <stimer state='on'/>
      <reset state='on'/>
      <!-- CRITICAL: Hide hypervisor presence -->
      <vendor_id state='on' value='1234567890ab'/>
      <frequencies state='on'/>
    </hyperv>
    <!-- Hide KVM signature -->
    <kvm>
      <hidden state='on'/>
    </kvm>
    <vmport state='off'/>
    <ioapic driver='kvm'/>
  </features>

  <cpu mode='host-passthrough' check='none' migratable='off'>
    <topology sockets='1' dies='1' cores='8' threads='2'/>
    <!-- Hide hypervisor CPUID leaves -->
    <feature policy='disable' name='hypervisor'/>
  </cpu>
</domain>
```

### Level 2: Hardware Spoofing

**QEMU arguments to add:**

```xml
<qemu:commandline>
  <!-- Spoof CPU model string -->
  <qemu:arg value='-cpu'/>
  <qemu:arg value='host,host-cache-info=on,kvm=off,hv_vendor_id=null,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time'/>

  <!-- Randomize/customize system info -->
  <qemu:arg value='-smbios'/>
  <qemu:arg value='type=0,vendor=American Megatrends Inc.,version=P1.50,date=04/15/2022'/>
  <qemu:arg value='-smbios'/>
  <qemu:arg value='type=1,manufacturer=ASRock,product=Z690 PG Velocita,version=1.0,serial=0123456789,uuid=random,sku=Default,family=Desktop'/>
  <qemu:arg value='-smbios'/>
  <qemu:arg value='type=2,manufacturer=ASRock,product=Z690 PG Velocita,version=1.0,serial=0123456789'/>
  <qemu:arg value='-smbios'/>
  <qemu:arg value='type=3,manufacturer=ASRock,version=1.0,serial=0123456789'/>
</qemu:commandline>
```

### Level 3: Device ID Spoofing

For AMD GPUs, you may want to patch the GPU BIOS or device IDs:

```bash
# Extract GPU VBIOS (from host before passing through)
cd /sys/bus/pci/devices/0000:03:00.0/
echo 1 > rom
cat rom > /etc/nixos/vbios/rx6700xt.rom
echo 0 > rom

# Use custom VBIOS in VM
```

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
  </source>
  <rom file='/etc/nixos/vbios/rx6700xt.rom'/>
  <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
</hostdev>
```

### Level 4: Kernel-Level Tweaks

**NixOS configuration additions:**

```nix
boot.kernelParams = [
  # Enable IOMMU
  "intel_iommu=on"
  "iommu=pt"

  # Improve performance
  "transparent_hugepage=never"
  "default_hugepagesz=1G"
  "hugepagesz=1G"

  # Optional: ACS override if IOMMU groups are problematic
  # "pcie_acs_override=downstream,multifunction"
];

boot.kernelModules = [ "kvm-intel" "vfio-pci" ];

# Reserve hugepages for VM (adjust based on VM RAM allocation)
boot.kernel.sysctl = {
  "vm.nr_hugepages" = 8; # 8GB in 1GB pages
};
```

### Level 5: Anti-Cheat Specific Bypasses

**Common detection vectors:**

1. **ACPI Tables** - Some anti-cheat checks ACPI for VM signatures
   - Use QEMU's SLIC table injection
   - Patch DSDT/SSDT tables

2. **MAC Address Ranges** - VirtIO uses specific vendor OUIs
   - Manually set MAC addresses outside VM ranges
   ```xml
   <mac address='52:54:00:xx:xx:xx'/>  <!-- Avoid this range -->
   <mac address='00:1a:2b:xx:xx:xx'/>  <!-- Use real vendor OUI -->
   ```

3. **PCI Device Paths** - Some games check PCI topology
   - Use host-passthrough CPU mode
   - Ensure GPU is on a realistic bus/slot combination

4. **Disk Controller** - VirtIO-SCSI can be detected
   - Use direct disk passthrough or NVMe controller emulation
   ```xml
   <controller type='scsi' model='virtio-scsi'/>  <!-- Detectable -->
   <controller type='nvme' model='nvme'/>         <!-- Better -->
   ```

### Testing VM Detection

**Tools to check if VM is detected:**

- **Pafish** - https://github.com/a0rtega/pafish
- **al-khaser** - https://github.com/LordNoteworthy/al-khaser
- **Windows Device Manager** - Check for "Virtual" or "QEMU" strings
- **Windows Registry** - Check `HKLM\HARDWARE\DESCRIPTION\System`

---

## 5. NixOS Configuration for VFIO

### Complete VFIO Configuration Module

Create `/etc/nixos/modules/vfio-passthrough.nix`:

```nix
{ config, lib, pkgs, ... }:

{
  # Enable IOMMU and load VFIO modules
  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"  # Passthrough mode for better performance
  ];

  boot.kernelModules = [
    "kvm-intel"
    "vfio-pci"
    "vfio"
    "vfio_iommu_type1"
  ];

  # Bind specific devices to VFIO at boot (optional - bind GPU if not using it on host)
  # Get IDs from: lspci -nn | grep -E "VGA|Audio"
  boot.extraModprobeConfig = ''
    # AMD RX 6700 XT - Only uncomment if you have a second GPU for host!
    # options vfio-pci ids=1002:73df,1002:ab28

    # Alternatively, bind ASMedia USB controller
    # options vfio-pci ids=1b21:3042
  '';

  # Libvirt/QEMU configuration
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;  # TPM emulation for Windows 11
      ovmf = {
        enable = true;  # UEFI support
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
  };

  # Enable Looking Glass (covered in section 6)
  virtualisation.libvirtd.qemu.verbatimConfig = ''
    user = "jarrett"
    group = "libvirtd"
    cgroup_device_acl = [
      "/dev/null", "/dev/full", "/dev/zero",
      "/dev/random", "/dev/urandom",
      "/dev/ptmx", "/dev/kvm",
      "/dev/kvmfr0",  # Looking Glass shared memory
      "/dev/shm/looking-glass",
      "/dev/input/by-id/"  # For input passthrough
    ]
  '';

  # Hugepages for better VM performance
  boot.kernelParams = [
    "default_hugepagesz=1G"
    "hugepagesz=1G"
    "hugepages=16"  # 16GB - adjust based on VM needs
  ];

  # User permissions
  users.groups.libvirtd.members = [ "jarrett" ];
  users.users.jarrett.extraGroups = [ "kvm" "qemu-libvirtd" ];

  # Useful tools
  environment.systemPackages = with pkgs; [
    virt-manager
    looking-glass-client
    scream  # Network audio for VMs
    barrier  # Software KVM switch (alternative to USB passthrough)
  ];

  # Network bridge for VM (optional - better than NAT)
  networking.bridges.br0.interfaces = [ ];  # Add your network interface
  networking.interfaces.br0.useDHCP = true;
}
```

### Import in `configuration.nix`:

```nix
imports = [
  ./modules/vfio-passthrough.nix
  ./modules/virtual-machines.nix  # Your existing module
  # ... other imports
];
```

---

## 6. Looking Glass - Zero-Latency Display Sharing

### What is Looking Glass?

Looking Glass allows you to display the VM's screen on your host WITHOUT additional latency or hardware. It uses shared memory (IVSHMEM) to directly share framebuffers between host and guest.

**Advantages:**
- Near-zero latency (< 1ms additional overhead)
- No need for second monitor/input switching
- Can use host desktop features (screenshots, recording, etc.)
- Mouse/keyboard can be seamlessly shared
- Guest GPU is still fully passed through

**How it works:**
1. GPU is passed to VM (full performance)
2. Looking Glass guest application captures framebuffer
3. Framebuffer is written to shared memory (IVSHMEM device)
4. Looking Glass host client reads from shared memory and displays

### IMPORTANT: AMD GPU Considerations

**AMD Reset Bug Warning:**
AMD GPUs from Polaris through RDNA 2/3 (including your RX 6700 XT) have known stability issues when used as passthrough devices:
- **Affected series:** Polaris, Vega, Navi, BigNavi (RDNA 1/2)
- **Your GPU:** RX 6700 XT (Navi 22/RDNA 2) - **AFFECTED**
- **Common issues:**
  - GPU fails to reset properly between VM restarts
  - Black screen after first VM shutdown/reboot
  - May require full host reboot to recover

**Workarounds (in order of effectiveness):**

1. **Single-shot method** (Most reliable)
   - Start VM once, use suspend/resume instead of shutdown/reboot
   - Avoid stopping and restarting the VM

2. **vendor-reset kernel module**
   ```nix
   boot.extraModulePackages = with config.boot.kernelPackages; [ vendor-reset ];
   boot.kernelModules = [ "vendor-reset" ];
   ```

3. **Pass both GPU functions** (VGA + HDMI Audio)
   - Ensures complete device isolation
   - Already recommended in base config

4. **Alternative: Swap GPU roles**
   - Use RX 6700 XT as host GPU (works fine with Looking Glass)
   - Pass through RX 6950 XT to guest (better VM performance)
   - Same reset issues but you get more power in the VM

**Note:** The host GPU (RX 6950 XT in your planned setup) is NOT affected by these issues. AMD cards work perfectly as host GPUs with Looking Glass and DMABUF support.

### NixOS Configuration for Looking Glass

**Add to your VFIO module:**

```nix
# Create IVSHMEM device
systemd.tmpfiles.rules = [
  "f /dev/shm/looking-glass 0660 jarrett qemu-libvirtd -"
];

# Or use kvmfr kernel module (recommended for better performance)
boot.extraModulePackages = with config.boot.kernelPackages; [ kvmfr ];
boot.kernelModules = [ "kvmfr" ];
boot.extraModprobeConfig = ''
  options kvmfr static_size_mb=128  # 128MB for 4K, 64MB for 1080p
'';

# Permissions
services.udev.extraRules = ''
  SUBSYSTEM=="kvmfr", OWNER="jarrett", GROUP="kvm", MODE="0660"
'';
```

### VM XML Configuration

Add to your VM (via `virsh edit` or virt-manager XML editor):

```xml
<devices>
  <!-- Looking Glass shared memory device -->
  <shmem name='looking-glass'>
    <model type='ivshmem-plain'/>
    <size unit='M'>128</size>  <!-- 128MB for 4K, adjust as needed -->
  </shmem>
</devices>
```

**Size calculation:**
- 1920x1080: 32MB minimum, 64MB recommended
- 2560x1440: 64MB minimum, 96MB recommended
- 3840x2160 (4K): 128MB minimum, 256MB recommended

Formula: `width × height × 4 × 2 / 1024 / 1024 = MB`

### Guest Setup (Windows VM)

1. Install Looking Glass host application in Windows VM
2. Download from: https://looking-glass.io/downloads
3. Install IVSHMEM driver (included in Looking Glass package)
4. Run `looking-glass-host.exe` at startup (create Task Scheduler entry)

### Host Client Usage

```bash
# Start Looking Glass client
looking-glass-client

# Common options
looking-glass-client -F  # Fullscreen
looking-glass-client -f /dev/kvmfr0  # Specify device
looking-glass-client -s  # Enable spice integration for input
```

**Keyboard shortcuts:**
- `Scroll Lock` - Capture/release mouse (default)
- `Scroll Lock + Q` - Quit
- `Scroll Lock + F` - Toggle fullscreen
- `Scroll Lock + I` - Align guest and host mouse

### Looking Glass + Barrier Setup

For seamless mouse/keyboard switching between host and VM:

```nix
environment.systemPackages = [ pkgs.barrier ];

# Barrier allows software-based KVM switching
# Host runs as server, VM runs Barrier client
# Mouse cursor crosses screen boundaries automatically
```

---

## 7. Complete Setup Checklist

### Phase 1: BIOS Configuration
- [ ] Enable Intel Virtualization Technology
- [ ] Enable Intel VT-d
- [ ] Enable Above 4G Decoding
- [ ] Enable Resizable BAR (optional)
- [ ] Disable CSM
- [ ] Set UEFI boot mode

### Phase 2: NixOS Configuration
- [ ] Create `/etc/nixos/modules/vfio-passthrough.nix`
- [ ] Import module in `configuration.nix`
- [ ] Add kernel parameters for IOMMU
- [ ] Configure hugepages
- [ ] Rebuild NixOS: `sudo nixos-rebuild switch`
- [ ] Reboot

### Phase 3: Verification
- [ ] Check IOMMU groups: `ls /sys/kernel/iommu_groups/`
- [ ] Verify IOMMU enabled: `dmesg | grep -i iommu`
- [ ] Check VFIO modules loaded: `lsmod | grep vfio`
- [ ] Identify GPU IOMMU group
- [ ] Identify ASMedia USB controller IOMMU group

### Phase 4: Physical Port Mapping
- [ ] Test USB ports with `lsusb -t` to find ASMedia ports
- [ ] Label physical ports for VM use
- [ ] Connect VM-dedicated peripherals to ASMedia ports

### Phase 5: VM Creation
- [ ] Create Windows 11 VM in virt-manager
- [ ] Set firmware to UEFI (OVMF)
- [ ] Enable TPM 2.0 emulation
- [ ] Configure CPU: host-passthrough, topology matching
- [ ] Add PCI devices: GPU (VGA + Audio)
- [ ] Add PCI device: ASMedia USB controller (07:00.0)
- [ ] Configure anti-detection settings
- [ ] Add IVSHMEM device for Looking Glass
- [ ] Install Windows 11

### Phase 6: Guest Configuration
- [ ] Install AMD GPU drivers in guest
- [ ] Install VFIO-PCI drivers if needed
- [ ] Install Looking Glass host application
- [ ] Install IVSHMEM driver
- [ ] Configure Looking Glass host to start on boot
- [ ] Test GPU performance (3DMark, games)

### Phase 7: Looking Glass Setup
- [ ] Configure kvmfr module on host
- [ ] Test Looking Glass client connection
- [ ] Configure client preferences
- [ ] (Optional) Set up Barrier for seamless input

### Phase 8: Anti-Detection Testing
- [ ] Run Pafish in guest
- [ ] Check Device Manager for VM artifacts
- [ ] Test anti-cheat games if applicable
- [ ] Adjust SMBIOS values as needed

---

## 8. Troubleshooting Common Issues

### IOMMU Groups Too Large

**Problem:** GPU is grouped with other critical devices

**Solution:**
```nix
boot.kernelParams = [
  "pcie_acs_override=downstream,multifunction"
];
```

**Warning:** This can reduce security. Only use if necessary.

### VM Won't Boot After GPU Passthrough

**Causes:**
1. GPU still bound to host driver
2. GPU VBIOS doesn't support UEFI
3. IOMMU not properly configured

**Solutions:**
```bash
# Check what's using GPU
lspci -k | grep -A 3 "VGA"

# Verify VFIO binding
lspci -k -s 03:00.0

# Extract and use custom VBIOS (see section 4)
```

### Black Screen on VM

**Common causes:**
- AMD Reset Bug (GPU doesn't reset properly) - **VERY COMMON with RX 6700 XT**
- Missing VBIOS
- Wrong GPU in XML (check PCI address)

**Solution for AMD Reset Bug (RX 6700 XT):**

```nix
# Add vendor-reset module to your VFIO configuration
boot.extraModulePackages = with config.boot.kernelPackages; [ vendor-reset ];
boot.kernelModules = [ "vendor-reset" ];
```

**Additional mitigations:**

1. **Use VM suspend instead of shutdown:**
   - In virt-manager: Actions → Suspend instead of Shutdown
   - Avoids GPU reset entirely

2. **Pass both GPU devices:**
   ```xml
   <!-- VGA Controller -->
   <hostdev mode='subsystem' type='pci' managed='yes'>
     <source>
       <address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
     </source>
   </hostdev>

   <!-- HDMI Audio Controller -->
   <hostdev mode='subsystem' type='pci' managed='yes'>
     <source>
       <address domain='0x0000' bus='0x03' slot='0x00' function='0x1'/>
     </source>
   </hostdev>
   ```

3. **If vendor-reset doesn't work:**
   - Extract and use custom VBIOS (see section 4)
   - Consider using RX 6950 XT as guest GPU instead (same issues but better perf)

4. **Last resort - manual unbind/rebind:**
   ```bash
   # Before VM shutdown
   echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
   sleep 1
   echo 1 > /sys/bus/pci/rescan
   ```

### USB Controller Won't Pass Through

**Check IOMMU group:**
```bash
# Find USB controller's group
find /sys/kernel/iommu_groups/ -name "0000:07:00.0"
```

**If grouped with other devices:**
- Use ACS override patch
- Or pass through entire group

### Looking Glass Not Working

**Common issues:**
1. IVSHMEM size too small - increase in XML
2. Permissions incorrect - check `/dev/kvmfr0` or `/dev/shm/looking-glass`
3. Guest application not running - check Task Manager
4. Wrong display captured - configure in looking-glass-host.ini

---

## 9. Performance Optimization

### CPU Pinning

Pin VM vCPUs to specific host cores for better performance:

```xml
<vcpu placement='static'>16</vcpu>
<cputune>
  <vcpupin vcpu='0' cpuset='0'/>
  <vcpupin vcpu='1' cpuset='1'/>
  <vcpupin vcpu='2' cpuset='2'/>
  <!-- ... continue for all vCPUs ... -->
  <emulatorpin cpuset='0-1'/>
</cputune>
```

**Important:** Check your CPU topology:
```bash
lscpu -e
# Pin to same CCX/CCD for AMD or P-cores for Intel hybrid
```

### Hugepages

Already configured in module. Verify allocation:
```bash
cat /proc/meminfo | grep Huge
```

### Disk I/O

Use virtio-scsi with io_uring or direct NVMe passthrough:

```xml
<!-- Option 1: virtio-scsi with io_uring -->
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='none' io='io_uring' discard='unmap'/>
  <source file='/var/lib/libvirt/images/win11.qcow2'/>
  <target dev='sda' bus='scsi'/>
</disk>

<!-- Option 2: Direct NVMe passthrough (best performance) -->
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

### Network Performance

Use virtio with vhost-net:

```xml
<interface type='bridge'>
  <model type='virtio'/>
  <driver name='vhost' queues='8'/>
  <source bridge='br0'/>
</interface>
```

---

## 10. Additional Resources

- **ArchWiki VFIO Guide:** https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF
- **Looking Glass Documentation:** https://looking-glass.io/docs/
- **NixOS Libvirt Options:** https://search.nixos.org/options?query=libvirt
- **Reddit r/VFIO:** https://reddit.com/r/VFIO
- **Level1Techs VFIO Forum:** https://forum.level1techs.com/c/software/vfio/

---

## Summary of Your Specific Setup

**Hardware:**
- Motherboard: ASRock Z690 PG Velocita
- CPU: Intel i7-14700KF (supports VT-d)
- GPU for passthrough: AMD RX 6700 XT (PCI 03:00.0)
- USB for passthrough: ASMedia ASM3042 (PCI 07:00.0)

**Recommended Approach:**
1. Enable VT-d in BIOS
2. Use QEMU/KVM with libvirt (already partially configured)
3. Pass through ASMedia USB controller (clean isolation)
4. Use Looking Glass for display (no second monitor needed)
5. Implement anti-detection measures progressively (start with Level 1-2)

**Next Steps:**
1. Configure BIOS settings
2. Apply NixOS VFIO module
3. Reboot and verify IOMMU
4. Create VM with passthrough
5. Install Looking Glass
6. Test and optimize

Good luck with your VFIO setup!
