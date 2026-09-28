# Active-Directory-Certificate-Services-Issued-and-Published-Certificate-Inventory

Read-only inventory script for planning upgrades of Windows Server 2012 R2 PKI servers. Run `Export-ADCSMultiCAInventory.ps1` **locally on each server** to record installed AD CS role services, identify a local certification authority (CA), inventory issued-request records, and capture templates published by that enterprise CA.

> **Status:** The replacement script has not been executed against the target Windows Server 2012 R2 environment. Validate PowerShell syntax and the first server's outputs before treating the inventory as complete. This is an inventory, **not** an AD CS backup, certificate/private-key export, migration tool, or upgrade readiness certification.

## Scope

- `Inventory`: installed `ADCS*` Windows features, local CA name, CA type, and CertSvc state.
- `Issued`: local CA's issued request view (`Disposition=20`), raw extension/attribute views, and database schema outputs. Only runs if a local CA is detected.
- `Templates`: enterprise CA's published-template names, matching readable AD template properties, and template access-control entries. Not applicable to standalone CAs or non-CA role servers.
- `All` (default): all applicable sections. Non-CA servers still produce a role inventory.

**Four-server rule:** run once on **each of the four PKI servers**. Each CA has its own issuance records; template definitions are forest-wide AD objects, while each enterprise CA has its own published-template list. Repeated template settings across runs are expected when multiple CAs publish the same template.

## Prerequisites

- Windows PowerShell 4.0 or later; use Windows PowerShell, not PowerShell 7, on the target server.
- Run locally with access to installed ServerManager features and, for CA database exports, sufficient CA database read permissions.
- `certutil.exe` for CA views; installed with Certificate Services on a CA.
- For `Templates`/`All` on enterprise CAs: the ActiveDirectory PowerShell module and permission to read the forest Configuration partition and template security descriptors.
- Writable, appropriately restricted `-OutputRoot`; exports may include sensitive requester names, certificate metadata, template configuration, and permissions.
- For offline roots: run while the server is available; an offline root is normally a standalone CA and will not export AD template data.

## Install and syntax check

Place `Export-ADCSMultiCAInventory.ps1` in `C:\Script` on each server. In **Windows PowerShell**, check parsing before running:

```powershell
$path = 'C:\Script\Export-ADCSMultiCAInventory.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

No output from `$errors` means the parser found no syntax errors; it does **not** establish that AD queries or `certutil` commands will succeed in your environment.

## Run

```powershell
Set-Location C:\Script
.\Export-ADCSMultiCAInventory.ps1 -Export Inventory -OutputRoot C:\ADCS-Inventory
.\Export-ADCSMultiCAInventory.ps1 -Export All -OutputRoot C:\ADCS-Inventory
```

Run individual sections when needed:

```powershell
.\Export-ADCSMultiCAInventory.ps1 -Export Issued -OutputRoot C:\ADCS-Inventory
.\Export-ADCSMultiCAInventory.ps1 -Export Templates -OutputRoot C:\ADCS-Inventory
```

Each invocation creates a separate `<Server>_<CA>_<timestamp>` directory. `Inventory` and `All` are separate runs and therefore create separate directories. **Do not assume a file exists simply because the run finished:** check warnings and verify row counts.

## Outputs

| File | What it represents |
| --- | --- |
| `ServerAndCAInventory.csv` | Server identity, installed AD CS roles, detected CA name/type, CertSvc status, selected mode. |
| `InstalledADCSRoles.csv` | Installed AD CS features; absent if no matching features were found or role detection failed. |
| `IssuedCertificates_Raw.csv` | Native `certutil` CSV output filtered to issued requests; retain as evidence. |
| `IssuedCertificates_ByCA.csv` | Issued rows with `CAServer`, `CAName`, and `CAType`, **only if** the raw header is recognized and usable rows are parsed. |
| `RequestCertificateSchema.txt`, `ExtensionSchema.txt`, `AttributeSchema.txt` | CA database schema command outputs; check warnings if a verb is unsupported. |
| `Extensions_Raw.csv`, `RequestAttributes_Raw.csv` | Raw related CA database tables; **not restricted to issued requests**. Relate using Request ID. |
| `CAPublishedTemplateMapping.csv` | Template names published by the detected enterprise CA; absent when none are published or export fails. |
| `PublishedTemplateAttributes.csv` | Readable AD template properties, one value per row; binary values are Base64. |
| `PublishedTemplatePermissions.csv` | AD template ACL entries and SDDL as read by the executing identity. |
| `Warnings.txt` | Only created when one or more warnings occur; review before declaring a run complete. |

`IssuedCertificates_Raw.csv` is a CA database **inventory**, not individual `.cer` files or private keys. A default CA view is not guaranteed to include every possible CA database field. The schema and related tables are separate; the script does not join them into a complete per-certificate record. `PublishedTemplatePermissions.csv` contains access-control entries, not a calculated effective-permissions assessment.

## First-server acceptance checks

1. Verify the parser check returns no errors.
2. Run `-Export Inventory` and confirm installed role services, CA name/type, and service state against the server.
3. Run `-Export All`. Review `Warnings.txt` if present. Do not interpret a skipped section as success.
4. Open `IssuedCertificates_Raw.csv`; confirm it is a real CSV with a request-ID column, then check `IssuedCertificates_ByCA.csv` exists and its rows carry the correct CA identity. Compare counts with the CA console using equivalent scope/filter.
5. For enterprise CAs, compare `CAPublishedTemplateMapping.csv` with templates listed under the CA console; spot-check AD attributes and ACLs in the Certificate Templates snap-in.
6. Repeat on the other three servers. Preserve each run folder separately and restrict access to the exports.

## Known limitations

- **Environment validation pending:** `certutil` switches/output and CSV headers may differ by Windows version and CA configuration. An unsupported view writes a warning and may leave a raw error-output file. Inspect it rather than treating it as CSV data.
- The script does not enumerate certificate files in client/server stores, export certificate/private keys, back up the CA database or configuration, capture CRLs/AIA, or validate AD CS upgrade compatibility.
- Only templates **published by the local enterprise CA** are included; unused forest templates are intentionally excluded.
- A Web Enrollment or Online Responder-only server has no local CA issuance database to export.
- The script does not merge the four inventories or calculate effective permissions. Keep `CAServer` and `CAName` when aggregating.
- If an export fails, the script can still finish and report warnings; check the output, not just the exit behavior.

## Wiki

The GitHub Wiki is a separate repository. Copy `Home.md`, `Operations.md`, and `Troubleshooting.md` from the accompanying wiki bundle into `<repository>.wiki.git`, or create pages with those titles in the GitHub Wiki UI. Upload `README.md` and the `.ps1` script to the main repository. **Do not upload production CSVs, CA databases, certificate material, or customer identifiers to a public repository.**

## References

- [Microsoft: certutil command reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil)
- [Microsoft: CA type enumeration](https://learn.microsoft.com/en-us/windows/win32/api/certsrv/ne-certsrv-enum_catypes)
- [Microsoft: Enterprise CA publication in AD](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wcce/ad150321-4b89-4802-8713-6c7a51cc0b84)
- [Microsoft: certificate template concepts](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/certificate-template-concepts)
- [GitHub: adding or editing wiki pages](https://docs.github.com/en/communities/documenting-your-project-with-wikis/adding-or-editing-wiki-pages)

