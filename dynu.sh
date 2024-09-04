#!/bin/bash

# Check if jq is installed, and if not, install it
if ! command -v jq &> /dev/null; then
    echo "jq could not be found. Installing jq..."
    # Detect the package manager and install jq
    if [ -x "$(command -v apt-get)" ]; then
        sudo apt-get update
        sudo apt-get install -y jq
    elif [ -x "$(command -v yum)" ]; then
        sudo yum install -y epel-release
        sudo yum install -y jq
    elif [ -x "$(command -v dnf)" ]; then
        sudo dnf install -y jq
    elif [ -x "$(command -v brew)" ]; then
        brew install jq
    else
        echo "Package manager not detected. Please install jq manually."
        exit 1
    fi
    echo "jq installed successfully."
fi

# Prompt for the Cloudflare API Token
read -p "Enter your Cloudflare API Token: " CLOUDFLARE_API_TOKEN

# List domains using Cloudflare API
domains=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" | jq -r '.result[] | .name + " " + .id')

if [ -z "$domains" ]; then
    echo "No domains found. Please check your API token."
    exit 1
fi

# Show domain list and prompt user to select one
echo "Available Domains:"
select domain in $domains; do
    if [ -n "$domain" ]; then
        selected_domain=$(echo $domain | cut -d ' ' -f 1)
        selected_zone_id=$(echo $domain | cut -d ' ' -f 2)
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Ask user if subdomain should be random or manual
read -p "Do you want the subdomain to be random? (yes/no): " random_subdomain_choice

if [[ "$random_subdomain_choice" == "yes" ]]; then
    subdomain=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    echo "Random subdomain generated: $subdomain"
else
    read -p "Enter your desired subdomain: " subdomain
fi

# Get IPv6 subnet from user
read -p "Enter your IPv6 subnet (e.g., 2001:db8:2001:db8::/64): " ipv6_subnet

# Strip the /64 part from the subnet to get the prefix
subnet_prefix=$(echo $ipv6_subnet | cut -d '/' -f 1)

# Create SQLite database if it doesn't exist
db_file="/opt/cloudflare_config.db"
sqlite3 $db_file "CREATE TABLE IF NOT EXISTS config (id INTEGER PRIMARY KEY, api_token TEXT, domain TEXT, zone_id TEXT, subdomain TEXT, ipv6_subnet TEXT);"

# Insert the provided configuration into the database
sqlite3 $db_file "INSERT INTO config (api_token, domain, zone_id, subdomain, ipv6_subnet) VALUES ('$CLOUDFLARE_API_TOKEN', '$selected_domain', '$selected_zone_id', '$subdomain', '$subnet_prefix');"

# Python script content
python_script_content=$(cat <<EOF
import requests
import sqlite3
import random

# Load configuration from the database
conn = sqlite3.connect('/opt/cloudflare_config.db')
cursor = conn.cursor()
cursor.execute("SELECT api_token, domain, zone_id, subdomain, ipv6_subnet FROM config ORDER BY id DESC LIMIT 1;")
config = cursor.fetchone()
CLOUDFLARE_API_TOKEN, selected_domain, zone_id, subdomain, subnet_prefix = config

# Generate a random IPv6 address from /64 subnet
def generate_random_ipv6(subnet_prefix):
    suffix = ':'.join(['%x' % random.randint(0, 2**16-1) for _ in range(4)])
    return f"{subnet_prefix}{suffix}"

# Check if IPv6 address has been used
def is_ipv6_used(ipv6):
    cursor.execute("SELECT * FROM used_ips WHERE ipv6 = ?", (ipv6,))
    return cursor.fetchone() is not None

# Update DNS record on Cloudflare
def update_dns_record(zone_id, domain, subdomain, ipv6):
    # Find existing record
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={subdomain}.{domain}"
    headers = {
        "Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}",
        "Content-Type": "application/json"
    }
    response = requests.get(url, headers=headers)
    result = response.json()
    
    # Delete old record if it exists
    if result['result']:
        record_id = result['result'][0]['id']
        requests.delete(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}", headers=headers)
    
    # Add new DNS record
    data = {
        "type": "AAAA",
        "name": f"{subdomain}.{domain}",
        "content": ipv6,
        "ttl": 120
    }
    response = requests.post(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records", headers=headers, json=data)
    return response.status_code == 200

# Main routine
def main():
    # Generate new IPv6
    new_ipv6 = generate_random_ipv6(subnet_prefix)
    
    # Ensure IPv6 is not used
    while is_ipv6_used(new_ipv6):
        new_ipv6 = generate_random_ipv6(subnet_prefix)
    
    # Update DNS
    if update_dns_record(zone_id, selected_domain, subdomain, new_ipv6):
        # Insert new IPv6 into database
        cursor.execute("INSERT INTO used_ips (ipv6) VALUES (?)", (new_ipv6,))
        conn.commit()
        print(f"Updated {subdomain}.{selected_domain} to {new_ipv6}")
    else:
        print("Failed to update DNS record.")

if __name__ == "__main__":
    main()
EOF
)

# Save the Python script to /opt directory
python_script_path="/opt/cloudflare_ipv6_updater.py"
echo "$python_script_content" > $python_script_path
chmod +x $python_script_path

# Create used_ips table in SQLite if not exists
sqlite3 $db_file "CREATE TABLE IF NOT EXISTS used_ips (ipv6 TEXT);"

# Add the cron job to run the Python script every minute
cronjob="* * * * * /usr/bin/python3 $python_script_path"
(crontab -l; echo "$cronjob") | crontab -

echo "Setup complete. The Python script has been saved to $python_script_path and will run every minute."
