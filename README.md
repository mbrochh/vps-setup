# Intro

This script is to provision and lock down a Debian VPS.

What it does:

- enable automatic security updates (you still need to reboot yourself)
- installs Zsh, makes it default shell
- install zoxide
- adds user admin (sudo user)
- adds user pi (not sudo user)
- installs Tailscale
- disables sshd password logins
- enables ufw, only allows inbound traffic from Tailscale
- disables root SSH login

Note: You might not need the `pi` user. I use it to install agents under that user.
You can also change the variable `AGENT_USER` in the script and give it another i
name if you like.


# Tailscale Policy

This policy makes sure that your servers can't connect to any other machine.

```
{
	// Only tailnet admins can apply tag:server to a device.
	"tagOwners": {
		"tag:server": ["autogroup:admin"],
	},

	"grants": [
		// Your own (user-owned) devices can reach everything, including servers.
		// Tagged devices aren't "members", so servers can't open connections
		// to anything: not your laptop, not each other.
		{"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
	],

	// Unchanged. Only applies to Tailscale SSH (you use regular sshd),
	// and autogroup:self never matches tagged devices anyway.
	"ssh": [
		{
			"action": "check",
			"src":    ["autogroup:member"],
			"dst":    ["autogroup:self"],
			"users":  ["autogroup:nonroot", "root"],
		},
	],

	// Checked every time you save; the save fails if a test fails.
	"tests": [
		{
			"src":    "yourname@github", // your Tailscale login
			"accept": ["tag:server:22"],
		},
		{
			"src":  "tag:server",
			"deny": ["100.x.y.z:22"], // your laptop's Tailscale IP
		},
	],
}
```

# Usage

Get a Tailscale auth-key at https://console.tailscale.com/admin/settings/keys

Set TS_HOSTNAME and TS_AUTHKEY variables at the top of the script.

Usage (from your machine):
  scp vps-setup.sh root@<public-ip>:
  ssh -t root@<public-ip> 'bash vps-setup.sh'
