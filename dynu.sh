#!/bin/bash

# Update and install required packages
echo "Updating package list and installing required packages..."
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y jq sqlite3 python3-pip
sudo mkdir -p /opt/dynamic-ipv6

# Install required Python libraries
pip3 install requests ipaddress

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
echo "Enter your IPv6 subnet (e.g., 2001:db8::/64):"
read -r ipv6_subnet

# Create SQLite database and table
echo "Creating SQLite database and table..."
sqlite3 /opt/dynamic-ipv6/cloudflare_config.db <<EOF
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
sqlite3 /opt/dynamic-ipv6/cloudflare_config.db <<EOF
INSERT INTO config (api_token, email, domain, zone_id, subdomain, ipv6_subnet)
VALUES ('$CLOUDFLARE_API_KEY', '$CLOUDFLARE_EMAIL', '$selected_domain', '$zone_id', '$subdomain', '$ipv6_subnet');
EOF

# Create the Python script
echo "Creating the Python script..."
cat << 'EOF' > /opt/dynamic-ipv6/cloudflare_ipv6_updater.py
import requests
import sqlite3
import random
import ipaddress
import logging

# Setup logging
logging.basicConfig(filename='/var/log/cloudflare_ipv6_updater.log', level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')

# Load configuration from the database
conn = sqlite3.connect('/opt/dynamic-ipv6/cloudflare_config.db')
cursor = conn.cursor()
cursor.execute("SELECT api_token, email, domain, zone_id, subdomain, ipv6_subnet FROM config ORDER BY id DESC LIMIT 1;")
config = cursor.fetchone()
api_token, email, selected_domain, zone_id, subdomain, subnet_prefix = config

# Print configuration for debugging
logging.info(f"Domain: {selected_domain}")
logging.info(f"Zone ID: {zone_id}")
logging.info(f"Subdomain: {subdomain}")
logging.info(f"IPv6 Subnet Prefix: {subnet_prefix}")

def generate_random_ipv6(subnet_prefix):
    subnet = ipaddress.IPv6Network(subnet_prefix)
    random_ip = subnet[random.randint(0, subnet.num_addresses - 1)]
    return str(random_ip)

def is_ipv6_used(ipv6):
    cursor.execute("SELECT * FROM used_ips WHERE ipv6 = ?", (ipv6,))
    return cursor.fetchone() is not None

def fetch_dns_records(zone_id, domain, subdomain):
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?type=AAAA&name={subdomain}.{domain}"
    headers = {
        "X-Auth-Key": api_token,
        "X-Auth-Email": email,
        "Content-Type": "application/json"
    }
    
    response = requests.get(url, headers=headers)
    result = response.json()
    
    logging.info(f"Fetched DNS records: {result}")
    
    if not result.get('success', False):
        logging.error(f"Error fetching DNS records: {result.get('errors', [{'message': 'Unknown error'}])[0]['message']}")
    
    return result.get('result', [])

def update_or_create_dns_record(zone_id, domain, subdomain, ipv6):
    records = fetch_dns_records(zone_id, domain, subdomain)
    
    headers = {
        "X-Auth-Key": api_token,
        "X-Auth-Email": email,
        "Content-Type": "application/json"
    }
    
    data = {
        "type": "AAAA",
        "name": f"{subdomain}.{domain}",
        "content": ipv6,
        "ttl": 60
    }
    
    if records:
        # Update existing record
        record_id = records[0]['id']
        url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}"
        response = requests.put(url, headers=headers, json=data)
        action = "updated"
    else:
        # Create new record
        url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records"
        response = requests.post(url, headers=headers, json=data)
        action = "created"
    
    result = response.json()
    if result.get('success', False):
        logging.info(f"Successfully {action} DNS record for {subdomain}.{domain} with {ipv6}")
        return True
    else:
        logging.error(f"Failed to {action} DNS record. Status code: {response.status_code}")
        if 'errors' in result and result['errors']:
            logging.error(f"Error: {result['errors'][0]['message']}")
        else:
            logging.error(f"Unknown error occurred. Full response: {result}")
        return False

def main():
    # Generate new IPv6
    new_ipv6 = generate_random_ipv6(subnet_prefix)
    logging.info(f"Generated IPv6 address: {new_ipv6}")
    
    # Ensure IPv6 is not used
    while is_ipv6_used(new_ipv6):
        new_ipv6 = generate_random_ipv6(subnet_prefix)
        logging.info(f"Regenerated IPv6 address: {new_ipv6}")
    
    # Update or create DNS record
    if update_or_create_dns_record(zone_id, selected_domain, subdomain, new_ipv6):
        # Insert new IPv6 into database
        cursor.execute("INSERT INTO used_ips (ipv6) VALUES (?)", (new_ipv6,))
        conn.commit()
    else:
        logging.warning("Failed to update or create DNS record. Not inserting into database.")

if __name__ == "__main__":
    main()

EOF

# Set permissions for the Python script
sudo chmod +x /opt/dynamic-ipv6/cloudflare_ipv6_updater.py

# Setup cron job to run the Python script every minute
echo "* * * * * /usr/bin/python3 /opt/dynamic-ipv6/cloudflare_ipv6_updater.py" | sudo tee /etc/cron.d/cloudflare_ipv6_updater

echo "Setup complete. The Python script has been saved to /opt/dynamic-ipv6/cloudflare_ipv6_updater.py and will run every minute."