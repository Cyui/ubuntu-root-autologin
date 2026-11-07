#!/usr/bin/env bash
# Ubuntu 24.04 GNOME lab machine: root password, GDM root autologin, SSH root password login.
# Also tested on Ubuntu 26.04, where Nautilus refuses to run as root.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo 'ERROR: Run this script as root: sudo bash setup-root-lab.sh' >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo 'ERROR: /etc/os-release is missing.' >&2
    exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != ubuntu ]]; then
    echo "ERROR: This script targets Ubuntu (detected: ${ID:-unknown})." >&2
    exit 1
fi
if [[ "${VERSION_ID:-}" == '26.04' ]]; then
    echo 'WARNING: Ubuntu 26.04 Nautilus refuses to run as root, so the file manager cannot open in the root GNOME session. This script does not bypass that restriction. Ubuntu 24.04 is tested and working.' >&2
elif [[ "${VERSION_ID:-}" != '24.04' ]]; then
    echo "WARNING: Primarily tested for Ubuntu 24.04; also tested on 26.04 with a known Nautilus limitation. Detected ${VERSION_ID:-unknown} has not been validated." >&2
fi

if [[ ! -f /etc/gdm3/custom.conf || ! -f /etc/pam.d/gdm-autologin ]]; then
    echo 'ERROR: GDM3 configuration is not installed. Install the Ubuntu GNOME desktop first.' >&2
    exit 1
fi

# Require explicit acknowledgement before changing any system configuration.
printf '\n%s\n' \
    '============================================================' \
    'WARNING: SECURITY RISKS' \
    '============================================================' \
    'This script modifies system password policies to allow weak passwords.' \
    'It disables PAM password-quality checks for all users, reducing security.' \
    'It also enables root password login over SSH and automatic root login' \
    'to the GNOME desktop. These changes increase the risk of unauthorized' \
    'access, especially on untrusted networks.' \
    '' \
    'Only run this script on a trusted, isolated lab machine.' \
    '============================================================'
if [[ ! -t 0 ]]; then
    echo 'ERROR: Interactive confirmation requires a terminal. No changes made.' >&2
    exit 1
fi
read -r -p 'Do you want to continue? (y/N): ' confirmation
if [[ "$confirmation" != 'y' ]]; then
    echo 'Cancelled. No changes made.'
    exit 0
fi

backup_dir="/root/root-lab-setup-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 -p "$backup_dir"
backup_file() {
    local path="$1"
    if [[ -e "$path" ]]; then
        mkdir -p "$backup_dir$(dirname "$path")"
        cp -a -- "$path" "$backup_dir$path"
    fi
}

printf '\n[1/4] Disable PAM password-quality warnings, then set root password\n'
# pam_pwquality normally prompts for the new password. When disabling it,
# pam_unix must NOT keep use_authtok, or passwd cannot obtain a new password.
# Also drop pam_unix obscure checks for the requested simple-password policy.
pam_password=/etc/pam.d/common-password
if [[ ! -f "$pam_password" ]] || ! grep -Eq '^[[:space:]]*password[[:space:]].*pam_unix\.so([[:space:]]|$)' "$pam_password"; then
    echo 'ERROR: Expected pam_unix.so password rule not found; refusing to change PAM.' >&2
    exit 1
fi
backup_file "$pam_password"
python3 - "$pam_password" <<'PYCODE'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
updated = []
for line in lines:
    if re.match(r"^\s*password\s+", line) and re.search(r"\bpam_pwquality\.so(?=\s|$)", line):
        # Skip already-commented lines, so reruns are safe.
        line = "# root-lab: " + line
    elif re.match(r"^\s*password\s+", line) and re.search(r"\bpam_unix\.so(?=\s|$)", line):
        line = re.sub(r"(?<!\S)(?:use_authtok|obscure)(?!\S)", "", line)
    updated.append(line)
new = "".join(updated)
if new != "".join(lines):
    path.write_text(new)
PYCODE
passwd root

printf '\n[2/4] Configure GDM root autologin\n'
backup_file /etc/gdm3/custom.conf
for pam_file in /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin; do
    if [[ -f "$pam_file" ]]; then
        backup_file "$pam_file"
        # Only disable the exact PAM auth rule that rejects root.
        sed -i -E \
            '/^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_succeed_if\.so[[:space:]]+user[[:space:]]*!=[[:space:]]*root([[:space:]]|$)/s/^/# root-lab: /' \
            "$pam_file"
    fi
done

# Modify only the keys in [daemon], preserving all other GDM sections.
gdm_tmp="$(mktemp /etc/gdm3/.custom.conf.XXXXXX)"
awk '
BEGIN { in_daemon=0; saw_daemon=0; wrote_enable=0; wrote_login=0 }
function flush_daemon() {
    if (in_daemon) {
        if (!wrote_enable) print "AutomaticLoginEnable=true"
        if (!wrote_login) print "AutomaticLogin=root"
    }
}
/^\[[^]]+\][[:space:]]*$/ {
    flush_daemon()
    in_daemon=($0 ~ /^\[daemon\][[:space:]]*$/)
    if (in_daemon) saw_daemon=1
    print
    next
}
in_daemon && /^[[:space:]]*#?[[:space:]]*AutomaticLoginEnable[[:space:]]*=/ {
    if (!wrote_enable) print "AutomaticLoginEnable=true"
    wrote_enable=1
    next
}
in_daemon && /^[[:space:]]*#?[[:space:]]*AutomaticLogin[[:space:]]*=/ {
    if (!wrote_login) print "AutomaticLogin=root"
    wrote_login=1
    next
}
{ print }
END {
    flush_daemon()
    if (!saw_daemon) {
        print ""
        print "[daemon]"
        print "AutomaticLoginEnable=true"
        print "AutomaticLogin=root"
    }
}
' /etc/gdm3/custom.conf > "$gdm_tmp"
chmod --reference=/etc/gdm3/custom.conf "$gdm_tmp"
chown --reference=/etc/gdm3/custom.conf "$gdm_tmp"
mv -f -- "$gdm_tmp" /etc/gdm3/custom.conf
systemctl set-default graphical.target

printf '\n[3/4] Install and configure OpenSSH Server\n'
if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
fi
install -d -m 755 /etc/ssh/sshd_config.d
ssh_conf=/etc/ssh/sshd_config.d/00-root-lab.conf
backup_file "$ssh_conf"
cat > "$ssh_conf" <<'SSHEOF'
# Lab machine: allow direct root login with password.
PermitRootLogin yes
PasswordAuthentication yes
SSHEOF
chmod 644 "$ssh_conf"
if ! /usr/sbin/sshd -t; then
    echo 'ERROR: SSH configuration invalid. Review /etc/ssh/sshd_config*.' >&2
    exit 1
fi
ssh_effective="$(/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1)"
printf '%s\n' "$ssh_effective" | grep -E '^(permitrootlogin|passwordauthentication) '
if ! grep -qx 'permitrootlogin yes' <<< "$ssh_effective" || \
   ! grep -qx 'passwordauthentication yes' <<< "$ssh_effective"; then
    echo 'ERROR: SSH root/password settings are overridden by an earlier configuration or Match block.' >&2
    echo 'Check: /etc/ssh/sshd_config and /etc/ssh/sshd_config.d/*.conf' >&2
    exit 1
fi
systemctl enable --now ssh.service
systemctl reload ssh.service

printf '\n[4/4] Results\n'
echo 'GDM configuration:'
awk '/^\[daemon\]/{p=1;next} /^\[/{p=0} p && /^[[:space:]]*AutomaticLogin/{print}' /etc/gdm3/custom.conf
echo "Backup directory: $backup_dir"
echo
printf '%s\n' 'NEXT STEPS:' \
    '1. Reboot and confirm that GDM automatically logs into the root GNOME session.' \
    '2. From another computer, verify: ssh root@<ubuntu-ip-or-hostname>' \
    '3. Only after BOTH tests succeed, optionally delete the default user:' \
    '      loginctl terminate-user user' \
    '      userdel -r user' \
    '   (Skip the terminate-user command if that account has no active sessions.)'
