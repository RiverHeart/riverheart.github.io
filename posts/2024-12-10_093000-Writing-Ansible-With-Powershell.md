---
title: Writing Ansible With Powershell
date: 2024-12-10T09:30:00-04:00
---

## Overview

Hello fine people of the internet! After banging my head against the proverbial wall I've come to share the wisdom leaking out of my head.

If you're here I assume you, like me, are a Powershell fanboy not content to meekly run Powershell scripts from YAML. No? Perhaps you recognize Python's clunkiness for sysadmin work, and you WANT learn how to use Powershell in it's raw form to manage Linux machines. Maybe you'd like to use this method to write modules in another language entirely, that's entirely doable. Whatever the reason you're here to learn and learning is great.

Now sure, there are some [resources](https://docs.ansible.com/ansible/latest/dev_guide/developing_modules_general_windows.html) out there detailing the use of Powershell with Ansible but those I've come across focus on Windows and, arguably, hide the simplicity of Ansible's inner workings.

## Table of Contents
- [Cloud Init](#cloud-init)
- [Powershell Module](#powershell-script)
- [Playbook](#playbook)

## Cloud Init

To start, let's bootstrap Powershell on the server using [cloud-init](https://cloud-init.io/) so it's immediately available to us.

During Azure/AWS/etc VM creation, you provide a yaml file like the one below. In it, we add the Microsoft repo and install Powershell. I'm explicitly providing the public key for the Microsoft repo but you can use a key id instead to query `keyserver.ubuntu.com`. To find the public key id of a gpg file run `gpg --show-keys /path/to/foobar.gpg`.

If your VM doesn't have an Ansible user already you may be interested in [bootstrapping one using cloud-init](https://cloudinit.readthedocs.io/en/latest/reference/examples.html#configure-instance-to-be-managed-by-ansible).


**cloud-init.yml**
```yml
## template: jinja
#cloud-config

package_reboot_if_required: true
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - wget
  - software-properties-common
  - powershell

apt:
  preserve_sources_list: true
  sources_list: |
    Types: deb
    URIs: https://packages.microsoft.com/ubuntu/{{ distro_version }}/prod
    Suites: $RELEASE
    Components: main
    Signed-By: $KEY_FILE
  sources:
    microsoft-prod:
      source: 'deb [arch=amd64,armhf,arm64 signed-by=$KEY_FILE] https://packages.microsoft.com/ubuntu/{{ distro_version }}/prod $RELEASE main'
      # Convert binary key to ASCII
      # gpg --keyring /etc/apt/trusted.gpg.d/microsoft-prod.gpg --no-default-keyring --export -a > microsoft.asc
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        mQENBFYxWIwBCADAKoZhZlJxGNGWzqV+1OG1xiQeoowKhssGAKvd+buXCGISZJwT
        LXZqIcIiLP7pqdcZWtE9bSc7yBY2MalDp9Liu0KekywQ6VVX1T72NPf5Ev6x6DLV
        7aVWsCzUAF+eb7DC9fPuFLEdxmOEYoPjzrQ7cCnSV4JQxAqhU4T6OjbvRazGl3ag
        OeizPXmRljMtUUttHQZnRhtlzkmwIrUivbfFPD+fEoHJ1+uIdfOzZX8/oKHKLe2j
        H632kvsNzJFlROVvGLYAk2WRcLu+RjjggixhwiB+Mu/A8Tf4V6b+YppS44q8EvVr
        M+QvY7LNSOffSO6Slsy9oisGTdfE39nC7pVRABEBAAG0N01pY3Jvc29mdCAoUmVs
        ZWFzZSBzaWduaW5nKSA8Z3Bnc2VjdXJpdHlAbWljcm9zb2Z0LmNvbT6JATUEEwEC
        AB8FAlYxWIwCGwMGCwkIBwMCBBUCCAMDFgIBAh4BAheAAAoJEOs+lK2+EinPGpsH
        /32vKy29Hg51H9dfFJMx0/a/F+5vKeCeVqimvyTM04C+XENNuSbYZ3eRPHGHFLqe
        MNGxsfb7C7ZxEeW7J/vSzRgHxm7ZvESisUYRFq2sgkJ+HFERNrqfci45bdhmrUsy
        7SWw9ybxdFOkuQoyKD3tBmiGfONQMlBaOMWdAsic965rvJsd5zYaZZFI1UwTkFXV
        KJt3bp3Ngn1vEYXwijGTa+FXz6GLHueJwF0I7ug34DgUkAFvAs8Hacr2DRYxL5RJ
        XdNgj4Jd2/g6T9InmWT0hASljur+dJnzNiNCkbn9KbX7J/qK1IbR8y560yRmFsU+
        NdCFTW7wY0Fb1fWJ+/KTsC4=
        =J6gs
        -----END PGP PUBLIC KEY BLOCK-----
```

In the module below, we're ignoring any existing Ansible powershell helpers that may exist for simplicity's sake. To start, we read an Ansible provided parameter file from `arg0` to produce a hashtable.

> [!IMPORTANT]
> Crucially, the string `WANT_JSON` is set somewhere in the module because it tells Ansible to pass us JSON instead of key/value pairs.

Since idempotency is a core principle of Ansible, it's important that our module abides by it. If you're not already familiar, Powershell supports idempotency via WhatIf mode which is controlled using the `$WhatIfPreference` variable and `-WhatIf` flag for advanced cmdlets (ones with `[CmdletBinding()]` above the `param` block). Below, we set `$WhatIfPreference = $Ansible._ansible_check_mode` to ensure our code executes in WhatIf mode when the `-C` or `--check` flag is provided. Builtin cmdlets like `New-Item` support WhatIf mode already, and inherit that setting from the caller, so nothing special needs done. Any code that doesn't support or properly implement WhatIf mode needs to be wrapped using `ShouldProcess` as in `if ($PSCmdlet.ShouldProcess("Target", "Perform Task") { ...code... }`.

If you need a fresher or refresher on `ShouldProcess` please consult [this excellent guide](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess?view=powershell-7.4).

Everything else in the module is standard powershell and ends with us serializing our response as JSON so Ansible can use it to check for changes and present them to the user.

### Powershell Script

**library/powershell_example.ps1**
```powershell
#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Places a file on the filesystem

.NOTES
    Maybe Ansible.ModuleUtils.Legacy module is useful here?

.LINK
    https://github.com/ansible/ansible/blob/1ad0c404ef05f6d6a03d59ad25b55860f15d1da0/lib/ansible/module_utils/powershell/Ansible.ModuleUtils.Legacy.psm1#L140
#>

# (Crucial) Indicate that this is a non-native module
# https://docs.ansible.com/ansible/2.7/dev_guide/developing_program_flow_modules.html#non-native-want-json-modules
# WANT_JSON

$Ansible = Get-Content $Args[0] | ConvertFrom-Json
$WhatIfPreference = $Ansible._ansible_check_mode

# Result to return to Ansible at end of script
$Result = @{
    path = ''
    changed = $true
    original_state = ''
    state = ''
}

$Path = $Ansible.Path #  /etc/testing/foo.txt
$Result.Path = $Path

if (-not (Test-Path $Path)) {
    New-Item $Path -Force
    $Result.original_state = 'Absent'
    $Result.state = 'Present'
} else {
    $Result.Changed = $false
    $Result.original_state = 'Present'
    $Result.state = 'Present'
}

return $Result | ConvertTo-Json -Depth 100 -Compress
```

> [!IMPORTANT]
> In our playbook file we set the TERM env to `dumb` to avoid an issue with Powershell escape codes mucking up the JSON response from our module which Ansible uses to determine whether it succeeded.

We provide the name of the module as a task and provide any properties our module expects. In this case, we just need the `path` to the file to create.

### Playbook

**playbooks/powershell_example.yml**
```yml
- name: Test
  hosts: all
  become: true
  environment:
    # Avoid escape codes breaking output
    # See https://github.com/ansible/ansible/issues/48881#issuecomment-440481672
    - TERM: dumb
  gather_facts: true
  tasks:
    - name: Test
      powershell_example:
        path: '/etc/testing/foo.txt'
```

Finally, we test our playbook against a machine, substituting `1.2.3.4` with an IP address or hostname.

```bash
# Dry run
ansible-playbook playbooks/powershell_example.yml -C -i ', 1.2.3.4' -v

# Real run
ansible-playbook playbooks/powershell_example.yml -i ', 1.2.3.4' -v
```