# Intro

This script is to provision and lock down a Debian VPS.

The firewall closes all ports. 

In order to serve traffic, we shall use a Cloudflare tunnel.

In order to SSH into the machine, we shall use Tailscale.

It also creates a user admin (which can sudo) and a user pi (which cannot sudo).

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
