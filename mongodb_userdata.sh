#!/bin/bash
set -x

exec > >(tee /var/log/user-data.log|logger -t user-data ) 2>&1

# Mounting data volume
sleep 120
mkdir -p /var/lib/mongodb
mkfs -t xfs /dev/nvme1n1
mount /dev/nvme1n1 /var/lib/mongodb
blkid=$(blkid | grep nvme1n1 | cut -d '"' -f 2)
echo "UUID=$blkid  /var/lib/mongodb  xfs  defaults,nofail  0  2" >> /etc/fstab

# Installing AWS CLI
apt-get update
apt-get install awscli -y

# Allowing TCP Forwarding from SSH
echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
systemctl restart ssh

# Installing MongoDB and Python with Dependent Packages and Pip
apt-get install dirmngr gnupg apt-transport-https ca-certificates software-properties-common -y
wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | sudo apt-key add -
echo "deb [ arch=arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
apt-get update

# Download and extract MongoDB binaries for ARM architecture
mkdir -p /opt/mongodb
wget https://fastdl.mongodb.org/linux/mongodb-linux-aarch64-amazon2-7.0.1.tgz -O /tmp/mongodb.tgz
tar -zxvf /tmp/mongodb.tgz -C /opt/mongodb --strip-components=1
rm /tmp/mongodb.tgz

# Create symbolic links to MongoDB binaries
ln -s /opt/mongodb/bin/mongod /usr/bin/mongod
ln -s /opt/mongodb/bin/mongo /usr/bin/mongo

apt-get install unzip python3-distutils jq build-essential python3-dev -y
chown -R mongodb:mongodb /var/lib/mongodb
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3 get-pip.py
rm -f get-pip.py
pip3 install --upgrade awscli
pip3 install boto3

# Configuring mongod.conf File
sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mongod.conf
cat >> /etc/mongod.conf <<EOL
security:
  keyFile: /opt/mongodb/keyFile

replication:
  replSetName: ${replica_set_name}
EOL
chown ubuntu:ubuntu /etc/mongod.conf
cat >> /etc/systemd/system/mongod.service <<EOL
[Unit]
Description=High-performance, schema-free document-oriented database
After=network.target

[Service]
User=mongodb
ExecStart=/usr/bin/mongod --quiet --config /etc/mongod.conf

[Install]
WantedBy=multi-user.target
EOL
chown ubuntu:ubuntu /etc/systemd/system/mongod.service

# Waiting for the primary MongoDB server to come in the running state
aws ec2 wait instance-running  --filters "Name=tag:Type,Values=primary" "Name=tag:Environment,Values=${environment}" "Name=tag:Project,Values=${project_name}" --region ${aws_region}

# System Settings for MongoDB Replica Set
PRIMARY_PRIVATE_IP=$(aws ec2 describe-instances --filters "Name=tag:Type,Values=primary" "Name=instance-state-name,Values=running" "Name=tag:Environment,Values=${environment}" "Name=tag:Project,Values=${project_name}" --region ${aws_region} | jq .Reservations[0].Instances[0].PrivateIpAddress --raw-output)
if [ ${custom_domain} = true ]
then
  echo "$PRIMARY_PRIVATE_IP mongo1${domain_name}" >> /etc/hosts
fi

while [ ! -f /home/ubuntu/populate_hosts_file.py ]
do
  sleep 2
done
while [ ! -f /home/ubuntu/parse_instance_tags.py ]
do
  sleep 2
done
while [ ! -f /home/ubuntu/keyFile ]
do
  sleep 2
done
mv /home/ubuntu/keyFile /opt/mongodb
chown mongodb:mongodb /opt/mongodb/keyFile
chmod 600 /opt/mongodb/keyFile

mv /home/ubuntu/populate_hosts_file.py /populate_hosts_file.py
mv /home/ubuntu/parse_instance_tags.py /parse_instance_tags.py

chmod +x populate_hosts_file.py
chmod +x parse_instance_tags.py

INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id --silent)
MONGO_NODE_TYPE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Type" --region ${aws_region} | jq .Tags[0].Value --raw-output)

# Executing python script to set up host and cluster-setup file
aws ec2 describe-instances --filters "Name=tag:Type,Values=secondary" "Name=instance-state-name,Values=running" "Name=tag:Environment,Values=${environment}" "Name=tag:Project,Values=${project_name}" --region ${aws_region} | jq . | ./populate_hosts_file.py ${replica_set_name} ${mongo_database} ${mongo_username} ${mongo_password} ${domain_name} ${custom_domain} $PRIMARY_PRIVATE_IP $MONGO_NODE_TYPE ${aws_region} ${environment} ${ssm_parameter_prefix}

if [ ${custom_domain} = true ]
then
  HOSTNAME=$(aws ec2 describe-instances --instance-id $INSTANCE_ID --region ${aws_region} | jq . | ./parse_instance_tags.py ${domain_name} ${custom_domain})
  hostnamectl set-hostname $HOSTNAME
fi

# Install and configure MongoDB Exporter for ARM64
mongodb_exporter_version="0.39.0"
wget https://github.com/percona/mongodb_exporter/releases/download/v${mongodb_exporter_version}/mongodb_exporter-${mongodb_exporter_version}.darwin-arm64.tar.gz -O /tmp/mongodb_exporter.tar.gz
tar -zxvf /tmp/mongodb_exporter.tar.gz -C /usr/local/bin/
rm /tmp/mongodb_exporter.tar.gz

# Create a systemd service for MongoDB Exporter
cat <<EOL | sudo tee /etc/systemd/system/mongodb_exporter.service
[Unit]
Description=MongoDB Exporter
After=network.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/mongodb_exporter

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and start MongoDB Exporter
systemctl daemon-reload
systemctl enable mongodb_exporter.service
systemctl start mongodb_exporter.service

# Enable MongoDB Exporter to start on system boot
systemctl enable mongodb_exporter.service

systemctl enable mongod.service
systemctl start mongod.service

if [ $MONGO_NODE_TYPE == "primary" ]; 
then
  sleep 300
  mongo ./cluster_setup.js
  sleep 60
  mongo ./user_setup.js
  sleep 60 
  mongo -u${mongo_username} -p${mongo_password} --authenticationDatabase admin ./priority_change.js
fi

systemctl start mongod.service

