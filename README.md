# Ubuntu Root Autologin (Ubuntu 26.04)

A Bash setup script for a **dedicated Ubuntu 26.04 GNOME lab/test machine**. It configures direct root access for a controlled lab environment.

> [!WARNING]
> **Security is deliberately reduced.** This script disables PAM password-quality checks for all users, permits weak passwords, enables SSH password login as `root`, and configures GDM to automatically log in to the root GNOME session. Run it only on a trusted, isolated lab machine, never on an Internet-exposed or shared workstation.

## Supported OS

- **Ubuntu 26.04** with GNOME and GDM3 installed.
- Requires root privileges and an interactive terminal.
- The script checks `/etc/os-release`; other Ubuntu releases cause a warning and are not validated.

## What the script does

1. Displays a security warning. Only entering `y` at `Do you want to continue? (y/N):` proceeds; Enter or any other input cancels before making changes.
2. Backs up the configuration files it modifies under `/root/root-lab-setup-backup-<timestamp>-<pid>/`.
3. Disables active `pam_pwquality.so` password-quality rules in `/etc/pam.d/common-password`; removes `use_authtok` and `obscure` options from the active `pam_unix.so` password rule, then prompts to set the root password with `passwd root`.
4. Adjusts GDM PAM root restrictions where the expected rule exists, configures automatic root login in `/etc/gdm3/custom.conf`, and sets `graphical.target` as the default boot target.
5. Installs OpenSSH Server if needed, writes `/etc/ssh/sshd_config.d/00-root-lab.conf` with `PermitRootLogin yes` and `PasswordAuthentication yes`, validates the effective SSH configuration, and enables/reloads SSH.
6. Displays verification steps and optional commands for deleting the default `user` account. **It never deletes a user automatically.**

## Run

```bash
chmod +x setup-root-lab.sh
sudo ./setup-root-lab.sh
```

Confirm the warning with `y` and enter the new root password when prompted.

## After setup

1. Reboot and verify that GDM automatically enters the root GNOME session.
2. From a second machine, confirm SSH access with `ssh root@<ubuntu-ip-or-hostname>`.
3. **Only after both tests succeed**, optionally remove the original account if it has no needed files:

   ```bash
   loginctl terminate-user user  # only if it has active sessions
   userdel -r user
   ```

   The `userdel -r` command permanently removes the user's home directory. Run account removal from an independent root session, not from the account being removed.

## Notes

- Running the script again prompts to set the root password again and creates another backup directory.
- The script is intended for Ubuntu 26.04 lab configurations; custom PAM, SSH, or display-manager configurations may need manual review.
- The script does not configure a firewall or disable system service accounts.
- Keep a working local console/root SSH session available while changing login authentication.

## Files

- `setup-root-lab.sh` — interactive system configuration script.
