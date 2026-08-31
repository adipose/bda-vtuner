@{
    # Copy this file to testbed.config.psd1 (gitignored) and edit.
    # Without a config file the code falls back to placeholders that will
    # not match your machine -- always create the config.

    # How the host reaches the machine running MPC-HC and the virtual tuner.
    #   hyperv  PowerShell Direct to a Hyper-V VM by name. The only transport
    #           that works when clone guests share a computer name with their
    #           network adapters disconnected (the pooled-rig setup).
    #   winrm   PowerShell remoting to any reachable Windows machine: a VM on
    #           another hypervisor, a second PC, bare metal. Run
    #           Enable-PSRemoting on the target first.
    #   local   Loopback remoting to THIS machine - the smallest reproduction:
    #           test-signed driver, MPC-HC and harness all on one box. Run
    #           Enable-PSRemoting locally first.
    Transport      = 'local'

    # VM name (hyperv) or computer name (winrm). Ignored for local.
    Guest          = 'my-test-box'

    # Exported credential (Get-Credential | Export-Clixml <path>).
    # Required for hyperv. Leave '' on winrm/local to use the current user.
    CredentialPath = ''

    # Rig POOL machinery - optional, Hyper-V-flavoured. Path to your broker
    # script if you run a multi-guest pool; '' disables
    # pooling, makes every claim a no-op against the single Guest above, and
    # skips the rig-id.txt identity check.
    BrokerPath     = ''
    RequireRigId   = $false

    # The account logged on at the target's console (MPC-HC runs on its
    # desktop; some tasks must name it explicitly).
    GuestConsoleUser = 'YourGuestUser'
}
