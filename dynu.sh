#!/bin/bash

# Update and install required packages
echo "Updating package list and installing required packages..."
sudo apt-get update
sudo apt-get install -y jq sqlite3 python3-pip

# Install requests library for Python
pip3 install requests

# Prompt for Cloudflare Global API Key and Email
echo "Enter your Cloudflare Global API Key:"
read -r CLOUDFLARE_API_KEY
echo "Enter your Cloudflare account email:"
read -r CLOUDFLARE_EMAIL

# List domains using the Cloudflare API
echo "Fetching domains from Cloudflare..."
response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "Content-Type: application/json")

# Extract domain names and zone IDs
domains=$(echo "$response" | jq -r '.result[] | "\(.name) \(.id)"')
echo "Available domains:"
echo "$domains"

# Let user select a domain
echo "Enter the domain name you want to select:"
read -r selected_domain

# Validate the selected domain
zone_id=$(echo "$domains" | grep "$selected_domain" | awk '{print $2}')
if [ -z "$zone_id" ]; then
  echo "Domain not found. Exiting."
  exit 1
fi

echo "Selected domain: $selected_domain (Zone ID: $zone_id)"

# Let user choose between manual or random subdomain
echo "Do you want the subdomain to be manual or random? (manual/random)"
read -r choice

if [ "$choice" = "manual" ]; then
  echo "Enter the desired subdomain:"
  read -r subdomain
else
  subdomain=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
  echo "Generated random subdomain: $subdomain"
fi

# Prompt for IPv6 subnet
echo "Enter your IPv6 subnet (e.g., 2001:db8:2001:db8::/64):"
read -r ipv6_subnet

# Create SQLite database and table
echo "Creating SQLite database and table..."
sqlite3 /opt/cloudflare_config.db <<EOF
CREATE TABLE IF NOT EXISTS config (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    api_token TEXT,
    email TEXT,
    domain TEXT,
    zone_id TEXT,
    subdomain TEXT,
    ipv6_subnet TEXT
);
CREATE TABLE IF NOT EXISTS used_ips (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ipv6 TEXT UNIQUE
);
EOF

# Insert configuration into database
echo "Saving configuration to the database..."
sqlite3 /opt/cloudflare_config.db <<EOF
INSERT INTO config (api_token, email, domain, zone_id, subdomain, ipv6_subnet)
VALUES ('$CLOUDFLARE_API_KEY', '$CLOUDFLARE_EMAIL', '$selected_domain', '$zone_id', '$subdomain', '$ipv6_subnet');
EOF

# Create the Python script
echo "Creating the Python script..."
cat << 'EOF' > /opt/cloudflare_ipv6_updater.py
import requests
import sqlite3
import random
import ipaddress

# Load configuration from the database
conn = sqlite3.connect('/opt/cloudflare_config.db')
cursor = conn.cursor()
cursor.execute("SELECT api_token, email, domain, zone_id, subdomain, ipv6_subnet FROM config ORDER BY id DESC LIMIT 1;")
config = cursor.fetchone()
api_token, email, selected_domain, zone_id, subdomain, subnet_prefix = config

# Print configuration for debugging
print(f"API Key: {api_token}")
print(f"Domain: {selected_domain}")
print(f"Zone ID: {zone_id}")
print(f"Subdomain: {subdomain}")
print(f"IPv6 Subnet Prefix: {subnet_prefix}")

# Generate a random IPv6 address from /64 subnet
def generate_random_ipv6(subnet_prefix):
    suffix = ':'.join(['%x' % random.randint(0, 2**16-1) for _ in range(4)])
    return f"{subnet_prefix}{suffix}"

# Check if IPv6 address has been used
def is_ipv6_used(ipv6):
    cursor.execute("SELECT * FROM used_ips WHERE ipv6 = ?", (ipv6,))
    return cursor.fetchone() is not None

# Fetch existing DNS records for the subdomain
def fetch_dns_records(zone_id, domain, subdomain):
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={subdomain}.{domain}"
    headers = {
        "X-Auth-Key": api_token,
        "X-Auth-Email": email,
        "Content-Type": "application/json"
    }
    
    response = requests.get(url, headers=headers)
    result = response.json()
    
    # Debugging output
    print(f"Request URL: {url}")
    print(f"Request Headers: {headers}")
    print(f"API response: {result}")

    if not result.get('success', False):
        print(f"Error: {result.get('errors', [{'message': 'Unknown error'}])[0]['message']}")
    
    return result.get('result', [])

def is_valid_ipv6(address):
    try:
        ipaddress.IPv6Address(address)
        return True
    except ipaddress.AddressValueError:
        return False
        
# Update or create a DNS record on Cloudflare
def update_or_create_dns_record(zone_id, domain, subdomain, ipv6):
    records = fetch_dns_records(zone_id, domain, subdomain)
    
    headers = {
        "X-Auth-Key": api_token,
        "X-Auth-Email": email,
        "Content-Type": "application/json"
    }
    
    if records:
        # Update existing record
        record_id = records[0]['id']
        data = {
            "type": "AAAA",
            "name": f"{subdomain}.{domain}",
            "content": ipv6,
            "ttl": 120
        }
        response = requests.put(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}", headers=headers, json=data)
        if response.status_code == 200:
            print(f"Successfully updated DNS record for {subdomain}.{domain} to {ipv6}")
        else:
            print(f"Failed to update DNS record. Status code: {response.status_code}")
            print(f"Response: {response.json()}")
    else:
        # Create new record
        data = {
            "type": "AAAA",
            "name": f"{subdomain}.{domain}",
            "content": ipv6,
            "ttl": 120
        }
        response = requests.post(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records", headers=headers, json=data)
        if response.status_code == 200:
            print(f"Successfully created DNS record for {subdomain}.{domain} with {ipv6}")
        else:
            print(f"Failed to create DNS record. Status code: {response.status_code}")
            print(f"Response: {response.json()}")

# Main routine
def main():
    # Generate new IPv6
    new_ipv6 = generate_random_ipv6(subnet_prefix)
    
    # Ensure IPv6 is not used
    while is_ipv6_used(new_ipv6):
        new_ipv6 = generate_random_ipv6(subnet_prefix)
    
    if not is_valid_ipv6(new_ipv6):
        print(f"Invalid IPv6 address generated: {new_ipv6}")
        return
    
    # Update or create DNS record
    update_or_create_dns_record(zone_id, selected_domain, subdomain, new_ipv6)
    
    # Insert new IPv6 into database
    cursor.execute("INSERT INTO used_ips (ipv6) VALUES (?)", (new_ipv6,))
    conn.commit()

if __name__ == "__main__":
    main()

EOF

# Set permissions for the Python script
sudo chmod +x /opt/cloudflare_ipv6_updater.py

# Setup cron job to run the Python script every minute
echo "* * * * * /usr/bin/python3 /opt/cloudflare_ipv6_updater.py >> /var/log/cloudflare_ipv6_updater.log 2>&1" | sudo tee /etc/cron.d/cloudflare_ipv6_updater

echo "Setup complete. The Python script has been saved to /opt/cloudflare_ipv6_updater.py and will run every minute."
