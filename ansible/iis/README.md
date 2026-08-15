# IIS deployment contract for Azure DevOps migration

This directory is the central Ansible deployment implementation that migrated GitHub Actions workflows should call through AWX, Ansible Automation Platform, or Tower. The migration LLM should reuse this contract rather than generating application-specific IIS deployment scripts.

## Playbook

`ansible/iis/deploy-iis.yml`

The playbook expects AWX/Tower inventory and credentials to provide Windows connectivity. Do not put Windows usernames or passwords in generated GitHub Actions YAML.

## Required deployment variables

- `artifact_name` - immutable logical artifact name.
- `artifact_version` - immutable version produced once by CI.
- `artifact_uri` - exact Artifactory URI for that version.
- `health_url` - URL tested from the target Windows IIS host after deployment.
- `target_group` - inventory group, default `iis_targets`.
- `iis.site_name` - IIS site name.
- `iis.app_pool_name` - IIS application pool.
- `iis.physical_path` - deployed website path.

Optional values include `artifact_sha256`, backup/staging directories, HTTP/HTTPS bindings, certificate thumbprint, authentication mode, non-secret configuration substitutions, and health-check settings.

## Deployment guarantees

The playbook performs the following sequence:

1. Validate the immutable artifact/IIS contract.
2. Ensure deployment, backup, and staging directories exist.
3. Ensure the IIS application pool and site exist.
4. Download the exact artifact version and optionally verify SHA-256.
5. Extract the artifact to staging.
6. Back up the current deployment.
7. Stop the IIS site and application pool.
8. Replace site content with the staged artifact.
9. Apply environment-specific token substitution.
10. Configure IIS authentication.
11. Configure HTTPS/certificate when enabled.
12. Start the application pool and site.
13. Run the health check from the IIS host.
14. Roll back the previous content when deployment or validation fails.

## Secrets

Machine/WinRM credentials belong in AWX/Tower credentials. Artifactory credentials should also be provided by AWX/Tower credential injection or another approved secret mechanism. Generated workflows pass only references and non-secret deployment metadata.

## AWX project setup

Point an AWX Project at this repository and branch. AWX will discover `collections/requirements.yml`; the project uses the `ansible.windows` collection. Configure the job template playbook as `ansible/iis/deploy-iis.yml` and inventory with an `iis_targets` group containing the Windows IIS host.

For the laptop MigrationLab, configure the job template to target the Windows host over WinRM/PSRP using an AWX machine credential. The sample generated-workflow call pattern is `templates/call-iis-awx-deploy.yaml`.

## Migration LLM mapping rule

When the Azure DevOps release contains IIS/Web Deploy/PowerShell deployment logic, normalize it into the inputs of the central reusable workflow:

`.github/workflows/reusable-iis-tower-deploy.yaml`

Do not copy the Azure deployment script verbatim into every application repository. Preserve environment names, bindings, configuration values, approvals, artifact identity, and health-check semantics as inputs to this central deployment contract.
