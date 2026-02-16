#!/bin/bash
# Remove old host keys from known_hosts after VM rebuild

ssh-keygen -R arch.rya-bebop.ts.net
ssh-keygen -R 100.110.203.22
ssh-keygen -R arch

echo "Old host keys removed. Now try:"
echo "  ssh hcasten@arch.rya-bebop.ts.net"