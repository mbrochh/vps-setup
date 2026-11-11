# Intro

This script is to provision and lock down a Debian VPS.

The firewall closes all ports. In order to server traffic, we shall use a Cloudflare tunnel.

In order to SSH into the machine, we shall use Tailscale.

It also creates a user admin (which can sudo) and a user pi (which cannot sudo).

# Usage

Get a Tailscale auth-key at https://console.tailscale.com/admin/settings/keys

Set TS_HOSTNAME and TS_AUTHKEY variables at the top of the script.

Usage (from your machine):
  scp vps-setup.sh root@<public-ip>:
  ssh -t root@<public-ip> 'bash vps-setup.sh'
