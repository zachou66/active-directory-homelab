
# Enterprise Windows Server Infrastructure Lab

> A production-style Windows Server 2022 environment built end-to-end: Active Directory with an AGDLP permission model, PowerShell-automated user provisioning, CIS-aligned GPO hardening, and Microsoft 365 hybrid identity with Intune MDM.

## What This Project Is

A self-directed lab that builds the parts of a real Windows infrastructure I'd actually be touching in a junior sysadmin or IT support role: AD structure and identity, scripted user provisioning, Group Policy enforcement, and enterprise identity management through Microsoft 365 and Intune.

The project is structured as sequential phases, each with its own validation evidence. Every step starts from a stated objective, an enterprise-reasoning justification, and the native PowerShell cmdlets used to implement it. Where a phase surfaced a real failure, that failure is documented in [Known Issues / Troubleshooting](#known-issues--troubleshooting) rather than hidden — diagnosing those is the most representative part of the actual job.

## Architecture

Single-box Windows Server 2022 environment with a Microsoft 365 hybrid identity extension.

- **Domain Controller:** Bare-metal Windows Server 2022 (Lenovo desktop, 24 GB RAM) hosting AD DS, DNS, DHCP, File and Storage Services, and Hyper-V.
  - Static IPv4: `192.168.0.174/24` · Domain: `lab.local`
  - *Note: this is a single-machine lab, so the DC also serves as the Hyper-V host out of hardware necessity. In production these roles would never be co-located on a domain controller.*
- **Client Endpoint:** `Win11-CLIENT1`, a domain-joined Windows 11 Pro VM running on Hyper-V on the same host. Hybrid Azure AD Joined and enrolled in Intune MDM.
- **Cloud:** Microsoft 365 Business Premium tenant (`zaolab.onmicrosoft.com`), with Microsoft Entra Connect syncing on-prem AD users to Entra ID.
- **Administration:** Performed via RDP to the domain controller. *In production I would avoid interactive logon to a DC and administer it remotely from a separate workstation over WinRM; that's a constraint of a one-machine lab, not a design choice.*

## Project Phases

| Phase | Focus | Status |
| --- | --- | --- |
| **0** | Environment preparation, WinRM baseline, client VM deployment | ✅ Complete |
| **1** | Active Directory foundation: OU design, AGDLP groups, baseline users, domain join | ✅ Complete |
| **2** | PowerShell user provisioning automation (idempotent, logged) | ✅ Complete |
| **3** | CIS-aligned GPO hardening: password/lockout, audit policy, USB restrictions, RDP, desktop lockdown | 🟡 Computer-side verified; user-side pending verification |
| **4** | Microsoft 365 hybrid identity: Entra Connect sync, Hybrid Azure AD Join, Intune enrollment, compliance policy | 🟡 Sync + device join + enrollment complete; one compliance control failing (see below) |

## Phase Evidence

### Phase 0 — Environment

WinRM confirmed responding on the domain controller.

→ [`evidence/phase0_test-wsman.txt`](evidence/phase0_test-wsman.txt)

### Phase 1 — Active Directory Foundation

A tiered OU design (`_Admin`, `Corporate`, `Servers`, `_Disabled`) with department sub-OUs, plus AGDLP role groups with real membership.

→ OU structure: [`evidence/phase1_ou-structure.txt`](evidence/phase1_ou-structure.txt)
→ Role-group membership: [`evidence/phase1_group-members.txt`](evidence/phase1_group-members.txt)

### Phase 2 — Provisioning Automation

A CSV-driven, idempotent onboarding script: derives SAM/UPN, creates the user in the correct department OU, adds AGDLP role-group membership, provisions a home directory, and sets NTFS permissions. Safe to re-run — existing users are skipped, not duplicated. The temporary password is passed in at runtime (`-InitialPassword`) so no credential is stored in source.

→ Script: [`Phase2_Provisioning_Scripts/Onboarding.ps1`](Phase2_Provisioning_Scripts/Onboarding.ps1)
→ Sample input: [`Phase2_Provisioning_Scripts/users.csv`](Phase2_Provisioning_Scripts/users.csv)
→ Transcript logs: [`Phase2_Provisioning_Scripts/sample-logs/`](Phase2_Provisioning_Scripts/sample-logs/)

### Phase 3 — GPO Hardening

Computer-side policies confirmed applying to `WIN11-CLIENT1`: USB restriction, RDP enablement, audit policy, and the domain password/lockout policy. GPO link order at the `Corporate` OU is shown in the GPMC screenshot.

→ Applied GPOs (computer-side): [`evidence/phase3_gpresult-client.txt`](evidence/phase3_gpresult-client.txt)
→ Link order: [`screenshots/phase3/gpmc-link-order.png`](screenshots/phase3/gpmc-link-order.png)

**Status note:** every `gpresult` so far was run as `Administrator`, so the User Configuration side returned `N/A` and `BL-User-DesktopRestrictions` is **not yet verified**. Verifying it requires logging into the client as a standard Finance user and re-running `gpresult /r`.

### Phase 4 — Hybrid Identity & Intune

- Entra Connect syncing on-prem AD to Entra ID (last sync < 1 hour).
- `WIN11-CLIENT1` Hybrid Azure AD Joined with `DeviceAuthStatus: SUCCESS` against a TPM-protected device key.
- Device enrolled in Intune and being evaluated against `CMP-Windows-Baseline`.

→ Entra Connect sync: [`screenshots/phase4/entra-connect-sync.png`](screenshots/phase4/entra-connect-sync.png)
→ Device join proof: [`evidence/phase4_dsregcmd-client.txt`](evidence/phase4_dsregcmd-client.txt)
→ Compliance policy: [`screenshots/phase4/intune-compliance-policy.png`](screenshots/phase4/intune-compliance-policy.png)
→ Device compliance state: [`screenshots/phase4/intune-device-noncompliant.png`](screenshots/phase4/intune-device-noncompliant.png)

**Status note:** the device passes 9 of 10 compliance controls. The BitLocker/encryption control is failing remediation (error `2016281112`), which marks the device **Noncompliant** overall. Documented below.

## Known Issues / Troubleshooting

This section is intentional. A homelab where everything passed on the first try isn't realistic; reading failures and tracing them to a cause is the work.

### 1. Intune compliance — BitLocker encryption remediation failing (`2016281112`)

**Symptom:** `WIN11-CLIENT1` reports Noncompliant in Intune. Nine controls (Firewall, Antivirus, Defender, Secure Boot, TPM, etc.) are Compliant; `Encryption of data storage on device` shows `Error — 2016281112 (Remediation failed)`.

**Working diagnosis:** Error `2016281112` is an encryption-state failure — the device key/TPM is present (`dsregcmd` reports `TpmProtected: YES`), so the likely cause is that BitLocker silent encryption isn't completing on the Hyper-V virtual TPM, or the OS volume isn't in a state the policy can auto-encrypt.

**Next step / status:** Check `manage-bde -status` on the client to read the actual volume encryption state and confirm whether the vTPM is being presented correctly, then either enable encryption so the device re-evaluates to Compliant, or confirm and document this as a known limitation of BitLocker auto-encryption on a Hyper-V vTPM. **Open.**

### 2. `dcdiag` — three failing tests

**Symptom:** `dcdiag /q` reports `DFSREvent`, `NCSecDesc`, and `SystemLog` failures.

**Working diagnosis:**
- `SystemLog` is the actionable one — the embedded event is *"The DHCP service failed to see a directory server for authorization,"* i.e. the DHCP server is not authorized in AD.
- `NCSecDesc` flags the RODC group missing `Replicating Directory Changes` on the domain naming context (commonly benign on a single-DC build with no RODCs, but worth confirming).
- `DFSREvent` indicates SYSVOL replication warnings in the last 24h, which can affect Group Policy delivery.

**Next step / status:** Authorize DHCP in AD (`Add-DhcpServerInDC`), review the DFSR/SYSVOL event log, and re-run `dcdiag` for a clean result. **Open.**

→ Capture: [`evidence/troubleshooting_dcdiag.txt`](evidence/troubleshooting_dcdiag.txt)

## Key Design Decisions

- **AGDLP (Account → Global → Domain Local → Permission):** role membership and resource access are deliberately separated. `R-*` groups describe who someone is; `ACL-*` groups describe what a resource grants. Resource groups sit on the ACL — never users, never role groups directly.
- **Idempotent automation:** the provisioning script is safe to re-run. Existing users are skipped, not duplicated; failures are caught and logged without leaving partial state.
- **Hybrid identity over cloud-only:** users are mastered on-premises in AD DS and synced to Entra ID, so one identity works for both on-prem resources and cloud/Intune-managed policies — the pattern most mid-size organizations actually run.
- **Documentation as deliverable:** each phase is closed with verification evidence, and real failures are written up rather than hidden.

## Naming Conventions

| Object Type | Convention | Example |
| --- | --- | --- |
| OU (Department) | Singular noun, PascalCase | `Finance`, `Engineering` |
| Security Group (Role) | `R-<Department>-<Role>` | `R-Finance-Accountants` |
| Security Group (Resource ACL) | `ACL-<Resource>-<Permission>` | `ACL-FinanceShare-RW` |
| User SAM | `firstname.lastname` | `alice.thompson` |
| GPO (Baseline) | `BL-<Scope>-<Purpose>` | `BL-User-DesktopRestrictions` |
| Compliance Policy (Intune) | `CMP-<Platform>-<Scope>` | `CMP-Windows-Baseline` |

## Skills Demonstrated

- **Active Directory:** OU design and delegation · AGDLP permission modeling · `dcdiag` health verification and failure triage · DNS/SRV validation · domain join and computer object lifecycle
- **PowerShell:** `ActiveDirectory` / `GroupPolicy` modules · CSV-driven automation · idempotent script design · `Try`/`Catch` error handling · `Start-Transcript` logging · NTFS ACL manipulation via `System.Security.AccessControl`
- **Group Policy:** GPO authoring (Computer and User config) · advanced audit policy · removable-media restriction · domain password/lockout policy · link order and LSDOU precedence · `gpresult` / RSOP verification
- **Microsoft 365 & Intune:** Entra Connect sync · Hybrid Azure AD Join · `dsregcmd /status` verification · Intune enrollment · compliance policy design (BitLocker, Secure Boot, Defender, Firewall) · reading and triaging compliance failures
- **Operational discipline:** per-phase validation · event-log-based verification · honest documentation of deviations and open issues

## Roadmap

- **Verify user-side GPO** by testing `gpresult` as a standard Finance user (closes Phase 3).
- **Resolve the two open troubleshooting items** above (closes Phase 4 compliance + clean `dcdiag`).
- **Offboarding script** — companion to onboarding, with an audit CSV of removed group memberships.
- **Conditional Access in Entra ID** — require a compliant device for M365 access.
- **Win32 app deployment via Intune** to `CLIENT1`.

## Author

**Zachary Ouldsfiya** — UMass Boston · BS Information Technology (System Administration Track) · May 2026
CompTIA Security+ · Microsoft AZ-900 (in progress) 
ouldsfiyazachary@gmail.com

